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

# step-2
