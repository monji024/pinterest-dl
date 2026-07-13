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

# step-1
