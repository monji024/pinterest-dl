# frozen_string_literal: true

require 'json'
require 'net/http'
require 'uri'

module PinterestDL
  class Search
    S_URL = 'https://www.pinterest.com/resource/BaseSearchResource/get/'

    def initialize(client: PinterestDL::Client.new, config: PinterestDL.config)
      @client = client
      @config = config
    end

    def call(query, limit: 25, pages: 5)
      results = []
      bookmarks = nil
      pages_fetched = 0

      loop do
        page = fetch_page(query, bookmarks: bookmarks)
        pins = page[:pins]
        results.concat(pins)
        bookmarks = page[:bookmarks]
        pages_fetched += 1

        break if results.size >= limit
        break if bookmarks.nil? || bookmarks.empty? || bookmarks == ['-end-']
        break if pages_fetched >= pages
        break if pins.empty?
      end

      results.first(limit)
    end

    private

    def fetch_page(query, bookmarks: nil)
      session = establish_session(query)
      body = @client.get(
        build_search_url(session[:source_path], query, bookmarks),
        use_cache: false,
        headers: search_headers(session)
      )

      json = safe_parse(body)
      raise PinterestDL::NotFoundError, "No search results for \"#{query}\"" unless json

      parse_search_response(json)
    end

    # Pinterest's search resource requires a session cookie + CSRF token
    # obtained by first loading the human-facing search page.
    def establish_session(query)
      source_path = "/search/pins/?q=#{URI.encode_www_form_component(query)}"
      home_uri = URI("https://www.pinterest.com#{source_path}")
      home_response = @client.raw_get(home_uri.to_s)
      cookies = (home_response.get_fields('set-cookie') || []).map { |c| c.split(';').first }

      { source_path: source_path, home_uri: home_uri, cookies: cookies, csrf: csrf_token(cookies) }
    end

    def csrf_token(cookies)
      token_cookie = cookies.find { |c| c.start_with?('csrftoken=') }
      token_cookie ? token_cookie.split('=', 2).last : 'undefined'
    end

    def build_search_url(source_path, query, bookmarks)
      options = { query: query, scope: 'pins', page_size: 25 }
      options[:bookmarks] = bookmarks if bookmarks && !bookmarks.empty?
      data = { options: options, context: {} }.to_json

      res_uri = URI(S_URL)
      res_uri.query = URI.encode_www_form('source_url' => source_path, 'data' => data)
      res_uri.to_s
    end

    def search_headers(session)
      cookie_header = [@config.cookies, session[:cookies].join('; ')].compact.reject(&:empty?).join('; ')

      {
        'Accept' => 'application/json, text/javascript, */*, q=0.01',
        'X-Requested-With' => 'XMLHttpRequest',
        'X-Pinterest-PWS-Handler' => 'www/search/[scope].js',
        'X-CSRFToken' => session[:csrf],
        'Referer' => session[:home_uri].to_s,
        'Cookie' => cookie_header
      }
    end

    def parse_search_response(json)
      data_node = json.dig('resource_response', 'data') || {}
      raw_results = data_node['results'] || []
      next_bookmarks = json.dig('resource_response', 'bookmark') ||
                        json.dig('resource', 'options', 'bookmarks')

      { pins: raw_results.filter_map { |r| build_pin(r) }, bookmarks: Array(next_bookmarks) }
    end

    def build_pin(raw)
      id = raw['id']
      return nil unless id

      {
        id: id,
        pin_url: "https://www.pinterest.com/pin/#{id}/",
        title: raw['title'] || raw['grid_title'],
        description: raw['description'],
        creator: pin_creator(raw),
        image_url: pin_image_url(raw),
        video_url: first_video_url(raw)
      }
    end

    def pin_creator(raw)
      raw.dig('pinner', 'username') || raw.dig('pinner', 'full_name')
    end

    def pin_image_url(raw)
      raw.dig('images', 'orig', 'url') || fallback_image_url(raw)
    end

    def fallback_image_url(raw)
      images = raw['images']
      return nil unless images

      images.values.filter_map { |v| v['url'] if v.is_a?(Hash) }.last
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
