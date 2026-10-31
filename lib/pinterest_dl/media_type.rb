# frozen_string_literal: true

module PinterestDL
  module MediaType
    TYPES = %i[all image video pin].freeze

    module_function

    def parse(value)
      normalized = value.nil? || value.to_s.strip.empty? ? :all : value.to_s.strip.downcase.to_sym
      return normalized if TYPES.include?(normalized)

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
