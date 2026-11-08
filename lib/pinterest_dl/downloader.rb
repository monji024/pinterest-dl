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
        verify_content: should_verify,
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
        verify_content: should_verify = verify_content,
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
        MediaValidator.validate_file_content!(part_path, url: url) if should_verify
        return resumed_offset
      end

      cleanup_part(part_path)
      perform_download_to_part(
        url,
        part_path,
        resumed_offset: 0,
        max_size: max_size,
        max_speed: max_speed,
        verify_content: should_verify,
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

      @client.stream_get(url, headers: headers) do |chunk, response|
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

# step-3
