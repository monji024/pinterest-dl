# frozen_string_literal: true


require_relative '../test_helper'

class ApiTest < Minitest::Test
  def test_get_image_url_returns_extracted_url
    html = '<meta property="og:image" content="https://i.pinimg.com/originals/aa/bb/img.jpg">'
    client = FakeClient.new({ %r{pinterest\.com/pin} => html })

    url = PinterestDL.get_image_url('https://www.pinterest.com/pin/123456789/', client: client)
    assert_equal 'https://i.pinimg.com/originals/aa/bb/img.jpg', url
  end

  def test_get_image_url_raises_on_invalid_url
    assert_raises(PinterestDL::InvalidURLError) do
      PinterestDL.get_image_url('https://example.com/not-a-pin')
    end
  end

  def test_get_image_url_accepts_pin_it_short_links
    html = '<meta property="og:image" content="https://i.pinimg.com/originals/aa/bb/img.jpg">'
    client = FakeClient.new({ %r{pin\.it/} => html })

    url = PinterestDL.get_image_url('https://pin.it/7k7wPsqPO', client: client)
    assert_equal 'https://i.pinimg.com/originals/aa/bb/img.jpg', url
  end

  def test_get_image_url_prefers_embedded_pin_data_over_scraping
    html = <<~HTML
      <meta property="og:image" content="https://i.pinimg.com/originals/wrong/og.jpg">
      <script id="__PWS_DATA__" type="application/json">
      {"pins":{"123456789":{"id":"123456789","images":{"orig":{"url":"https://i.pinimg.com/originals/correct/data.jpg"}}}}}
      </script>
    HTML
    client = FakeClient.new({ %r{pinterest\.com/pin} => html })

    url = PinterestDL.get_image_url('https://www.pinterest.com/pin/123456789/', client: client)
    assert_equal 'https://i.pinimg.com/originals/correct/data.jpg', url
  end

  def test_get_image_url_raises_not_found_when_nothing_extracted
    client = FakeClient.new({ %r{PinResource} => '{}', %r{pinterest\.com/pin} => '<html><body>empty</body></html>' })
    assert_raises(PinterestDL::NotFoundError) do
      PinterestDL.get_image_url('https://www.pinterest.com/pin/123456789/', client: client)
    end
  end

  def test_get_video_url_returns_extracted_url
    html = '<meta property="og:video" content="https://v.pinimg.com/videos/mc/720p/clip.mp4">'
    client = FakeClient.new({ %r{pinterest\.com/pin} => html })

    url = PinterestDL.get_video_url('https://www.pinterest.com/pin/123456789/', client: client)
    assert_equal 'https://v.pinimg.com/videos/mc/720p/clip.mp4', url
  end

  def test_country_domain_pin_is_fetched_from_www
    html = '<meta property="og:image" content="https://i.pinimg.com/originals/aa/bb/img.jpg">'
    client = FakeClient.new({ %r{pinterest\.com/pin} => html })

    PinterestDL.get_image_url('https://de.pinterest.com/pin/174373816821185504/', client: client)
    assert_equal ['https://www.pinterest.com/pin/174373816821185504/'], client.calls
  end

  def test_get_image_url_uses_the_requested_pin_not_a_related_one
    html = <<~HTML
      <script id="__PWS_DATA__" type="application/json">

# step-0
