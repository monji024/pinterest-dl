# frozen_string_literal: true

# Monji024
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
      {"pins":{"1":{"images":{"orig":{"url":"https://i.pinimg.com/originals/correct/data.jpg"}}}}}
      </script>
    HTML
    client = FakeClient.new({ %r{pinterest\.com/pin} => html })

    url = PinterestDL.get_image_url('https://www.pinterest.com/pin/123456789/', client: client)
    assert_equal 'https://i.pinimg.com/originals/correct/data.jpg', url
  end

  def test_get_image_url_raises_not_found_when_nothing_extracted
    client = FakeClient.new({ %r{pinterest\.com/pin} => '<html><body>empty</body></html>' })
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

  def test_search_json_returns_pretty_json_string
    PinterestDL.stub(:search, [{ id: '1', image_url: 'https://i.pinimg.com/originals/a.jpg' }]) do
      json = PinterestDL.search_json('cats', limit: 1)
      parsed = JSON.parse(json)
      assert_equal '1', parsed.first['id']
    end
  end

  def test_search_images_filters_to_image_urls_only
    pins = [{ image_url: 'https://i.pinimg.com/originals/a.jpg', video_url: nil },
            { image_url: nil, video_url: 'https://v.pinimg.com/videos/b.mp4' }]
    PinterestDL.stub(:search, pins) do
      assert_equal ['https://i.pinimg.com/originals/a.jpg'], PinterestDL.search_images('cats')
    end
  end
end
