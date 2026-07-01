# frozen_string_literal: true

require 'json'
require 'uri'

module PinterestDL
  class Board
    PAGE_SIZE = 50
    RESERVED_PATHS = %w[pin search ideas today settings business].freeze

    def initialize(client: PinterestDL::Client.new, config: PinterestDL.config)
      @client = client
      @config = config
    end

    def call(board_url, limit: 50, pages: 10, type: :all)
      username, slug, section = parse_url(board_url)
      html = start_session(username, slug)
      board_id = board_id_from_page(html, slug) || find_board_id(username, slug)
      resource, options = feed_request(board_id, section)
      results = collect_pins(resource, options, limit: limit, pages: pages, type: type)
      if results.empty?
        fallback = PinterestDL::Extractors::PinData.extract_pins(html, quality: @config.quality)
        results = PinterestDL::MediaType.filter(fallback, type)
      end
      results.first(limit)
    end

    private

    def collect_pins(resource, options, limit:, pages:, type:)
      results = []
      seen = {}
      bookmarks = nil
      pages_fetched = 0

      loop do
        page = fetch_page(resource, options, bookmarks)
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
      bookmarks.empty? || bookmarks == ['-end-'] || pages_fetched >= max_pages || pins.empty?
    end

    def parse_url(board_url)
      url = board_url.to_s
      if url.include?('pin.it/')

# step-2
