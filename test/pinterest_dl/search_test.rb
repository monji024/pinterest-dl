# frozen_string_literal: true

require_relative '../test_helper'

class SearchTest < Minitest::Test
  SEARCH_PAGE = %r{pinterest\.com/search/pins/}.freeze

  def pin_node(id, video: false)
    node = {
      id: id,
      title: "Pin #{id}",
      pinner: { username: 'maker' },
      images: { orig: { url: "https://i.pinimg.com/originals/#{id}.jpg" } }
    }
    if video
      node[:videos] = {
        video_list: { V_720P: { url: "https://v1.pinimg.com/videos/#{id}.mp4", width: 720, height: 1280 } }
      }
    end
    node
  end

  def search_json(results, bookmark: '-end-')
    { resource_response: { data: { results: results }, bookmark: bookmark } }.to_json
  end

  def test_fetches_search_results_and_parses_pins
    client = FakeClient.new(
      { SEARCH_PAGE => '<html></html>', %r{BaseSearchResource} => search_json([pin_node('10')]) },
      raw_headers: { SEARCH_PAGE => { 'set-cookie' => ['csrftoken=tok1; Path=/'] } }
    )
    search = PinterestDL::Search.new(client: client, config: PinterestDL::Configuration.new)

    pins = search.call('cyberpunk', limit: 5)
    assert_equal 1, pins.size
    assert_equal '10', pins.first[:id]
    assert_equal 'maker', pins.first[:creator]
    assert_equal 'tok1', client.last_headers['X-CSRFToken']
  end

  def test_establishes_session_only_once_across_pages
    pages = [
      search_json([pin_node('1')], bookmark: 'next_bm'),
      search_json([pin_node('2')], bookmark: '-end-')
    ]
    client = FakeClient.new({ SEARCH_PAGE => '<html></html>', %r{BaseSearchResource} => pages })
    search = PinterestDL::Search.new(client: client, config: PinterestDL::Configuration.new)

    pins = search.call('cats', limit: 2, pages: 3)

# step-0
