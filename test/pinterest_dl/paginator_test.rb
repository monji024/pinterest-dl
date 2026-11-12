# frozen_string_literal: true

require_relative '../test_helper'

class PaginatorTest < Minitest::Test
  def test_paginates_across_multiple_pages_until_limit_or_end
    pages = [
      { pins: [{ id: '1', image_url: 'https://i.pinimg.com/originals/1.jpg' }], bookmarks: ['bm_1'] },
      { pins: [{ id: '2', image_url: 'https://i.pinimg.com/originals/2.jpg' }], bookmarks: ['bm_2'] },
      { pins: [{ id: '3', image_url: 'https://i.pinimg.com/originals/3.jpg' }], bookmarks: ['-end-'] }
    ]

    paginator = PinterestDL::Paginator.new(max_pages: 5, limit: 2) do |_bm, idx|
      pages[idx]
    end

    results = paginator.to_a
    assert_equal(%w[1 2], results.map { |p| p[:id] })
  end

  def test_stops_automatically_when_bookmark_repeats_to_prevent_infinite_loop
    calls = 0
    paginator = PinterestDL::Paginator.new(max_pages: 10, limit: 50) do |_bm, _idx|
      calls += 1
      {
        pins: [{ id: calls.to_s, image_url: "https://i.pinimg.com/originals/#{calls}.jpg" }],
        bookmarks: ['stuck_cursor']
      }
    end

    results = paginator.to_a
    assert_equal 2, calls
    assert_equal(%w[1 2], results.map { |p| p[:id] })
  end

  def test_deduplicates_pins_with_same_id_across_pages
    pages = [
      { pins: [{ id: '10', image_url: 'https://i.pinimg.com/originals/10.jpg' }], bookmarks: ['bm_next'] },
      { pins: [{ id: '10', image_url: 'https://i.pinimg.com/originals/10.jpg' },
               { id: '11', image_url: 'https://i.pinimg.com/originals/11.jpg' }], bookmarks: ['-end-'] }
    ]

    paginator = PinterestDL::Paginator.new(max_pages: 5) { |_bm, idx| pages[idx] }
    assert_equal(%w[10 11], paginator.map { |p| p[:id] })
  end
end
