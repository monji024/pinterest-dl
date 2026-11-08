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


# step-0
