# frozen_string_literal: true

require 'fileutils'
require 'uri'
require_relative '../extractors/image'

module PinterestDL
  module TUI
    class DownloadQueue
      PauseSignal = Class.new(StandardError)
      CancelSignal = Class.new(StandardError)
      DEFAULT_WORKERS = 2
      DEFAULT_AUTO_CLEAR_DELAY = 2.5

      Item = Struct.new(
        :id, :pin_id, :title, :url, :filename, :dest_path, :media_type, :quality,
        :status, :bytes_received, :total_bytes, :speed, :eta, :error_message,
        :started_at, :finished_at,
        keyword_init: true
      ) do
        def progress_ratio
          return 1.0 if status == :completed
          return 0.0 unless total_bytes&.positive?

          [[bytes_received.to_f / total_bytes, 0.0].max, 1.0].min
        end

        def percent
          (progress_ratio * 100).round
        end
      end

      def initialize(session:, output_dir: './downloads', on_update: nil, workers: DEFAULT_WORKERS)
        @session = session
        @output_dir = output_dir
        @on_update = on_update
        @items = []
        @next_id = 1
        @completed_total = 0
        @control_flags = {}
        @mutex = Mutex.new
        @work_queue = Queue.new
        @running = true
        @workers = start_workers([workers.to_i, 1].max)
      end

      def items
        @mutex.synchronize { @items.map(&:dup) }
      end

      def active_speed
        @mutex.synchronize do
          @items.select { |i| i.status == :downloading }.sum(&:speed)
        end
      end

      def active_count
        @mutex.synchronize { @items.count { |i| %i[downloading queued].include?(i.status) } }
      end

      def failed_count
        @mutex.synchronize { @items.count { |i| i.status == :failed } }
      end

      def completed_count
        @mutex.synchronize { @completed_total }
      end

      def prune_completed(ttl: DEFAULT_AUTO_CLEAR_DELAY)
        now = monotonic_now
        pruned = @mutex.synchronize do
          before = @items.size
          @items.reject! do |item|
            if item.status == :completed && item.finished_at && (now - item.finished_at) >= ttl
              @control_flags.delete(item.id)
              true
            else
              false
            end
          end
          before != @items.size
        end
        notify_update if pruned
        pruned
      end

      def enqueue(pin, quality: :originals, video_quality: :best, output_dir: @output_dir)
        url, media_type = resolve_media_url(pin, quality: quality, video_quality: video_quality)
        raise ArgumentError, 'Pin has no downloadable media URL' if url.to_s.strip.empty?

        FileUtils.mkdir_p(output_dir)
        filename = build_filename(pin, url, media_type)
        dest_path = File.join(output_dir, filename)

        item = @mutex.synchronize do
          created = Item.new(
            id: @next_id,
            pin_id: pin[:id].to_s,
            title: pin[:title].to_s,
            url: url,
            filename: filename,
            dest_path: dest_path,
            media_type: media_type,
            quality: media_type == :video ? video_quality : quality,
            status: :queued,
            bytes_received: 0,
            total_bytes: nil,
            speed: 0.0,
            eta: nil,
            error_message: nil
          )
          @next_id += 1
          @items << created
          @control_flags[created.id] = nil
          created.dup
        end

        @work_queue << item.id
        notify_update
        item
      end

      def enqueue_batch(pins, quality: :originals, video_quality: :best, output_dir: @output_dir)
        queued = []
        Array(pins).each do |pin|
          queued << enqueue(pin, quality: quality, video_quality: video_quality, output_dir: output_dir)
        rescue ArgumentError
          next
        end
        queued
      end

      def pause(item_id)
        changed = @mutex.synchronize do
          item = find_item_unlocked(item_id)
          return false unless item

          if item.status == :queued
            item.status = :paused
            @control_flags[item_id] = :pause
            true
          elsif item.status == :downloading
            @control_flags[item_id] = :pause
            true
          else
            false
          end
        end
        notify_update if changed
        changed
      end

      def resume(item_id)
        requeue = @mutex.synchronize do
          item = find_item_unlocked(item_id)
          return false unless item && %i[paused failed].include?(item.status)

          item.status = :queued
          item.error_message = nil
          @control_flags[item_id] = nil
          true
        end
        if requeue
          @work_queue << item_id
          notify_update
        end
        requeue
      end

      def cancel(item_id)
        changed = @mutex.synchronize do
          item = find_item_unlocked(item_id)
          return false unless item

          if %i[queued paused].include?(item.status)
            item.status = :cancelled
            item.speed = 0.0
            item.eta = nil
            @control_flags[item_id] = :cancel
            cleanup_part_file(item.dest_path)
            true
          elsif item.status == :downloading
            @control_flags[item_id] = :cancel
            true
          else
            false
          end
        end
        notify_update if changed
        changed
      end

      def remove(item_id)
        removed = @mutex.synchronize do
          item = find_item_unlocked(item_id)
          return false unless item

          @control_flags[item_id] = :cancel if item.status == :downloading
          cleanup_part_file(item.dest_path)
          @items.delete(item)
          @control_flags.delete(item_id)
          true
        end
        notify_update if removed
        removed
      end

      def shutdown
        @mutex.synchronize do
          @running = false
          @control_flags.each_key { |k| @control_flags[k] ||= :pause }
        end
        @workers.size.times { @work_queue << nil }
        @workers.each { |w| w.join(2) }
      end

      private

      def start_workers(count)
        Array.new(count) do
          Thread.new do
            Thread.current.report_on_exception = false
            while (item_id = @work_queue.pop)
              break unless running?

              process_item(item_id)
            end
          end
        end
      end

      def running?
        @mutex.synchronize { @running }
      end

      def process_item(item_id)
        snapshot = @mutex.synchronize do
          item = find_item_unlocked(item_id)
          next nil unless item&.status == :queued

          item.status = :downloading
          item.started_at = monotonic_now
          item.error_message = nil
          @control_flags[item_id] = nil
          item.dup
        end
        return unless snapshot

        notify_update
        execute_real_download(snapshot)
      end

      def execute_real_download(snapshot)
        @session.download(
          snapshot.url,
          path: snapshot.dest_path,
          overwrite: true,
          resume: true
        ) do |progress|
          check_control_signal!(snapshot.id)
          update_item_progress(snapshot.id, progress)
        end

        mark_completed(snapshot.id, snapshot.dest_path)
      rescue PauseSignal
        mark_paused(snapshot.id)
      rescue CancelSignal
        cleanup_part_file(snapshot.dest_path)
        mark_cancelled(snapshot.id)
      rescue PinterestDL::Error, StandardError => e
        flag = @mutex.synchronize { @control_flags[snapshot.id] }
        if flag == :pause
          mark_paused(snapshot.id)
        elsif flag == :cancel
          cleanup_part_file(snapshot.dest_path)
          mark_cancelled(snapshot.id)
        else
          mark_failed(snapshot.id, e.message)
        end
      end

      def check_control_signal!(item_id)
        flag = @mutex.synchronize { @control_flags[item_id] }
        raise PauseSignal if flag == :pause
        raise CancelSignal if flag == :cancel
      end

      def update_item_progress(item_id, progress)
        received = progress.is_a?(Hash) ? progress[:received].to_i : progress.to_i
        total = progress.is_a?(Hash) ? progress[:total] : nil
        speed = progress.is_a?(Hash) ? progress[:speed].to_f : 0.0
        remaining = total&.positive? ? [total - received, 0].max : nil
        eta = remaining && speed.positive? ? (remaining.to_f / speed) : nil

        @mutex.synchronize do
          item = find_item_unlocked(item_id)
          next unless item

          item.bytes_received = received
          item.total_bytes = total if total&.positive?
          item.speed = speed
          item.eta = eta
        end
        notify_update
      end

      def mark_completed(item_id, dest_path)
        final_size = File.exist?(dest_path) ? File.size(dest_path) : nil
        @mutex.synchronize do
          item = find_item_unlocked(item_id)
          next unless item

          item.status = :completed
          item.bytes_received = final_size if final_size
          item.total_bytes = final_size if final_size
          item.speed = 0.0
          item.eta = 0.0
          item.finished_at = monotonic_now
          @completed_total += 1
        end
        notify_update
      end

      def mark_paused(item_id)
        @mutex.synchronize do
          item = find_item_unlocked(item_id)
          next unless item

          item.status = :paused
          item.speed = 0.0
          item.eta = nil
        end
        notify_update
      end

      def mark_cancelled(item_id)
        @mutex.synchronize do
          item = find_item_unlocked(item_id)
          next unless item

          item.status = :cancelled
          item.speed = 0.0
          item.eta = nil
        end
        notify_update
      end

      def mark_failed(item_id, message)
        @mutex.synchronize do
          item = find_item_unlocked(item_id)
          next unless item

          item.status = :failed
          item.speed = 0.0
          item.eta = nil
          item.error_message = message.to_s
        end
        notify_update
      end

      def resolve_media_url(pin, quality:, video_quality:)
        if !pin[:video_url].to_s.empty?
          url = apply_video_quality(pin[:video_url], video_quality)
          [url, :video]
        else
          raw = pin[:image_url].to_s
          url = raw.empty? ? '' : Extractors::Image.apply_quality(raw, quality)
          [url, :image]
        end
      end

      def apply_video_quality(url, video_quality)
        return url if video_quality == :best || video_quality.nil?

        str = url.to_s
        case video_quality.to_sym
        when :'720p' then str.sub(%r{/(?:1080p|480p|360p)/}, '/720p/')
        when :'480p' then str.sub(%r{/(?:1080p|720p|360p)/}, '/480p/')
        when :'1080p' then str.sub(%r{/(?:720p|480p|360p)/}, '/1080p/')
        else str
        end
      end

      def build_filename(pin, url, media_type)
        default_ext = media_type == :video ? '.mp4' : '.jpg'
        ext = begin
          found = File.extname(URI.parse(url).path.to_s)
          found.match?(/\A\.[A-Za-z0-9]{2,5}\z/) ? found : default_ext
        rescue URI::InvalidURIError
          default_ext
        end
        raw_title = pin[:title].to_s.strip.downcase.gsub(/[^a-z0-9]+/, '_').gsub(/\A_|_\z/, '')
        pin_id = pin[:id].to_s.gsub(/[^A-Za-z0-9_-]/, '')
        stem = if !raw_title.empty?
                 raw_title[0, 24]
               elsif !pin_id.empty?
                 "pin_#{pin_id}"
               else
                 "pin_#{Time.now.to_i}"
               end
        suffix = pin_id.empty? ? '' : "_#{pin_id[-6, 6] || pin_id}"
        "#{stem}#{suffix}#{ext}"
      end

      def cleanup_part_file(dest_path)
        part = "#{dest_path}.part"
        FileUtils.rm_f(part) if File.exist?(part)
      end

      def find_item_unlocked(item_id)
        @items.find { |i| i.id == item_id }
      end

      def notify_update
        @on_update&.call
      end

      def monotonic_now
        Process.clock_gettime(Process::CLOCK_MONOTONIC)
      end
    end
  end
end
