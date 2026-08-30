# frozen_string_literal: true

require 'json'
require 'uri'

module PinterestDL
  class Board
    B_URL = 'https://www.pinterest.com/resource/BoardFeedResource/get/'

    BOARD_URL_PATTERN = %r{pinterest\.[a-z.]+/(?<username>[^/]+)/(?<slug>[^/]+)/?(?<section>[^/]+)?/?\z}

    def initialize(client: PinterestDL::Client.new, config: PinterestDL.config)
      @client = client
      @config = config
    end

    def call(board_url, limit: 50, pages: 10)
      match = BOARD_URL_PATTERN.match(board_url)
      raise PinterestDL::InvalidURLError, "Not a Pinterest board URL: #{board_url}" unless match

      results = []
      bookmarks = nil
      pages_fetched = 0

      loop do
        page = fetch_page(match, bookmarks: bookmarks)
        results.concat(page[:pins])
        bookmarks = page[:bookmarks]
        pages_fetched += 1

        break if results.size >= limit
        break if bookmarks.nil? || bookmarks.empty? || bookmarks == ['-end-']
        break if pages_fetched >= pages
        break if page[:pins].empty?
      end

      results.first(limit)
    end

    private

    def fetch_page(match, bookmarks:)
      session = establish_session(match)
      body = @client.get(
        build_request_url(match, bookmarks),
        use_cache: false,
        headers: board_headers(session)
      )

      json = safe_parse(body)
      raise PinterestDL::NotFoundError, "Board not found: #{match[0]}" unless json

      data_node = json.dig('resource_response', 'data') || []
      next_bookmarks = json.dig('resource_response', 'bookmark')

      { pins: Array(data_node).filter_map { |r| build_pin(r) }, bookmarks: Array(next_bookmarks) }
    end

    def establish_session(match)
      board_path = "/#{match[:username]}/#{match[:slug]}/"
      board_uri = URI("https://www.pinterest.com#{board_path}")
      home_response = @client.raw_get(board_uri.to_s)
      cookies = (home_response.get_fields('set-cookie') || []).map { |c| c.split(';').first }

      { board_path: board_path, board_uri: board_uri, cookies: cookies, csrf: csrf_token(cookies) }
    end

    def csrf_token(cookies)
      token_cookie = cookies.find { |c| c.start_with?('csrftoken=') }
      token_cookie ? token_cookie.split('=', 2).last : 'undefined'
    end

    def build_request_url(match, bookmarks)
      options = {
        board_url: "/#{match[:username]}/#{match[:slug]}/",
        board_id: '',
        section_slug: match[:section]
      }.compact
      options[:bookmarks] = bookmarks if bookmarks && !bookmarks.empty?

      data = { options: options, context: {} }.to_json
      res_uri = URI(B_URL)
      res_uri.query = URI.encode_www_form('source_url' => options[:board_url], 'data' => data)
      res_uri.to_s
    end

    def board_headers(session)
      cookie_header = [@config.cookies, session[:cookies].join('; ')].compact.reject(&:empty?).join('; ')

      {
        'Accept' => 'application/json, text/javascript, */*, q=0.01',
        'X-Requested-With' => 'XMLHttpRequest',
        'X-Pinterest-PWS-Handler' => 'www/[username]/[slug].js',
        'X-CSRFToken' => session[:csrf],
        'Referer' => session[:board_uri].to_s,
        'Cookie' => cookie_header
      }
    end

    def build_pin(raw)
      id = raw['id']
      return nil unless id

      orig_image = raw.dig('images', 'orig', 'url')
      video_url = first_video_url(raw)

      {
        id: id,
        pin_url: "https://www.pinterest.com/pin/#{id}/",
        title: raw['title'] || raw['grid_title'],
        description: raw['description'],
        creator: raw.dig('pinner', 'username') || raw.dig('pinner', 'full_name'),
        image_url: orig_image,
        video_url: video_url
      }
    end

    def first_video_url(raw)
      video_list = raw.dig('videos', 'video_list')
      return nil unless video_list

      video_list.values.first&.dig('url')
    end

    def safe_parse(body)
      JSON.parse(body)
    rescue JSON::ParserError, TypeError
      nil
    end
  end
end
