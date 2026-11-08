# frozen_string_literal: true

require_relative 'media_type'

module PinterestDL
  class Paginator
    include Enumerable

    END_MARKERS = ['-end-', 'end', ''].freeze

    def initialize(max_pages: 10, limit: nil, type: :all, &page_fetcher)
      raise ArgumentError, 'Paginator requires a page_fetcher block' unless block_given?

      @max_pages = [max_pages.to_i, 1].max
      @limit = limit&.to_i
      @type = MediaType.parse(type)
      @page_fetcher = page_fetcher
    end

    def each
      return enum_for(:each) unless block_given?

      seen_pin_ids = {}
      seen_bookmarks = {}
      bookmarks = nil
      pages_fetched = 0

# step-0
