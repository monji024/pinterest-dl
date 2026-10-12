# frozen_string_literal: true

require_relative '../test_helper'

class BoardTest < Minitest::Test
  BOARD_PAGE = %r{pinterest\.com/someuser/someboard/?\z}.freeze
  BOARD_INFO = { resource_response: { data: { id: 'B1' } } }.to_json

  def pin_json(id, video: false)
    pin = { id: id, images: { orig: { url: "https://i.pinimg.com/originals/#{id}.jpg" } } }
    pin[:videos] = { video_list: { V_720P: { url: "https://v1.pinimg.com/videos/#{id}.mp4", width: 720, height: 1280 } } } if video
    pin
  end

  def feed_json(pins, bookmark: '-end-')
    { resource_response: { data: pins, bookmark: bookmark } }.to_json
  end

  def build_board(feed, raw_headers: {})
    client = FakeClient.new(
      { BOARD_PAGE => '<html>board page</html>',
        %r{BoardResource} => BOARD_INFO,
        %r{BoardFeedResource} => feed },
      raw_headers: raw_headers
    )
    [PinterestDL::Board.new(client: client, config: PinterestDL::Configuration.new), client]
  end

  def test_raises_invalid_url_for_non_board_url
    board = PinterestDL::Board.new(client: FakeClient.new, config: PinterestDL::Configuration.new)
    assert_raises(PinterestDL::InvalidURLError) { board.call('https://example.com/not-a-board') }
  end

  def test_raises_invalid_url_for_pin_url
    board = PinterestDL::Board.new(client: FakeClient.new, config: PinterestDL::Configuration.new)
    assert_raises(PinterestDL::InvalidURLError) { board.call('https://www.pinterest.com/pin/123456/') }
  end

  def test_fetches_pins_using_board_id_and_csrf_token
    board, client = build_board(
      feed_json([{ id: '1', title: 'Pin one', images: { orig: { url: 'https://i.pinimg.com/originals/a.jpg' } } }]),
      raw_headers: { BOARD_PAGE => { 'set-cookie' => ['csrftoken=abc123; Path=/', 'sessionid=xyz; Path=/'] } }
    )

    pins = board.call('https://www.pinterest.com/someuser/someboard/', limit: 10)

    assert_equal 1, pins.size
    assert_equal 'https://i.pinimg.com/originals/a.jpg', pins.first[:image_url]

    feed_call = client.calls.find { |u| u.include?('BoardFeedResource') }
    refute_nil feed_call
    assert_includes CGI.unescape(feed_call), '"board_id":"B1"'
    assert_equal 'abc123', client.last_headers['X-CSRFToken']
  end

  def test_returns_empty_array_when_board_has_no_pins
    board, = build_board(feed_json([], bookmark: nil))
    assert_equal [], board.call('https://www.pinterest.com/someuser/someboard/')
  end

  def test_share_link_with_invite_code_is_not_read_as_a_section
    board, client = build_board(feed_json([pin_json('1')]))

    pins = board.call('https://www.pinterest.com/someuser/someboard/?invite_code=abc&sender=1')

    assert_equal 1, pins.size
    assert(client.calls.none? { |u| u.include?('BoardSectionPinsResource') })
  end

  def test_raises_not_found_when_board_id_is_missing
    client = FakeClient.new(
      { BOARD_PAGE => '<html></html>', %r{BoardResource} => { resource_response: { data: nil } }.to_json }
    )
    board = PinterestDL::Board.new(client: client, config: PinterestDL::Configuration.new)

    assert_raises(PinterestDL::NotFoundError) { board.call('https://www.pinterest.com/someuser/someboard/') }
  end

  def test_type_video_keeps_only_video_pins
    board, = build_board(feed_json([pin_json('1'), pin_json('2', video: true)]))

    pins = board.call('https://www.pinterest.com/someuser/someboard/', type: :video)

    assert_equal ['2'], pins.map { |p| p[:id] }
    assert_equal 'https://v1.pinimg.com/videos/2.mp4', pins.first[:video_url]
  end

  def test_type_image_skips_video_pins
    board, = build_board(feed_json([pin_json('1'), pin_json('2', video: true)]))

    pins = board.call('https://www.pinterest.com/someuser/someboard/', type: :image)

    assert_equal ['1'], pins.map { |p| p[:id] }
  end
end
