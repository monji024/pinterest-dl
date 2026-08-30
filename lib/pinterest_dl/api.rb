# frozen_string_literal: true

# Monji024
module PinterestDL
  PIN_URL_PATTERN = %r{(pinterest\.[a-z.]+/pin/|pin\.it/)}i.freeze

  class << self
    def config
      @config ||= Configuration.new
    end

    def configure
      yield config
      config
    end

    def logger
      config.logger
    end

    def get_image_url(pin_url, quality: config.quality, client: Client.new(config: config))
      validate_pin_url!(pin_url)
      html = client.get(pin_url)
      url = extract_pin_image(html, quality: quality)
      raise NotFoundError, "No image found at #{pin_url}" unless url

      url
    end

    def get_video_url(pin_url, client: Client.new(config: config))
      validate_pin_url!(pin_url)
      html = client.get(pin_url)
      url = extract_pin_video(html)
      raise NotFoundError, "No video found at #{pin_url}" unless url

      url
    end

    def get_media(pin_url, quality: config.quality, client: Client.new(config: config))
      validate_pin_url!(pin_url)
      html = client.get(pin_url)
      {
        image_url: extract_pin_image(html, quality: quality),
        video_url: extract_pin_video(html)
      }
    end

    def download(url, path:)
      Downloader.new(config: config).download(url, path: path)
    end

    def download_batch(urls, dir:, filename: nil, &progress)
      Downloader.new(config: config).download_batch(urls, dir: dir, filename: filename, &progress)
    end

    def search(query, limit: 25, pages: 5)
      Search.new(config: config).call(query, limit: limit, pages: pages)
    end

    def search_json(query, limit: 25)
      JSON.pretty_generate(search(query, limit: limit))
    end

    def search_images(query, limit: 25)
      search(query, limit: limit).filter_map { |p| p[:image_url] }
    end

    def search_videos(query, limit: 25)
      search(query, limit: limit).filter_map { |p| p[:video_url] }
    end

    def board(board_url, limit: 50, pages: 10)
      Board.new(config: config).call(board_url, limit: limit, pages: pages)
    end

    private
    def extract_pin_image(html, quality:)
      pin = Extractors::PinData.extract(html)
      url = pin && pin[:image_url]
      url ||= Extractors::Image.extract(html, quality: quality)
      return nil unless url

      Extractors::Image.apply_quality(url, quality)
    end

    def extract_pin_video(html)
      pin = Extractors::PinData.extract(html)
      (pin && pin[:video_url]) || Extractors::Video.extract(html)
    end

    def validate_pin_url!(pin_url)
      return if pin_url.to_s.match?(PIN_URL_PATTERN)

      raise InvalidURLError, "Not a Pinterest pin URL: #{pin_url.inspect}"
    end
  end
end
