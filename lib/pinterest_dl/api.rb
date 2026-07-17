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
        filename: filename,
        concurrency: concurrency,
        overwrite: overwrite,
        &progress
      )
    end

    def search(query, limit: 25, pages: nil, type: :all, client: Client.new(config: config))
      type = MediaType.parse(type)
      needed_pages = (limit.to_f / 25).ceil + 2
      effective_pages = pages || [needed_pages, 5].max
      effective_pages = [effective_pages, 15].max unless type == :all
      Search.new(client: client, config: config).call(query, limit: limit, pages: effective_pages, type: type)
    end

    def search_json(query, limit: 25)
      JSON.pretty_generate(search(query, limit: limit))
    end

    def search_images(query, limit: 25)
      search(query, limit: limit, type: :image).filter_map { |p| p[:image_url] }
    end

    def search_videos(query, limit: 25)
      search(query, limit: limit, type: :video).filter_map { |p| p[:video_url] }
    end

    def board(board_url, limit: 50, pages: nil, type: :all, client: Client.new(config: config))
      type = MediaType.parse(type)
      needed_pages = (limit.to_f / Board::PAGE_SIZE).ceil + 2
      effective_pages = pages || [needed_pages, 10].max
      effective_pages = [effective_pages, 20].max unless type == :all
      Board.new(client: client, config: config).call(board_url, limit: limit, pages: effective_pages, type: type)
    end

    private

    def load_pin(pin_url, client, fresh: false)
      validate_pin_url!(pin_url)
      html = client.get(normalize_pin_url(pin_url), use_cache: !fresh)
      id = pin_id_from(client.last_url) || pin_id_from(pin_url) || html.to_s[%r{pinterest\.[a-z.]+/pin/(\d+)}, 1]
      [html, id]
    end

    def pin_from_api(pin_id, client)
      return nil unless pin_id

      data = { options: { id: pin_id, field_set_key: 'detailed' }, context: {} }.to_json
      uri = URI('https://www.pinterest.com/resource/PinResource/get/')
      uri.query = URI.encode_www_form('source_url' => "/pin/#{pin_id}/", 'data' => data)
      headers = {
        'Accept' => 'application/json, text/javascript, */*, q=0.01',
        'X-Requested-With' => 'XMLHttpRequest',
        'X-Pinterest-AppState' => 'active',
        'X-Pinterest-PWS-Handler' => 'www/pin/[id].js',
        'X-Pinterest-Source-Url' => "/pin/#{pin_id}/",
        'X-CSRFToken' => client.cookie('csrftoken') || 'undefined',
        'Referer' => "https://www.pinterest.com/pin/#{pin_id}/"
      }
      pin = JSON.parse(client.get(uri.to_s, headers: headers, use_cache: false)).dig('resource_response', 'data')
      return nil unless pin.is_a?(Hash)

      {
        image_url: Extractors::PinData.best_image_url(pin),
        video_url: Extractors::PinData.first_video_url(pin)
      }
    rescue PinterestDL::Error, JSON::ParserError => e
      logger.debug("PinResource failed for pin #{pin_id}: #{e.message}")
      nil
    end

    def api_image_url(pin_id, client, quality)
      url = pin_from_api(pin_id, client)&.dig(:image_url)
      url && Extractors::Image.apply_quality(url, quality)
    end

    def normalize_pin_url(pin_url)
      id = pin_id_from(pin_url)
      id ? "https://www.pinterest.com/pin/#{id}/" : pin_url
    end

    def pin_id_from(url)
      match = url.to_s.match(%r{/pin/(?:[^/?#]*--)?(\d+)})
      match && match[1]
    end

# step-6
