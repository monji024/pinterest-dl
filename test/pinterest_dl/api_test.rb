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
      {"main":{"id":"123","images":{"orig":{"url":"https://i.pinimg.com/originals/main.jpg"}}},
       "related":[{"id":"999","images":{"orig":{"url":"https://i.pinimg.com/originals/related.jpg"}}}]}
      </script>
    HTML
    client = FakeClient.new({ %r{pinterest\.com/pin} => html })

    url = PinterestDL.get_image_url('https://www.pinterest.com/pin/123/', client: client)
    assert_equal 'https://i.pinimg.com/originals/main.jpg', url
  end

  def test_get_video_url_picks_the_best_mp4_over_hls
    html = <<~HTML
      <script id="__PWS_DATA__" type="application/json">
      {"pin":{"id":"5","images":{"orig":{"url":"https://i.pinimg.com/originals/t.jpg"}},
       "videos":{"video_list":{
         "V_HLSV3_MOBILE":{"url":"https://v1.pinimg.com/videos/mc/hls/a/b.m3u8"},
         "V_480P":{"url":"https://v1.pinimg.com/videos/mc/480p/a/b.mp4","width":480,"height":852},
         "V_720P":{"url":"https://v1.pinimg.com/videos/mc/720p/a/b.mp4","width":720,"height":1280}}}}}
      </script>
    HTML
    client = FakeClient.new({ %r{pinterest\.com/pin} => html })

    url = PinterestDL.get_video_url('https://www.pinterest.com/pin/5/', client: client)
    assert_equal 'https://v1.pinimg.com/videos/mc/720p/a/b.mp4', url
  end

  def test_get_video_url_error_mentions_image_pins
    html = '<meta property="og:image" content="https://i.pinimg.com/originals/aa/bb/img.jpg">'
    api = { resource_response: { data: { id: '123', images: { orig: { url: 'https://i.pinimg.com/originals/a.jpg' } } } } }
    client = FakeClient.new({ %r{PinResource} => api.to_json, %r{pinterest\.com/pin} => html })

    error = assert_raises(PinterestDL::NotFoundError) do
      PinterestDL.get_video_url('https://www.pinterest.com/pin/123/', client: client)
    end
    assert_includes error.message, 'looks like an image'
  end

  def test_get_video_url_falls_back_to_api_when_page_has_no_video
    page = '<meta property="og:image" content="https://i.pinimg.com/originals/aa/bb/thumb.jpg">'
    api = {
      resource_response: {
        data: {
          id: '123',
          images: { orig: { url: 'https://i.pinimg.com/originals/aa/bb/thumb.jpg' } },
          videos: { video_list: { V_720P: { url: 'https://v1.pinimg.com/videos/a/b.mp4', width: 720, height: 1280 } } }
        }
      }
    }.to_json
    client = FakeClient.new({ %r{PinResource} => api, %r{pinterest\.com/pin} => page })

    url = PinterestDL.get_video_url('https://www.pinterest.com/pin/123/', client: client)
    assert_equal 'https://v1.pinimg.com/videos/a/b.mp4', url
  end

  def test_get_image_url_falls_back_to_api_when_page_has_no_image
    api = { resource_response: { data: { images: { orig: { url: 'https://i.pinimg.com/originals/x/y.jpg' } } } } }
    client = FakeClient.new({ %r{PinResource} => api.to_json, %r{pinterest\.com/pin} => '<html></html>' })

    url = PinterestDL.get_image_url('https://www.pinterest.com/pin/123/', client: client)
    assert_equal 'https://i.pinimg.com/originals/x/y.jpg', url
  end

  def test_pin_resource_is_called_with_the_pws_handler_header
    page = '<meta property="og:image" content="https://i.pinimg.com/originals/aa/bb/thumb.jpg">'
    api = { resource_response: { data: { videos: { video_list: { V_720P: { url: 'https://v1.pinimg.com/v/a.mp4', width: 1, height: 1 } } } } } }
    client = FakeClient.new({ %r{PinResource} => api.to_json, %r{pinterest\.com/pin} => page })

    PinterestDL.get_video_url('https://www.pinterest.com/pin/123/', client: client)

# step-1
