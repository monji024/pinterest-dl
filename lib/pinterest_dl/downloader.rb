# frozen_string_literal: true

require 'fileutils'

module PinterestDL
  class Downloader
    def initialize(client: PinterestDL::Client.new, config: PinterestDL.config)
      @client = client
      @config = config
    end

    def download(url, path:)
      raise ArgumentError, 'url must not be nil/empty' if url.to_s.empty?

      FileUtils.mkdir_p(File.dirname(path))
      response = @client.raw_get(url)
      File.binwrite(path, response.body)
      path
    rescue PinterestDL::Error
      raise
    rescue StandardError => e
      raise PinterestDL::DownloadError, "Could not download #{url} to #{path}: #{e.message}"
    end

    def download_batch(urls, dir:, filename: nil, &progress)
      FileUtils.mkdir_p(dir)
      succeeded = []
      failed = []
      total = urls.size

      urls.each_with_index do |url, index|
        name = filename ? filename.call(url, index) : default_filename(url, index)
        path = File.join(dir, name)
        begin
          download(url, path: path)
          succeeded << path
        rescue PinterestDL::Error => e
          @config.logger.warn("failed to download #{url}: #{e.message}")
          failed << { url: url, error: e }
        end
        progress&.call(index + 1, total, url)
      end

      { succeeded: succeeded, failed: failed }
    end

    private

    def default_filename(url, index)
      ext = File.extname(URI(url).path)
      ext = '.jpg' if ext.nil? || ext.empty?
      format('%<index>04d%<ext>s', index: index + 1, ext: ext)
    rescue URI::InvalidURIError
      format('%<index>04d.jpg', index: index + 1)
    end
  end
end
