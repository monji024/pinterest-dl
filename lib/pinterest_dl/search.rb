# frozen_string_literal: true

require 'json'
require 'net/http'
require 'uri'
require_relative 'paginator'
require_relative 'media_type'
require_relative 'extractors/pin_data'

module PinterestDL
  class Search
    S_URL = 'https://www.pinterest.com/resource/BaseSearchResource/get/'
    PAGE_SIZE = 25

    def initialize(client: PinterestDL::Client.new, config: PinterestDL.config)
      @client = client
      @config = config
    end

    def call(query, limit: 25, pages: 5, type: :all)
      raise ArgumentError, 'query must not be empty' if query.to_s.strip.empty?

      parsed_type = MediaType.parse(type)
      session = establish_session(query)
      paginator = Paginator.new(max_pages: pages, limit: limit, type: parsed_type) do |bookmarks, _page_idx|
        fetch_page(session, query, bookmarks: bookmarks)
      end

      results = paginator.to_a
      if results.empty?
        fallback = PinterestDL::Extractors::PinData.extract_pins(session[:html], quality: @config.quality)
        results = PinterestDL::MediaType.filter(fallback, parsed_type)
      end
      results.first(limit)
    end

    private

    def fetch_page(session, query, bookmarks: nil)
      url = build_search_url(session[:source_path], query, bookmarks)
      body = @client.get(url, use_cache: false, headers: search_headers(session))

      json = validate_search_json!(body, query: query, url: url)
      parse_search_response(json)
    end

    def establish_session(query)
      source_path = "/search/pins/?q=#{URI.encode_www_form_component(query)}"
      home_uri = URI("https://www.pinterest.com#{source_path}")
      home_response = @client.raw_get(home_uri.to_s)
      cookies = (home_response.get_fields('set-cookie') || []).map { |c| c.split(';').first }
      csrf = @client.cookie('csrftoken', home_uri.to_s) || csrf_token(cookies)

      {
        source_path: source_path,
        home_uri: home_uri,
        cookies: cookies,
        csrf: csrf,
        html: home_response.body
      }
    end

    def csrf_token(cookies)
      token_cookie = cookies.find { |c| c.start_with?('csrftoken=') }
      token_cookie ? token_cookie.split('=', 2).last : 'undefined'
    end

    def build_search_url(source_path, query, bookmarks)
      options = { query: query, scope: 'pins', page_size: PAGE_SIZE }
      options[:bookmarks] = bookmarks if bookmarks && !bookmarks.empty?
      data = { options: options, context: {} }.to_json

      res_uri = URI(S_URL)
      res_uri.query = URI.encode_www_form('source_url' => source_path, 'data' => data)
      res_uri.to_s
    end

    def search_headers(session)
      headers = {
        'Accept' => 'application/json, text/javascript, */*, q=0.01',
        'X-Requested-With' => 'XMLHttpRequest',
        'X-Pinterest-AppState' => 'active',
        'X-Pinterest-Source-Url' => session[:source_path],
        'X-Pinterest-PWS-Handler' => 'www/search/[scope].js',
        'X-CSRFToken' => session[:csrf],
        'Referer' => session[:home_uri].to_s
      }
      unless @client.respond_to?(:cookie_jar)
        cookie_header = [@config.cookies, session[:cookies].join('; ')].compact.reject(&:empty?).join('; ')
        headers['Cookie'] = cookie_header unless cookie_header.empty?
      end
      headers
    end

    def parse_search_response(json)
      data_node = json.dig('resource_response', 'data')
      raw_results =
        case data_node
        when Array then data_node
        when Hash then data_node['results'] || []
        else []
        end
      next_bookmarks = json.dig('resource_response', 'bookmark') ||
                       json.dig('resource', 'options', 'bookmarks')

      { pins: raw_results.filter_map { |r| build_pin(r) }, bookmarks: Array(next_bookmarks) }
    end

    def build_pin(raw)
      PinterestDL::Extractors::PinData.build_pin_hash(raw, quality: @config.quality)
    end

    def validate_search_json!(body, query:, url:)
      parsed = JSON.parse(body.to_s)
      raise PinterestDL::NotFoundError.new("No search results for \"#{query}\"", url: url) unless parsed.is_a?(Hash)

      if parsed['resource_response'] && !parsed['resource_response'].is_a?(Hash)
        raise PinterestDL::InvalidResponseError.new("Malformed resource_response for \"#{query}\"", url: url)
      end

      parsed
    rescue JSON::ParserError, TypeError => e
      raise PinterestDL::NotFoundError.new("No search results for \"#{query}\"", url: url, cause_error: e)
    end
  end
end
