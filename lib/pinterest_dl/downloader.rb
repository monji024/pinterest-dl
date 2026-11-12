# frozen_string_literal: true

require 'fileutils'
require 'uri'
require_relative 'errors'
require_relative 'models'
require_relative 'media_validator'
require_relative 'progress_bar'
require_relative 'security'

module PinterestDL
  class Downloader
    CONTENT_TYPE_EXT = {
      'image/jpeg' => '.jpg',
      'image/png' => '.png',
      'image/gif' => '.gif',
      'image/webp' => '.webp',
      'image/avif' => '.avif',
      'video/mp4' => '.mp4',
      'video/quicktime' => '.mov',
      'video/webm' => '.webm'
    }.freeze

    SPEED_MULTIPLIERS = {
      '' => 1,
      'b' => 1,
      'k' => 1024,
      'kb' => 1024,
      'm' => 1024 * 1024,
      'mb' => 1024 * 1024,
      'g' => 1024 * 1024 * 1024,
      'gb' => 1024 * 1024 * 1024
    }.freeze

    VALID_COLLISION_STRATEGIES = %i[rename skip overwrite].freeze

    TRACKING_QUERY_PARAMS = %w[
      utm_source utm_medium utm_campaign utm_term utm_content
      fbclid gclid _ga mc_cid mc_eid
    ].freeze

    CONTENT_RANGE_REGEX = /\Abytes\s+(\d+)-(\d+)\/(\d+|\*)\z/i.freeze
    UNSATISFIED_RANGE_REGEX = /\Abytes\s+\*\/(\d+)\z/i.freeze

    def initialize(client: PinterestDL::Client.new, config: PinterestDL.config)
      @client = client
      @config = config
      @path_mutex = Mutex.new
      @reserved_paths = {}
      @file_locks = Hash.new { |h, k| h[k] = Mutex.new }
    end

    def download(url, path:, overwrite: nil, resume: nil, max_size: nil, max_speed: nil,
                 verify_content: nil, collision_strategy: nil, progress_bar: nil, &on_progress)
      raise ArgumentError, 'url must not be nil/empty' if url.to_s.strip.empty?
      raise ArgumentError, 'path must not be nil/empty' if path.to_s.strip.empty?

      validate_download_url!(url)
      strategy = validate_collision_strategy!(collision_strategy) if collision_strategy
      should_overwrite = resolve_bool(overwrite, :overwrite, true)
      should_resume = resolve_bool(resume, :resume, false)
      size_limit = max_size || (@config.respond_to?(:max_file_size) ? @config.max_file_size : nil)
      speed_limit = parse_speed_limit(max_speed || (@config.respond_to?(:max_speed) ? @config.max_speed : nil))
      should_verify = resolve_bool(verify_content, :verify_content_type, true)

      target_path = path
      if file_present_on_disk?(target_path)
        if strategy == :skip || (strategy.nil? && !should_overwrite)
          return target_path
        elsif strategy == :rename
          target_path = find_next_available_path(target_path)
        end
      end

      ensure_writable_directory!(File.dirname(target_path))
      part_path = build_part_path(target_path, resumable: should_resume)
      resumed_offset = should_resume && File.exist?(part_path) ? File.size(part_path) : 0

      progress_bar&.start
      bytes_written = perform_download_with_416_recovery(
        url,
        part_path,
        resumed_offset: resumed_offset,
        max_size: size_limit,
        max_speed: speed_limit,
        verify_content: verify_content,
        progress_bar: progress_bar,
        &on_progress
      )
      progress_bar&.finish(final_bytes: bytes_written)

      if should_verify && bytes_written.positive?
        MediaValidator.validate_file_content!(part_path, url: url)
      end

      atomic_move!(part_path, target_path)
      target_path
    rescue ArgumentError
      cleanup_part(part_path)
      raise
    rescue IncompleteDownloadError
      cleanup_part(part_path) unless should_resume
      raise
    rescue PinterestDL::Error
      cleanup_part(part_path)
      raise
    rescue Errno::ENOSPC, Errno::EDQUOT => e
      cleanup_part(part_path)
      raise DiskSpaceError.new("Insufficient disk space while saving #{target_path}: #{e.message}", url: url, cause_error: e)
    rescue Errno::EACCES, Errno::EROFS, Errno::EPERM => e
      cleanup_part(part_path)
      raise DiskSpaceError.new("Permission or read-only storage error at #{target_path}: #{e.message}", url: url, cause_error: e)
    rescue StandardError => e
      cleanup_part(part_path)
      raise PinterestDL::DownloadError.new("Could not download #{url} to #{target_path}: #{e.message}", url: url, cause_error: e)
    end

    def download_batch(urls, dir:, filename: nil, concurrency: nil, overwrite: nil,
                       resume: nil, deduplicate: nil, collision_strategy: nil,
                       max_size: nil, max_speed: nil, &progress)
      ensure_writable_directory!(dir)
      effective_strategy = resolve_batch_collision_strategy(collision_strategy, overwrite)
      total = urls.size
      return DownloadReport.new if total.zero?

      started_at = monotonic_now
      @path_mutex.synchronize do
        @reserved_paths.clear
        @file_locks.clear
      end

      workers = resolve_concurrency(concurrency, total)
      opts = {
        dir: dir,
        filename: filename,
        resume: resume,
        deduplicate: resolve_bool(deduplicate, :deduplicate, false),
        collision_strategy: effective_strategy,
        max_size: max_size,
        max_speed: max_speed,
        started_at: started_at
      }

      if workers <= 1
        sequential_batch(urls, **opts, &progress)
      else
        concurrent_batch(urls, workers: workers, **opts, &progress)
      end
    end

    def parse_speed_limit(value)
      return nil if value.nil?
      return value.to_i if value.is_a?(Numeric) && value.positive?

      str = value.to_s.strip.downcase
      return nil if str.empty?

      match = str.match(/\A(\d+(?:\.\d+)?)\s*(b|k|kb|m|mb|g|gb)?\z/i)
      raise ArgumentError, "Invalid max_speed format: #{value.inspect}" unless match

      amount = match[1].to_f
      unit = (match[2] || '').downcase
      bytes_per_sec = (amount * SPEED_MULTIPLIERS.fetch(unit, 1)).to_i
      bytes_per_sec.positive? ? bytes_per_sec : nil
    end

    private

    def validate_collision_strategy!(strategy)
      sym = strategy.to_s.strip.downcase.to_sym
      return sym if VALID_COLLISION_STRATEGIES.include?(sym)

      raise ArgumentError, "collision_strategy must be one of: #{VALID_COLLISION_STRATEGIES.join(', ')} (got #{strategy.inspect})"
    end

    def resolve_batch_collision_strategy(collision_strategy, overwrite)
      return validate_collision_strategy!(collision_strategy) unless collision_strategy.nil?
      return :skip if overwrite == false
      return :overwrite if overwrite == true

      if @config.respond_to?(:overwrite) && @config.overwrite == false
        return :skip
      end

      configured = @config.respond_to?(:collision_strategy) ? @config.collision_strategy : :overwrite
      validate_collision_strategy!(configured || :overwrite)
    end

    def validate_download_url!(url)
      return unless @client.is_a?(PinterestDL::Client)

      allow_local = @config.respond_to?(:allow_local_network) ? @config.allow_local_network : false
      https_only = @config.respond_to?(:https_only) ? @config.https_only : false
      Security.parse_and_validate_url!(url, allow_local: allow_local, https_only: https_only)
    end

    def resolve_bool(explicit, config_attr, default)
      return explicit unless explicit.nil?
      return @config.public_send(config_attr) if @config.respond_to?(config_attr)

      default
    end

    def build_part_path(path, resumable: false)
      return "#{path}.part" if resumable

      "#{path}.part.#{Process.pid}.#{Thread.current.object_id}"
    end

    def perform_download_with_416_recovery(url, part_path, resumed_offset:, max_size:, max_speed:,
                                           verify_content:, progress_bar:, &on_progress)
      perform_download_to_part(
        url,
        part_path,
        resumed_offset: resumed_offset,
        max_size: max_size,
        max_speed: max_speed,
        verify_content: verify_content,
        progress_bar: progress_bar,
        &on_progress
      )
    rescue RangeNotSatisfiableError => e
      raise unless resumed_offset.positive?

      total_remote = parse_unsatisfied_range_total(e.content_range)
      if total_remote && resumed_offset == total_remote
        if max_size && resumed_offset > max_size
          raise FileTooLargeError.new(
            "File at #{url} (#{resumed_offset} bytes) exceeds max_file_size (#{max_size} bytes)",
            url: url,
            max_size: max_size,
            actual_size: resumed_offset
          )
        end
        MediaValidator.validate_file_content!(part_path, url: url) if verify_content
        return resumed_offset
      end

      cleanup_part(part_path)
      perform_download_to_part(
        url,
        part_path,
        resumed_offset: 0,
        max_size: max_size,
        max_speed: max_speed,
        verify_content: verify_content,
        progress_bar: progress_bar,
        &on_progress
      )
    end

    def parse_unsatisfied_range_total(content_range_header)
      str = content_range_header.to_s.strip
      match = str.match(UNSATISFIED_RANGE_REGEX)
      return nil unless match

      total = match[1].to_i
      total.positive? ? total : nil
    end

    def perform_download_to_part(url, part_path, resumed_offset:, max_size:, max_speed:, verify_content:, progress_bar:, &on_progress)
      headers = {}
      headers['Range'] = "bytes=#{resumed_offset}-" if resumed_offset.positive?

      if @client.respond_to?(:stream_get)
        stream_to_part(
          url,
          part_path,
          headers: headers,
          resumed_offset: resumed_offset,
          max_size: max_size,
          max_speed: max_speed,
          verify_content: verify_content,
          progress_bar: progress_bar,
          &on_progress
        )
      else
        direct_to_part(
          url,
          part_path,
          headers: headers,
          resumed_offset: resumed_offset,
          max_size: max_size,
          verify_content: verify_content,
          progress_bar: progress_bar,
          &on_progress
        )
      end
    end

    def prepare_response_plan!(response, url:, resumed_offset:, max_size:, verify_content:)
      if response.nil?
        return {
          is_partial: false,
          effective_offset: 0,
          expected_body_bytes: nil,
          final_total_size: nil,
          write_mode: 'wb'
        }
      end

      status_code = response.respond_to?(:code) && response.code ? response.code.to_i : 200
      if status_code == 416 || response.is_a?(Net::HTTPRequestedRangeNotSatisfiable)
        cr = extract_header(response, 'content-range')
        raise RangeNotSatisfiableError.new("Range not satisfiable for #{url} (HTTP 416)", url: url, status_code: 416, content_range: cr)
      end

      content_type = extract_header(response, 'content-type')
      MediaValidator.validate_content_type!(content_type, url: url) if verify_content

      raw_len = extract_header(response, 'content-length')
      content_length = raw_len && raw_len.to_s.strip.match?(/\A\d+\z/) ? raw_len.to_s.strip.to_i : nil

      is_partial = response.is_a?(Net::HTTPPartialContent) || status_code == 206
      if is_partial
        unless resumed_offset.positive?
          raise InvalidResponseError.new("Unexpected HTTP 206 without Range request for #{url}", url: url, status_code: 206)
        end

        range_info = parse_and_validate_content_range!(
          extract_header(response, 'content-range'),
          expected_offset: resumed_offset,
          content_length: content_length,
          url: url
        )
        effective_offset = resumed_offset
        expected_body_bytes = range_info[:range_length]
        final_total_size = range_info[:total_size] || (effective_offset + expected_body_bytes)
        write_mode = 'ab'
      else
        effective_offset = 0
        expected_body_bytes = content_length
        final_total_size = content_length
        write_mode = 'wb'
      end

      if max_size && final_total_size && final_total_size > max_size
        raise FileTooLargeError.new(
          "File at #{url} (#{final_total_size} bytes) exceeds max_file_size (#{max_size} bytes)",
          url: url,
          max_size: max_size,
          actual_size: final_total_size
        )
      end

      {
        is_partial: is_partial,
        effective_offset: effective_offset,
        expected_body_bytes: expected_body_bytes,
        final_total_size: final_total_size,
        write_mode: write_mode
      }
    end

    def parse_and_validate_content_range!(header_value, expected_offset:, content_length:, url:)
      raw = header_value.to_s.strip
      if raw.empty?
        raise InvalidResponseError.new("Missing Content-Range header in HTTP 206 response from #{url}", url: url, status_code: 206)
      end

      match = raw.match(CONTENT_RANGE_REGEX)
      unless match
        raise InvalidResponseError.new("Malformed Content-Range header #{raw.inspect} from #{url}", url: url, status_code: 206)
      end

      range_start = match[1].to_i
      range_end = match[2].to_i
      total_token = match[3]
      total_size = total_token == '*' ? nil : total_token.to_i

      if range_start > range_end || (total_size && (total_size <= 0 || range_end >= total_size))
        raise InvalidResponseError.new("Invalid byte range bounds in Content-Range #{raw.inspect} from #{url}", url: url, status_code: 206)
      end

      if range_start != expected_offset
        raise InvalidResponseError.new(
          "Content-Range start (#{range_start}) does not match requested offset (#{expected_offset}) from #{url}",
          url: url,
          status_code: 206
        )
      end

      range_length = (range_end - range_start) + 1
      if content_length && content_length != range_length
        raise InvalidResponseError.new(
          "Content-Length (#{content_length}) does not match Content-Range length (#{range_length}) from #{url}",
          url: url,
          status_code: 206
        )
      end

      {
        range_start: range_start,
        range_end: range_end,
        range_length: range_length,
        total_size: total_size
      }
    end

    def extract_header(response, name)
      return nil unless response.respond_to?(:[])

      response[name] || response[name.downcase] || response[name.split('-').map(&:capitalize).join('-')]
    end

    def stream_to_part(url, part_path, headers:, resumed_offset:, max_size:, max_speed:, verify_content:, progress_bar:, &on_progress)
      plan = nil
      received_body_bytes = 0
      total_written = 0
      file_handle = nil
      started_at = monotonic_now

      final_response = @client.stream_get(url, headers: headers) do |chunk, response|
        if file_handle.nil?
          plan = prepare_response_plan!(
            response,
            url: url,
            resumed_offset: resumed_offset,
            max_size: max_size,
            verify_content: verify_content
          )
          total_written = plan[:effective_offset]
          file_handle = File.open(part_path, plan[:write_mode])
        end

        chunk_size = chunk.bytesize
        next_total = total_written + chunk_size
        if max_size && next_total > max_size
          raise FileTooLargeError.new(
            "Download of #{url} exceeded max_file_size (#{max_size} bytes)",
            url: url,
            max_size: max_size,
            actual_size: next_total
          )
        end

        if plan[:expected_body_bytes] && (received_body_bytes + chunk_size) > plan[:expected_body_bytes]
          raise InvalidResponseError.new(
            "Received more bytes than declared in Content-Range/Content-Length from #{url}",
            url: url
          )
        end

        file_handle.write(chunk)
        received_body_bytes += chunk_size
        total_written = next_total

        throttle_bandwidth(received_body_bytes, started_at, max_speed) if max_speed
        report_chunk_progress(total_written, plan[:final_total_size], started_at, url, progress_bar, &on_progress)
      end

      if file_handle.nil?
        if final_response
          plan = prepare_response_plan!(
            final_response,
            url: url,
            resumed_offset: resumed_offset,
            max_size: max_size,
            verify_content: verify_content
          )
          total_written = plan[:effective_offset]
        end
        File.binwrite(part_path, '') unless resumed_offset.positive? && plan && plan[:is_partial]
      else
        file_handle.flush
        file_handle.close
        file_handle = nil
      end

      verify_received_length!(plan, received_body_bytes, url: url) if plan
      total_written
    ensure
      file_handle&.close unless file_handle&.closed?
    end

    def direct_to_part(url, part_path, headers:, resumed_offset:, max_size:, verify_content:, progress_bar:, &on_progress)
      response = headers.empty? ? @client.raw_get(url) : @client.raw_get(url, headers: headers)
      plan = prepare_response_plan!(
        response,
        url: url,
        resumed_offset: resumed_offset,
        max_size: max_size,
        verify_content: verify_content
      )

      body = response.body.to_s
      received_body_bytes = body.bytesize
      total_written = plan[:effective_offset] + received_body_bytes

      if max_size && total_written > max_size
        raise FileTooLargeError.new(
          "File at #{url} (#{total_written} bytes) exceeds max_file_size (#{max_size} bytes)",
          url: url,
          max_size: max_size,
          actual_size: total_written
        )
      end

      verify_received_length!(plan, received_body_bytes, url: url)

      File.open(part_path, plan[:write_mode]) do |f|
        f.write(body)
      end

      progress_bar&.update(total_written, bytes_received: total_written, total_bytes: total_written)
      on_progress&.call(total_written, total_written, url)
      total_written
    end

    def verify_received_length!(plan, received_body_bytes, url:)
      expected_body = plan[:expected_body_bytes]
      return unless expected_body

      if received_body_bytes < expected_body
        expected_total = plan[:effective_offset] + expected_body
        received_total = plan[:effective_offset] + received_body_bytes
        raise IncompleteDownloadError.new(
          "Incomplete download from #{url}: expected #{expected_total} bytes, got #{received_total}",
          url: url,
          expected_bytes: expected_total,
          received_bytes: received_total
        )
      elsif received_body_bytes > expected_body
        raise InvalidResponseError.new(
          "Response body length (#{received_body_bytes}) exceeded declared length (#{expected_body}) from #{url}",
          url: url
        )
      end
    end

    def throttle_bandwidth(bytes_transferred, started_at, max_speed)
      return if max_speed.nil? || max_speed <= 0 || bytes_transferred <= 0

      elapsed = monotonic_now - started_at
      expected_time = bytes_transferred.to_f / max_speed
      sleep_time = expected_time - elapsed
      sleep(sleep_time) if sleep_time > 0.005
    end

    def report_chunk_progress(received, total_bytes, started_at, url, progress_bar, &on_progress)
      elapsed = [monotonic_now - started_at, 0.001].max
      speed = received.to_f / elapsed
      progress_bar&.update(received, bytes_received: received, total_bytes: total_bytes, speed: speed)
      return unless on_progress

      case on_progress.arity
      when 1
        on_progress.call({ received: received, total: total_bytes, speed: speed, url: url })
      when 2
        on_progress.call(received, total_bytes)
      else
        on_progress.call(received, total_bytes, url)
      end
    end

    def atomic_move!(part_path, path)
      File.rename(part_path, path)
    end

    def cleanup_part(part_path)
      FileUtils.rm_f(part_path) if part_path && File.exist?(part_path)
    end

    def ensure_writable_directory!(dir)
      FileUtils.mkdir_p(dir)
      return if File.writable?(dir)

      raise DiskSpaceError, "Target directory #{dir} is not writable"
    rescue Errno::ENOSPC, Errno::EDQUOT => e
      raise DiskSpaceError.new("Insufficient disk space to create #{dir}: #{e.message}", cause_error: e)
    rescue Errno::EACCES, Errno::EROFS, Errno::EPERM => e
      raise DiskSpaceError.new("Permission denied creating directory #{dir}: #{e.message}", cause_error: e)
    end
    alias ensure_directory_and_space! ensure_writable_directory!

    def resolve_concurrency(concurrency, total)
      return 1 unless @client.is_a?(PinterestDL::Client)

      configured = concurrency || (@config.respond_to?(:concurrency) ? @config.concurrency : 1)
      [[configured.to_i, 1].max, total].min
    end

    def sequential_batch(urls, dir:, filename:, resume:, deduplicate:, collision_strategy:,
                         max_size:, max_speed:, started_at:, &progress)
      succeeded = []
      failed = []
      skipped = []
      resumed = []
      duplicates = []
      bytes_total = 0
      seen_urls = {}
      total = urls.size
      should_resume = resolve_bool(resume, :resume, false)

      urls.each_with_index do |item, index|
        raw_url = extract_item_url(item)
        norm_url = normalize_media_url(raw_url)

        if deduplicate && !norm_url.empty? && seen_urls[norm_url]
          duplicates << raw_url
          skipped << resolve_target(item, index, dir, filename).last
          safe_invoke_progress(progress, index + 1, total, raw_url)
          next
        end
        seen_urls[norm_url] = true unless norm_url.empty?

        url, path, action = resolve_unique_target(item, index, dir, filename, collision_strategy: collision_strategy)
        if action == :skip
          skipped << path
          succeeded << path
          safe_invoke_progress(progress, index + 1, total, url)
          next
        end

        begin
          had_part = should_resume && File.exist?("#{path}.part") && File.size("#{path}.part").positive?
          lock = file_lock_for(path)
          lock.synchronize do
            download(url, path: path, overwrite: true, resume: should_resume, max_size: max_size, max_speed: max_speed)
          end
          resumed << path if had_part
          succeeded << path
          bytes_total += File.size(path) if File.exist?(path)
        rescue PinterestDL::Error => e
          @config.logger.warn(Security.redact("failed to download #{url}: #{e.message}"))
          failed << { url: url, error: e }
        rescue StandardError => e
          wrapped = DownloadError.new(e.message, url: url, cause_error: e)
          @config.logger.warn(Security.redact("failed to download #{url}: #{wrapped.message}"))
          failed << { url: url, error: wrapped }
        end
        safe_invoke_progress(progress, index + 1, total, url)
      end

      DownloadReport.new(
        succeeded: succeeded,
        failed: failed,
        skipped: skipped,
        resumed: resumed,
        duplicates: duplicates,
        bytes_downloaded: bytes_total,
        elapsed_seconds: monotonic_now - started_at
      )
    end

    def concurrent_batch(urls, dir:, filename:, workers:, resume:, deduplicate:, collision_strategy:,
                         max_size:, max_speed:, started_at:, &progress)
      queue = Queue.new
      urls.each_with_index { |item, index| queue << [item, index] }
      workers.times { queue << nil }

      succeeded = []
      failed = []
      skipped = []
      resumed = []
      duplicates = []
      bytes_total = 0
      done_count = 0
      total = urls.size
      seen_urls = {}
      mutex = Mutex.new
      should_resume = resolve_bool(resume, :resume, false)

      threads = Array.new(workers) do
        Thread.new do
          Thread.current.report_on_exception = false
          while (work = queue.pop)
            item, index = work
            url = extract_item_url(item)
            path = nil
            outcome = nil
            err = nil
            file_bytes = 0
            was_resumed = false

            begin
              norm_url = normalize_media_url(url)
              is_dup = mutex.synchronize do
                if deduplicate && !norm_url.empty? && seen_urls[norm_url]
                  true
                else
                  seen_urls[norm_url] = true unless norm_url.empty?
                  false
                end
              end

              if is_dup
                _, path = resolve_target(item, index, dir, filename)
                outcome = :duplicate
              else
                url, path, action = resolve_unique_target(item, index, dir, filename, collision_strategy: collision_strategy)
                if action == :skip
                  outcome = :skipped
                else
                  lock = file_lock_for(path)
                  lock.synchronize do
                    was_resumed = should_resume && File.exist?("#{path}.part") && File.size("#{path}.part").positive?
                    download(url, path: path, overwrite: true, resume: should_resume, max_size: max_size, max_speed: max_speed)
                    file_bytes = File.size(path) if File.exist?(path)
                  end
                  outcome = :succeeded
                end
              end
            rescue PinterestDL::Error => e
              err = e
              outcome = :failed
            rescue StandardError => e
              err = DownloadError.new("Worker failure downloading #{url}: #{e.message}", url: url, cause_error: e)
              outcome = :failed
            end

            @config.logger.warn(Security.redact("failed to download #{url}: #{err.message}")) if outcome == :failed && err

            current_done = mutex.synchronize do
              case outcome
              when :duplicate
                duplicates << url
                skipped << path if path
              when :skipped
                skipped << path
                succeeded << path
              when :succeeded
                resumed << path if was_resumed
                succeeded << path
                bytes_total += file_bytes
              when :failed
                failed << { url: url, error: err }
              end
              done_count += 1
              done_count
            end

            safe_invoke_progress(progress, current_done, total, url)
          end
        end
      end

      threads.each(&:join)
      DownloadReport.new(
        succeeded: succeeded,
        failed: failed,
        skipped: skipped,
        resumed: resumed,
        duplicates: duplicates,
        bytes_downloaded: bytes_total,
        elapsed_seconds: monotonic_now - started_at
      )
    end

    def safe_invoke_progress(progress, done, total, url)
      return unless progress

      progress.call(done, total, url)
    rescue StandardError => e
      @config.logger.warn(Security.redact("progress callback error for #{url}: #{e.message}"))
    end

    def file_lock_for(path)
      @path_mutex.synchronize { @file_locks[path] }
    end

    def file_present_on_disk?(path)
      File.exist?(path) && File.size(path).positive?
    end

    def find_next_available_path(base_path)
      ext = File.extname(base_path)
      stem = File.basename(base_path, ext)
      parent = File.dirname(base_path)
      counter = 1
      candidate = File.join(parent, "#{stem}_#{counter}#{ext}")
      while @reserved_paths[candidate] || file_present_on_disk?(candidate) || File.exist?("#{candidate}.part")
        counter += 1
        candidate = File.join(parent, "#{stem}_#{counter}#{ext}")
      end
      candidate
    end

    def resolve_unique_target(item, index, dir, filename, collision_strategy: :overwrite)
      strategy = validate_collision_strategy!(collision_strategy)
      url, base_path = resolve_target(item, index, dir, filename)

      @path_mutex.synchronize do
        occupied = @reserved_paths[base_path] || file_present_on_disk?(base_path)

        case strategy
        when :skip
          return [url, base_path, :skip] if occupied

          @reserved_paths[base_path] = true
          [url, base_path, :download]
        when :rename
          if occupied
            candidate = find_next_available_path(base_path)
            @reserved_paths[candidate] = true
            [url, candidate, :download]
          else
            @reserved_paths[base_path] = true
            [url, base_path, :download]
          end
        when :overwrite
          @reserved_paths[base_path] = true
          [url, base_path, :download]
        end
      end
    end

    def extract_item_url(item)
      if item.is_a?(Hash) || item.is_a?(Pin)
        item[:video_url] || item[:image_url] || item[:url]
      else
        item
      end
    end

    def resolve_target(item, index, dir, filename)
      if item.is_a?(Hash) || item.is_a?(Pin)
        url = item[:video_url] || item[:image_url] || item[:url]
        name = filename ? filename.call(url, index) : pin_filename(item, url, index)
      else
        url = item
        name = filename ? filename.call(url, index) : default_filename(url, index)
      end
      [url, File.join(dir, sanitize_filename(name))]
    end

    def normalize_media_url(url)
      raw = url.to_s.strip
      return '' if raw.empty?

      uri = URI.parse(raw)
      scheme = uri.scheme.to_s.downcase
      host = uri.host.to_s.downcase
      port_part = if (scheme == 'http' && uri.port && uri.port != 80) ||
                     (scheme == 'https' && uri.port && uri.port != 443)
                    ":#{uri.port}"
                  else
                    ''
                  end
      path = uri.path.to_s.empty? ? '/' : uri.path.to_s

      query_part = ''
      if uri.query && !uri.query.empty?
        pairs = URI.decode_www_form(uri.query).reject do |k, _|
          TRACKING_QUERY_PARAMS.include?(k.to_s.downcase)
        end
        query_part = "?#{URI.encode_www_form(pairs.sort)}" unless pairs.empty?
      end

      "#{scheme}://#{host}#{port_part}#{path}#{query_part}"
    rescue URI::InvalidURIError
      raw
    end

    def pin_filename(pin, url, index)
      ext = extract_ext(url)
      id = pin[:id].to_s.strip
      return default_filename(url, index) if id.empty?

      format('%<index>04d_%<id>s%<ext>s', index: index + 1, id: id, ext: ext)
    end

    def default_filename(url, index)
      format('%<index>04d%<ext>s', index: index + 1, ext: extract_ext(url))
    end

    def extract_ext(url)
      ext = File.extname(URI(url.to_s).path.to_s)[/\A\.[A-Za-z0-9]{2,5}\z/]
      ext || '.jpg'
    rescue URI::InvalidURIError
      '.jpg'
    end

    def sanitize_filename(name)
      clean = File.basename(name.to_s.strip).gsub(/[\x00\/\\:*?"<>|]/, '_')
      clean = clean.sub(/\A\.+/, '_')
      clean.empty? ? 'download.jpg' : clean
    end

    def monotonic_now
      Process.clock_gettime(Process::CLOCK_MONOTONIC)
    end
  end
end
