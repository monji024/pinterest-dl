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


# step-0
