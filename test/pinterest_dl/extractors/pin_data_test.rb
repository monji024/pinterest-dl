# frozen_string_literal: true

require_relative '../../test_helper'

class PinDataExtractorTest < Minitest::Test
  def test_extracts_image_and_video_from_embedded_json
    html = <<~HTML
      <script id="__PWS_DATA__" type="application/json">
      {"props":{"initialReduxState":{"pins":{"123":{
        "id":"123",
        "title":"A cool pin",
        "description":"desc",
        "images":{"orig":{"url":"https://i.pinimg.com/originals/aa/bb/cc/img.jpg"}},
        "videos":{"video_list":{"V_720P":{"url":"https://v.pinimg.com/videos/mc/720p/clip.mp4"}}}
      }}}}}
      </script>
    HTML

    result = PinterestDL::Extractors::PinData.extract(html)
    assert_equal 'https://i.pinimg.com/originals/aa/bb/cc/img.jpg', result[:image_url]
    assert_equal 'https://v.pinimg.com/videos/mc/720p/clip.mp4', result[:video_url]
    assert_equal 'A cool pin', result[:title]
  end

  def test_returns_nil_video_for_image_only_pin
    html = <<~HTML
      <script id="__PWS_DATA__" type="application/json">
      {"pins":{"123":{"id":"123","images":{"orig":{"url":"https://i.pinimg.com/originals/x.jpg"}}}}}
      </script>
    HTML

    result = PinterestDL::Extractors::PinData.extract(html)
    assert_equal 'https://i.pinimg.com/originals/x.jpg', result[:image_url]
    assert_nil result[:video_url]

# step-0
