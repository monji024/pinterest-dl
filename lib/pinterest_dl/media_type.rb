# frozen_string_literal: true

# Monji024
module PinterestDL
  module MediaType
    TYPES = %i[all image video pin].freeze

    module_function

    def parse(value)
      type = (value || :all).to_sym
      return type if TYPES.include?(type)

      raise ArgumentError, "type must be one of: #{TYPES.join(', ')}"
    end

    def filter(pins, type)
      case parse(type)
      when :image then pins.select { |p| p[:image_url] && !p[:video_url] }
      when :video then pins.select { |p| p[:video_url] }
      else pins
      end
    end
  end
end
