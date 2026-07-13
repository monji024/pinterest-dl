# frozen_string_literal: true

require 'fileutils'
require 'uri'

module PinterestDL
  class Downloader
    CONTENT_TYPE_EXT = {
      'image/jpeg' => '.jpg',
      'image/png' => '.png',
      'image/gif' => '.gif',
      'image/webp' => '.webp',
      'video/mp4' => '.mp4',
      'video/quicktime' => '.mov'
    }.freeze

    def initialize(client: PinterestDL::Client.new, config: PinterestDL.config)
      @client = client
      @config = config
    end

    def download(url, path:, overwrite: nil)
      raise ArgumentError, 'url must not be nil/empty' if url.to_s.strip.empty?
      raise ArgumentError, 'path must not be nil/empty' if path.to_s.strip.empty?

      should_overwrite = overwrite.nil? ? (@config.respond_to?(:overwrite) ? @config.overwrite : true) : overwrite
      return path if !should_overwrite && File.exist?(path) && File.size(path).positive?

      FileUtils.mkdir_p(File.dirname(path))
      part_path = "#{path}.part.#{Process.pid}.#{Thread.current.object_id}"

      write_to_part(url, part_path)
      File.rename(part_path, path)
      path
    rescue PinterestDL::Error
      cleanup_part(part_path)
      raise
    rescue StandardError => e
      cleanup_part(part_path)
      raise PinterestDL::DownloadError, "Could not download #{url} to #{path}: #{e.message}"
    end

    def download_batch(urls, dir:, filename: nil, concurrency: nil, overwrite: nil, &progress)
      FileUtils.mkdir_p(dir)
      total = urls.size
      return { succeeded: [], failed: [], skipped: [] } if total.zero?

      workers = resolve_concurrency(concurrency, total)
      return sequential_batch(urls, dir: dir, filename: filename, overwrite: overwrite, &progress) if workers <= 1

      concurrent_batch(urls, dir: dir, filename: filename, workers: workers, overwrite: overwrite, &progress)
    end

    private

    def write_to_part(url, part_path)
      if @client.respond_to?(:stream_get)
        File.open(part_path, 'wb') do |file|
          @client.stream_get(url) { |chunk| file.write(chunk) }
        end
      else
        response = @client.raw_get(url)
        File.binwrite(part_path, response.body)
      end
    end

    def cleanup_part(part_path)
      FileUtils.rm_f(part_path) if part_path && File.exist?(part_path)
    end

    def resolve_concurrency(concurrency, total)
      return 1 unless @client.is_a?(PinterestDL::Client)

      configured = concurrency || (@config.respond_to?(:concurrency) ? @config.concurrency : 1)
      [[configured.to_i, 1].max, total].min
    end

    def sequential_batch(urls, dir:, filename:, overwrite:, &progress)
      succeeded = []
      failed = []
      skipped = []
      total = urls.size
      should_overwrite = overwrite.nil? ? (@config.respond_to?(:overwrite) ? @config.overwrite : true) : overwrite

      urls.each_with_index do |item, index|
        url, path = resolve_target(item, index, dir, filename)
        begin
          if !should_overwrite && File.exist?(path) && File.size(path).positive?
            skipped << path
            succeeded << path
          else
            download(url, path: path, overwrite: true)
            succeeded << path
          end
        rescue PinterestDL::Error => e
          @config.logger.warn("failed to download #{url}: #{e.message}")
          failed << { url: url, error: e }
        end
        progress&.call(index + 1, total, url)
      end

      { succeeded: succeeded, failed: failed, skipped: skipped }
    end

    def concurrent_batch(urls, dir:, filename:, workers:, overwrite:, &progress)
      queue = Queue.new
      urls.each_with_index { |item, index| queue << [item, index] }
      workers.times { queue << nil }

      succeeded = []
      failed = []
      skipped = []
      done_count = 0
      total = urls.size
      mutex = Mutex.new
      should_overwrite = overwrite.nil? ? (@config.respond_to?(:overwrite) ? @config.overwrite : true) : overwrite

      threads = Array.new(workers) do
        Thread.new do
          while (work = queue.pop)
            item, index = work
            url, path = resolve_target(item, index, dir, filename)
            outcome = nil
            err = nil

            begin
              if !should_overwrite && File.exist?(path) && File.size(path).positive?
                outcome = :skipped
              else
                download(url, path: path, overwrite: true)
                outcome = :succeeded
              end
            rescue PinterestDL::Error => e
              err = e
              outcome = :failed
            end

            mutex.synchronize do
              case outcome
              when :skipped
                skipped << path
                succeeded << path
              when :succeeded
                succeeded << path
              when :failed
                @config.logger.warn("failed to download #{url}: #{err.message}")
                failed << { url: url, error: err }
              end
              done_count += 1
              progress&.call(done_count, total, url)
            end
          end
        end
      end

      threads.each(&:join)
      { succeeded: succeeded, failed: failed, skipped: skipped }
    end

    def resolve_target(item, index, dir, filename)
      if item.is_a?(Hash)
        url = item[:video_url] || item[:image_url] || item[:url]
        name = filename ? filename.call(url, index) : pin_filename(item, url, index)
      else
        url = item
        name = filename ? filename.call(url, index) : default_filename(url, index)
      end
      [url, File.join(dir, sanitize_filename(name))]
    end


# step-6
