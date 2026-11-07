# frozen_string_literal: true

require 'json'

module PinterestDL
  class Pin
    ATTRIBUTES = %i[id pin_url title description creator image_url video_url width height].freeze

    attr_reader(*ATTRIBUTES)

    def initialize(id:, pin_url: nil, title: nil, description: nil, creator: nil,
                   image_url: nil, video_url: nil, width: nil, height: nil)
      @id = id.to_s
      @pin_url = pin_url || "https://www.pinterest.com/pin/#{@id}/"
      @title = title
      @description = description
      @creator = creator
      @image_url = image_url
      @video_url = video_url
      @width = width
      @height = height
    end

    def [](key)
      sym = key.to_sym
      return nil unless ATTRIBUTES.include?(sym)

      public_send(sym)
    end

    def dig(first_key, *rest)
      val = self[first_key]
      return val if rest.empty? || val.nil?

      val.respond_to?(:dig) ? val.dig(*rest) : nil
    end

    def fetch(key, *default, &block)
      sym = key.to_sym
      return public_send(sym) if ATTRIBUTES.include?(sym)
      return yield(key) if block
      return default.first unless default.empty?

      raise KeyError, "key not found: #{key.inspect}"
    end

    def key?(key)
      ATTRIBUTES.include?(key.to_sym)
    end
    alias has_key? key?
    alias include? key?

    def video?
      !@video_url.nil? && !@video_url.empty?
    end

    def image?
      !@image_url.nil? && !@image_url.empty? && !video?
    end

    def media_type
      video? ? :video : :image
    end

    def primary_media_url
      @video_url || @image_url
    end

    def to_h
      {
        id: @id,
        pin_url: @pin_url,
        title: @title,
        description: @description,
        creator: @creator,
        image_url: @image_url,
        video_url: @video_url
      }
    end
    alias to_hash to_h

    def deconstruct_keys(_keys)
      to_h
    end

# step-1
