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
      yielded = 0

      loop do
        page = @page_fetcher.call(bookmarks, pages_fetched)
        break unless page.is_a?(Hash)

        raw_pins = Array(page[:pins])
        filtered_pins = MediaType.filter(raw_pins, @type)

        filtered_pins.each do |pin|
          pin_id = pin[:id].to_s
          next if !pin_id.empty? && seen_pin_ids[pin_id]

          seen_pin_ids[pin_id] = true unless pin_id.empty?
          yield pin
          yielded += 1
          break if @limit && yielded >= @limit
        end
        break if @limit && yielded >= @limit

        next_bookmarks = normalize_bookmarks(page[:bookmarks])
        pages_fetched += 1

        break if stop?(next_bookmarks, seen_bookmarks, pages_fetched, raw_pins)

        seen_bookmarks[bookmark_signature(next_bookmarks)] = true
        bookmarks = next_bookmarks
      end
    end

    def collect
      to_a
    end

    private

    def normalize_bookmarks(raw)
      Array(raw).flatten.map { |b| b.to_s.strip }.reject(&:empty?)
    end

    def bookmark_signature(bookmarks)
      bookmarks.join('|')
    end

    def stop?(bookmarks, seen_bookmarks, pages_fetched, raw_pins)
      return true if pages_fetched >= @max_pages
      return true if raw_pins.empty?
      return true if bookmarks.empty?
      return true if bookmarks.all? { |b| END_MARKERS.include?(b.downcase) }
      return true if seen_bookmarks[bookmark_signature(bookmarks)]

      false
    end
  end
end
