# frozen_string_literal: true

require 'json'

module PinterestDL
  module Extractors
    module PinData
      SCRIPT_PATTERN = %r{<script[^>]*id=["']__PWS_DATA__["'][^>]*>(.*?)</script>}m.freeze

      module_function

      def extract(html)
        data = parse_embedded_json(html)
        return nil unless data

        pin = find_pin_node(data)
        return nil unless pin

        {
          image_url: pin.dig('images', 'orig', 'url'),
          video_url: first_video_url(pin),
          title: pin['title'] || pin['grid_title'],
          description: pin['description']
        }
      end

      def parse_embedded_json(html)
        html.to_s.scan(SCRIPT_PATTERN).each do |(raw)|
          parsed = safe_parse(raw)
          return parsed if parsed
        end
        nil
      end

      def find_pin_node(data)
        stack = [data]
        until stack.empty?
          node = stack.pop
          case node
          when Hash
            return node if pin_like?(node)

            stack.concat(node.values)
          when Array
            stack.concat(node)
          end
        end
        nil
      end

      def pin_like?(node)
        images = node['images']
        images.is_a?(Hash) && images.dig('orig', 'url')
      end

      def first_video_url(pin)
        video_list = pin.dig('videos', 'video_list')
        return nil unless video_list.is_a?(Hash)

        video_list.values.first&.dig('url')
      end

      def safe_parse(raw)
        JSON.parse(raw)
      rescue JSON::ParserError
        nil
      end
    end
  end
end
