# frozen_string_literal: true

require_relative 'configuration'
require_relative 'client'
require_relative 'downloader'
require_relative 'search'
require_relative 'board'
require_relative 'media_type'
require_relative 'extractors/image'
require_relative 'extractors/video'
require_relative 'extractors/pin_data'

module PinterestDL
  class Session
    attr_reader :config, :client

    def initialize(config: nil, client: nil, **options)
      base_config = config ? config.dup : PinterestDL.config.dup
      @config = options.empty? ? base_config : base_config.merge(**options)
      @client = client || Client.new(config: @config)
    end

    def configure
      yield @config if block_given?
      @client = Client.new(config: @config)
      self
    end

    def get_image_url(pin_url, quality: @config.quality)
      PinterestDL.get_image_url(pin_url, quality: quality, client: @client)
    end

    def get_video_url(pin_url)
      PinterestDL.get_video_url(pin_url, client: @client)
    end

    def get_media(pin_url, quality: @config.quality)
      PinterestDL.get_media(pin_url, quality: quality, client: @client)
    end

    def search(query, limit: 25, pages: nil, type: :all)
      PinterestDL.search(query, limit: limit, pages: pages, type: type, client: @client, config: @config)
    end

    def search_images(query, limit: 25)
      search(query, limit: limit, type: :image).filter_map { |p| p[:image_url] }
    end

    def search_videos(query, limit: 25)
      search(query, limit: limit, type: :video).filter_map { |p| p[:video_url] }
    end

    def board(board_url, limit: 50, pages: nil, type: :all)
      PinterestDL.board(board_url, limit: limit, pages: pages, type: type, client: @client, config: @config)
    end

    def download(url, path:, **options, &block)
      Downloader.new(client: @client, config: @config).download(url, path: path, **options, &block)
    end

    def download_batch(urls, dir:, **options, &block)
      Downloader.new(client: @client, config: @config).download_batch(urls, dir: dir, **options, &block)
    end
  end
end
