# frozen_string_literal: true

require 'json'

module PinterestDL
  module Extractors
    module PinData
      SCRIPT_PATTERN = %r{<script[^>]*id=["']__PWS_[A-Z_]+__["'][^>]*>(.*?)</script>}m.freeze

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

      def build_result(pin)
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

      def find_pin_node(data, pin_id = nil)
        matches = []
        stack = [data]
        until stack.empty?
          node = stack.pop
          case node
          when Hash
            if pin_id
              matches << node if node['id'].to_s == pin_id.to_s && has_media?(node)
            elsif pin_like?(node)
              return node
            end
            stack.concat(node.values)
          when Array
            stack.concat(node)
          end
        end
        matches.find { |n| first_video_url(n) } || matches.first
      end

      def pin_like?(node)
        images = node['images']
        images.is_a?(Hash) && images.dig('orig', 'url')
      end

      def has_media?(node)
        node['images'].is_a?(Hash) || node['videos'].is_a?(Hash) || node['story_pin_data'].is_a?(Hash)
      end

      def first_video_url(pin)
        video_list = pin.dig('videos', 'video_list')
        video_list = deep_find(pin['story_pin_data'], 'video_list') unless video_list.is_a?(Hash)
        best_video(video_list)
      end

      def best_video(video_list)
        return nil unless video_list.is_a?(Hash)

        formats = video_list.values.select { |v| v.is_a?(Hash) && v['url'] }
        mp4s = formats.select { |v| v['url'].include?('.mp4') }
        best = mp4s.max_by { |v| v['width'].to_i * v['height'].to_i }
        return best['url'] if best

        hls = formats.find { |v| v['url'].include?('.m3u8') }
        hls && hls_to_mp4(hls['url'])
      end

      def hls_to_mp4(url)
        if url.include?('/iht/hls/')
          url.sub('/hls/', '/expMp4/').sub(/\.m3u8.*\z/, '_720w.mp4')
        else
          url.sub('/hls/', '/720p/').sub(/\.m3u8.*\z/, '.mp4')
        end
      end

      def deep_find(node, key)
        stack = [node]
        until stack.empty?
          current = stack.pop
          case current
          when Hash
            return current[key] if current[key].is_a?(Hash)

            stack.concat(current.values)
          when Array
            stack.concat(current)
          end
        end
        nil
      end

      def safe_parse(raw)
        JSON.parse(raw)
      rescue JSON::ParserError
        nil
      end
    end
  end
end
