# frozen_string_literal: true

require 'json'

module PinterestDL
  module Extractors
    module PinData
      SCRIPT_PATTERN =
        %r{<script[^>]*(?:id=["']__PWS_[A-Z_]+__["']|data-relay-response=["']true["'])[^>]*>(.*?)</script>}m.freeze

      module_function

      def extract(html, pin_id = nil)
        found = nil
        html.to_s.scan(SCRIPT_PATTERN).each do |(raw)|
          data = safe_parse(raw)
          pin = data && find_pin_node(data, pin_id)
          next unless pin

          result = build_result(pin)
          return result if result[:video_url]

          found ||= result
        end
        found
      end

      def extract_pins(html, quality: :originals)
        pins = []
        html.to_s.scan(SCRIPT_PATTERN).each do |(raw)|
          stack = [safe_parse(raw)]
          until stack.empty?
            node = stack.pop
            case node
            when Hash
              pin = build_pin_hash(node, quality: quality)
              pins << pin if pin
              stack.concat(node.values)
            when Array
              stack.concat(node)
            end
          end
        end
        pins
      end

      def build_pin_hash(raw, quality: :originals)
        return nil unless raw.is_a?(Hash)
        return nil if raw['type'] && raw['type'] != 'pin'

        id = raw['id']
        img = best_image_url(raw)
        video = first_video_url(raw)
        return nil unless id && (img || video)

        {
          id: id.to_s,
          pin_url: "https://www.pinterest.com/pin/#{id}/",
          title: raw['title'] || raw['grid_title'],
          description: raw['description'],
          creator: raw.dig('pinner', 'username') || raw.dig('pinner', 'full_name'),
          image_url: img && PinterestDL::Extractors::Image.apply_quality(img, quality),
          video_url: video
        }
      end

      def build_result(pin)
        {
          image_url: best_image_url(pin),
          video_url: first_video_url(pin),
          title: pin['title'] || pin['grid_title'],
          description: pin['description'],
          creator: pin.dig('pinner', 'username') || pin.dig('pinner', 'full_name')
        }
      end

      def best_image_url(pin)
        return nil unless pin.is_a?(Hash)

# step-3
