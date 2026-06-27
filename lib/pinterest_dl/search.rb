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

    def call(query, limit: 25, pages: 5, type: :all)
      raise ArgumentError, 'query must not be empty' if query.to_s.strip.empty?

      session = establish_session(query)
      results = collect_pages(session, query, limit: limit, pages: pages, type: type)
      if results.empty?
        fallback = PinterestDL::Extractors::PinData.extract_pins(session[:html], quality: @config.quality)
        results = PinterestDL::MediaType.filter(fallback, type)
      end
      results.first(limit)
    end

    private

    def collect_pages(session, query, limit:, pages:, type:)
      results = []
      seen = {}
      bookmarks = nil
      pages_fetched = 0

      loop do
        page = fetch_page(session, query, bookmarks: bookmarks)
        PinterestDL::MediaType.filter(page[:pins], type).each do |pin|
          next if seen[pin[:id]]

          seen[pin[:id]] = true
          results << pin
        end
        bookmarks = page[:bookmarks]
        pages_fetched += 1

        break if results.size >= limit || stop_pagination?(bookmarks, pages_fetched, pages, page[:pins])
      end

      results
    end

    def stop_pagination?(bookmarks, pages_fetched, max_pages, pins)
      bookmarks.nil? || bookmarks.empty? || bookmarks == ['-end-'] || pages_fetched >= max_pages || pins.empty?
    end

    def fetch_page(session, query, bookmarks: nil)
      body = @client.get(
        build_search_url(session[:source_path], query, bookmarks),
        use_cache: false,
        headers: search_headers(session)
      )

      json = safe_parse(body)
      raise PinterestDL::NotFoundError, "No search results for \"#{query}\"" unless json

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
      options = { query: query, scope: 'pins', page_size: 25 }
      options[:bookmarks] = bookmarks if bookmarks && !bookmarks.empty?
      data = { options: options, context: {} }.to_json

      res_uri = URI(S_URL)
      res_uri.query = URI.encode_www_form('source_url' => source_path, 'data' => data)
      res_uri.to_s
    end

    def search_headers(session)
      cookie_header = [@config.cookies, session[:cookies].join('; ')].compact.reject(&:empty?).join('; ')
      headers = {
        'Accept' => 'application/json, text/javascript, */*, q=0.01',
        'X-Requested-With' => 'XMLHttpRequest',

# step-5
