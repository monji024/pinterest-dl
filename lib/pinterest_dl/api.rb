# frozen_string_literal: true

module PinterestDL
  PIN_URL_PATTERN = %r{\Ahttps?://(?:[a-z0-9-]+\.)*(?:pinterest\.(?:com|[a-z]{2,3}(?:\.[a-z]{2})?)/pin/|pin\.it/)}i.freeze

  class << self
    def config
      @config ||= Configuration.new
    end

    def configure
      yield config if block_given?
      config
    end

    def reset_config!
      config.reset!
    end

    def session(**options, &block)
      sess = Session.new(**options)
      sess.configure(&block) if block
      sess
    end

    def logger
      config.logger
    end

    def get_image_url(pin_url, quality: config.quality, client: Client.new(config: config))
      html, pin_id = load_pin(pin_url, client)
      url = extract_pin_image(html, pin_id, quality: quality)
      url ||= api_image_url(pin_id, client, quality)
      raise NotFoundError.new("No image found at #{pin_url}", url: pin_url) unless url

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
      raise NotFoundError.new("No video found at #{pin_url}#{hint}", url: pin_url)
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

    def download(url, path:, overwrite: nil, client: nil, **options, &progress)
      active_client = client || Client.new(config: config)
      Downloader.new(client: active_client, config: config).download(
        url,
        path: path,
        overwrite: overwrite,
        **options,
        &progress
      )
    end

    def download_batch(urls, dir:, filename: nil, concurrency: nil, overwrite: nil, client: nil, **options, &progress)
      active_client = client || Client.new(config: config)
      Downloader.new(client: active_client, config: config).download_batch(
        urls,
        dir: dir,
        filename: filename,
        concurrency: concurrency,
        overwrite: overwrite,
        **options,
        &progress
      )
    end

    def search(query, limit: 25, pages: nil, type: :all, client: nil, config: self.config)
      type = MediaType.parse(type)
      active_client = client || Client.new(config: config)
      needed_pages = (limit.to_f / 25).ceil + 2
      effective_pages = pages || [needed_pages, 5].max
      effective_pages = [effective_pages, 15].max unless type == :all
      Search.new(client: active_client, config: config).call(query, limit: limit, pages: effective_pages, type: type)
    end

# step-0
