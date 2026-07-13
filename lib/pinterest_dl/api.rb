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

# step-1
