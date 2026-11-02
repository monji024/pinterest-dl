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
    assert_equal %w[1 2], pins.map { |p| p[:id] }
    assert_equal 1, client.calls.count { |u| u.match?(SEARCH_PAGE) }
  end

  def test_filters_results_by_video_and_image_type
    payload = search_json([pin_node('1', video: false), pin_node('2', video: true)])
    client = FakeClient.new({ SEARCH_PAGE => '<html></html>', %r{BaseSearchResource} => payload })
    search = PinterestDL::Search.new(client: client, config: PinterestDL::Configuration.new)

    videos = search.call('clips', type: :video)
    assert_equal ['2'], videos.map { |p| p[:id] }
  end

  def test_handles_array_data_node_in_search_response
    payload = { resource_response: { data: [pin_node('77')], bookmark: '-end-' } }.to_json
    client = FakeClient.new({ SEARCH_PAGE => '<html></html>', %r{BaseSearchResource} => payload })
    search = PinterestDL::Search.new(client: client, config: PinterestDL::Configuration.new)

    pins = search.call('minimal')
    assert_equal ['77'], pins.map { |p| p[:id] }
  end

  def test_applies_configured_quality_to_search_images
    config = PinterestDL::Configuration.new
    config.quality = :'474x'
    client = FakeClient.new({ SEARCH_PAGE => '<html></html>', %r{BaseSearchResource} => search_json([pin_node('5')]) })
    search = PinterestDL::Search.new(client: client, config: config)

    pins = search.call('poster')
    assert_equal 'https://i.pinimg.com/474x/5.jpg', pins.first[:image_url]
  end

  def test_falls_back_to_embedded_html_pins_when_api_returns_empty
    html = '<script id="__PWS_DATA__" type="application/json">'            '{"pins":{"88":{"id":"88","images":{"orig":{"url":"https://i.pinimg.com/originals/88.jpg"}}}}}</script>'
    client = FakeClient.new({ SEARCH_PAGE => html, %r{BaseSearchResource} => search_json([]) })
    search = PinterestDL::Search.new(client: client, config: PinterestDL::Configuration.new)

    pins = search.call('fallback')
    assert_equal ['88'], pins.map { |p| p[:id] }
  end

  def test_raises_on_empty_query_and_invalid_json
    client = FakeClient.new({ SEARCH_PAGE => '<html></html>', %r{BaseSearchResource} => 'not-json' })
    search = PinterestDL::Search.new(client: client, config: PinterestDL::Configuration.new)

    assert_raises(ArgumentError) { search.call('   ') }
    assert_raises(PinterestDL::NotFoundError) { search.call('broken') }
  end
end
