# frozen_string_literal: true

require_relative '../test_helper'

class BoardTest < Minitest::Test
  def test_raises_invalid_url_for_non_board_url
    board = PinterestDL::Board.new(client: FakeClient.new, config: PinterestDL::Configuration.new)
    assert_raises(PinterestDL::InvalidURLError) { board.call('https://example.com/not-a-board') }
  end

  def test_fetches_pins_using_session_cookie_and_csrf_token
    resource_json = {
      resource_response: {
        data: [
          { id: '1', title: 'Pin one', images: { orig: { url: 'https://i.pinimg.com/originals/a.jpg' } } }
        ],
        bookmark: '-end-'
      }
    }.to_json

    client = FakeClient.new(
      { %r{pinterest\.com/someuser/someboard/?\z} => '<html>board page</html>',
        %r{BoardFeedResource} => resource_json },
      raw_headers: {
        %r{pinterest\.com/someuser/someboard/?\z} => {
          'set-cookie' => ['csrftoken=abc123; Path=/', 'sessionid=xyz; Path=/']
        }
      }
    )
    board = PinterestDL::Board.new(client: client, config: PinterestDL::Configuration.new)

    pins = board.call('https://www.pinterest.com/someuser/someboard/', limit: 10)

    assert_equal 1, pins.size
    assert_equal 'https://i.pinimg.com/originals/a.jpg', pins.first[:image_url]

    resource_call_headers = client.calls.each_with_index.find { |u, _| u.include?('BoardFeedResource') }
    refute_nil resource_call_headers
  end

  def test_returns_empty_array_when_board_has_no_pins
    resource_json = { resource_response: { data: [], bookmark: nil } }.to_json
    client = FakeClient.new(
      { %r{pinterest\.com/someuser/emptyboard/?\z} => '<html></html>',
        %r{BoardFeedResource} => resource_json }
    )
    board = PinterestDL::Board.new(client: client, config: PinterestDL::Configuration.new)

    assert_equal [], board.call('https://www.pinterest.com/someuser/emptyboard/')
  end

  def test_board_url_pattern_extracts_username_and_slug
    match = PinterestDL::Board::BOARD_URL_PATTERN.match('https://www.pinterest.com/someuser/someboard/')
    refute_nil match
    assert_equal 'someuser', match[:username]
    assert_equal 'someboard', match[:slug]
  end
end
