# frozen_string_literal: true

require 'json'
require_relative 'image'

module PinterestDL
  module Extractors
    module PinData
      SCRIPT_PATTERN = %r{
        <script[^>]*(?:
          id\s*=\s*["'](?:__PWS_[A-Z0-9_]+__|__NEXT_DATA__|initial-state)["'] |
          data-relay-response\s*=\s*["']true["'] |
          data-pinterest-state\s*=\s*["']true["']
        )[^>]*>(.*?)</script>
      }mix.freeze

      WINDOW_STATE_PATTERN = /
        window\.(?:__INITIAL_STATE__|__PWS_DATA__|__PWS_INITIAL_PROPS__)\s*=\s*(\{.*?\})\s*;?\s*<\/script>
      /mix.freeze

      IMAGE_BUCKET_PRIORITY = {
        'orig' => 1_000_000_000,
        'originals' => 1_000_000_000,
        '1200x' => 12_000_000,
        '736x' => 7_360_000,
        '600x' => 6_000_000,
        '564x' => 5_640_000,
        '474x' => 4_740_000,
        '236x' => 2_360_000,
        '170x' => 1_700_000,
        '136x136' => 18_496,
        '60x60' => 3_600
      }.freeze

      module_function

      def extract(html, pin_id = nil)
        found = nil
        each_script_payload(html) do |data|
          pin = find_pin_node(data, pin_id)
          next unless pin

          result = build_result(pin)
          return result if result[:video_url]

          found ||= result
        end
        found
      end

      def extract_pins(html, quality: :originals)
        pins = []
        seen = {}
        each_script_payload(html) do |data|
          stack = [data]
          until stack.empty?
            node = stack.pop
            case node
            when Hash
              pin = build_pin_hash(node, quality: quality)
              if pin && !seen[pin[:id]]
                seen[pin[:id]] = true
                pins << pin
              end
              stack.concat(node.values)
            when Array
              stack.concat(node)
            end
          end
        end
        pins
      end

      def each_script_payload(html)
        return enum_for(:each_script_payload, html) unless block_given?

        text = html.to_s
        text.scan(SCRIPT_PATTERN).each do |(raw)|
          parsed = safe_parse(raw)
          yield parsed if parsed
        end
        text.scan(WINDOW_STATE_PATTERN).each do |(raw)|
          parsed = safe_parse(raw)
          yield parsed if parsed
        end
      end

      def build_pin_hash(raw, quality: :originals)
        return nil unless raw.is_a?(Hash)
        return nil if raw['type'] && raw['type'] != 'pin'

        id = raw['id'] || raw['pin_id']
        return nil if id.nil? || id.to_s.strip.empty?

        img = best_image_url(raw)
        video = first_video_url(raw)
        return nil unless img || video

        title = extract_text_field(raw['title']) || extract_text_field(raw['grid_title'])
        description = extract_text_field(raw['description']) || extract_text_field(raw['closeup_unified_description'])

# step-0
