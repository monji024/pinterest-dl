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

# step-3
