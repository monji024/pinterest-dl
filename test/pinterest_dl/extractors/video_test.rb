# frozen_string_literal: true

# Monji024
require_relative '../../test_helper'

class VideoExtractorTest < Minitest::Test
  def test_extracts_from_json_ld
    html = <<~HTML
      <script type="application/ld+json">
      {"@type": "VideoObject", "contentUrl": "https://v.pinimg.com/videos/mc/720p/aa\\u002Fbb.mp4"}
      </script>
    HTML
    assert_equal 'https://v.pinimg.com/videos/mc/720p/aa/bb.mp4',
                 PinterestDL::Extractors::Video.extract(html)
  end

  def test_extracts_from_open_graph
    html = '<meta property="og:video" content="https://v.pinimg.com/videos/mc/720p/clip.mp4">'
    assert_equal 'https://v.pinimg.com/videos/mc/720p/clip.mp4',
                 PinterestDL::Extractors::Video.extract(html)
  end

  def test_extracts_from_content_url_fallback
    html = '"contentUrl":"https://v.pinimg.com/videos/mc/720p/fallback.mp4"'
    assert_equal 'https://v.pinimg.com/videos/mc/720p/fallback.mp4',
                 PinterestDL::Extractors::Video.extract(html)
  end

  def test_returns_nil_for_pin_without_video
    assert_nil PinterestDL::Extractors::Video.extract('<html><body>image only pin</body></html>')
  end
end
