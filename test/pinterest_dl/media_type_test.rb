# frozen_string_literal: true

require_relative '../test_helper'

class MediaTypeTest < Minitest::Test
  PINS = [
    { id: '1', image_url: 'https://i.pinimg.com/originals/a.jpg', video_url: nil },
    { id: '2', image_url: 'https://i.pinimg.com/originals/b.jpg', video_url: 'https://v1.pinimg.com/videos/b.mp4' }
  ].freeze

  def test_image_keeps_pins_without_video
    assert_equal ['1'], PinterestDL::MediaType.filter(PINS, :image).map { |p| p[:id] }
  end

  def test_video_keeps_pins_with_video
    assert_equal ['2'], PinterestDL::MediaType.filter(PINS, :video).map { |p| p[:id] }
  end

  def test_all_and_pin_keep_everything
    assert_equal 2, PinterestDL::MediaType.filter(PINS, :all).size
    assert_equal 2, PinterestDL::MediaType.filter(PINS, :pin).size
  end

  def test_parse_defaults_to_all_and_rejects_unknown
    assert_equal :all, PinterestDL::MediaType.parse(nil)
    assert_equal :video, PinterestDL::MediaType.parse('video')
    assert_raises(ArgumentError) { PinterestDL::MediaType.parse(:gif) }
  end
end
