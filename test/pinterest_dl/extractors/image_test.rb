# frozen_string_literal: true

require_relative '../../test_helper'

class ImageExtractorTest < Minitest::Test
  def test_extracts_from_json_ld
    html = <<~HTML
      <script type="application/ld+json">
      {"@type": "ImageObject", "contentUrl": "https://i.pinimg.com/originals/aa/bb/cc/img.jpg"}
      </script>
    HTML
    assert_equal 'https://i.pinimg.com/originals/aa/bb/cc/img.jpg',
                 PinterestDL::Extractors::Image.extract(html)
  end

  def test_extracts_from_open_graph_when_no_json_ld
    html = '<meta property="og:image" content="https://i.pinimg.com/736x/aa/bb/img.jpg">'
    assert_equal 'https://i.pinimg.com/originals/aa/bb/img.jpg',
                 PinterestDL::Extractors::Image.extract(html)
  end

  def test_open_graph_result_keeps_its_bucket_when_quality_matches
    html = '<meta property="og:image" content="https://i.pinimg.com/736x/aa/bb/img.jpg">'
    assert_equal 'https://i.pinimg.com/736x/aa/bb/img.jpg',
                 PinterestDL::Extractors::Image.extract(html, quality: :'736x')
  end

  def test_extracts_from_raw_pattern_as_last_resort
    html = 'blah blah https://i.pinimg.com/474x/11/22/33/pic.png blah'
    assert_equal 'https://i.pinimg.com/originals/11/22/33/pic.png',
                 PinterestDL::Extractors::Image.extract(html)

# step-0
