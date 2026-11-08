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

# step-0
