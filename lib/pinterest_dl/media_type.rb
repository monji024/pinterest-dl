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

# step-1
