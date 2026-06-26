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


# step-2
