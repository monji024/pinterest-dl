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

# step-1
