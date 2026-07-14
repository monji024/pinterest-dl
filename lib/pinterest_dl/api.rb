# frozen_string_literal: true

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
      html, pin_id = load_pin(pin_url, client)
      url = extract_pin_image(html, pin_id, quality: quality)
      url ||= api_image_url(pin_id, client, quality)
      raise NotFoundError, "No image found at #{pin_url}" unless url

      url
    end

    def get_video_url(pin_url, client: Client.new(config: config))
      pin = nil
      3.times do |attempt|
        html, pin_id = load_pin(pin_url, client, fresh: attempt.positive?)
        url = extract_pin_video(html, pin_id)
        return url if url

        pin = pin_from_api(pin_id, client)
        return pin[:video_url] if pin && pin[:video_url]
      end

      hint = pin && pin[:image_url] ? ' (it looks like an image pin, try the image command)' : ''
      raise NotFoundError, "No video found at #{pin_url}#{hint}"
    end

    def get_media(pin_url, quality: config.quality, client: Client.new(config: config))
      html, pin_id = load_pin(pin_url, client)
      image = extract_pin_image(html, pin_id, quality: quality)
      video = extract_pin_video(html, pin_id)
      if (!image || !video) && pin_id
        api_pin = pin_from_api(pin_id, client)
        image ||= api_pin && api_pin[:image_url] && Extractors::Image.apply_quality(api_pin[:image_url], quality)
        video ||= api_pin && api_pin[:video_url]
      end
      { image_url: image, video_url: video }
    end

    def download(url, path:, overwrite: nil)
      Downloader.new(config: config).download(url, path: path, overwrite: overwrite)
    end

    def download_batch(urls, dir:, filename: nil, concurrency: nil, overwrite: nil, &progress)
      Downloader.new(config: config).download_batch(
        urls,
        dir: dir,

# step-2
