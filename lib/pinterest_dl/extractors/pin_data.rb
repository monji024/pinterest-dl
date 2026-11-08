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
        creator = extract_creator(raw)

        {
          id: id.to_s,
          pin_url: "https://www.pinterest.com/pin/#{id}/",
          title: title,
          description: description,
          creator: creator,
          image_url: img && PinterestDL::Extractors::Image.apply_quality(img, quality),
          video_url: video
        }
      end

      def build_result(pin)
        {
          image_url: best_image_url(pin),
          video_url: first_video_url(pin),
          title: extract_text_field(pin['title']) || extract_text_field(pin['grid_title']),
          description: extract_text_field(pin['description']) || extract_text_field(pin['closeup_unified_description']),
          creator: extract_creator(pin)
        }
      end

      def extract_text_field(val)
        case val
        when String then val
        when Hash then val['text'] || val['format']
        end
      end

      def extract_creator(pin)
        pin.dig('pinner', 'username') ||
          pin.dig('pinner', 'full_name') ||
          pin.dig('native_creator', 'username') ||
          pin.dig('origin_pinner', 'username')
      end

      def best_image_url(pin)
        return nil unless pin.is_a?(Hash)

        orig = pin.dig('images', 'orig', 'url') || pin.dig('images', 'originals', 'url')
        return orig if orig.is_a?(String) && !orig.empty?

        images = pin['images'] || pin['image_spec']
        if images.is_a?(Hash)
          candidates = images.filter_map do |bucket_key, entry|
            next unless entry.is_a?(Hash) && entry['url'].is_a?(String) && !entry['url'].empty?

            [score_image_variant(bucket_key.to_s, entry), entry['url']]
          end
          return candidates.max_by(&:first).last unless candidates.empty?
        elsif images.is_a?(Array)
          candidates = images.filter_map do |entry|
            next unless entry.is_a?(Hash) && entry['url'].is_a?(String) && !entry['url'].empty?

            [score_image_variant('', entry), entry['url']]
          end
          return candidates.max_by(&:first).last unless candidates.empty?
        end

        story_img = deep_find_image(pin['story_pin_data'])
        return story_img if story_img

        pin['image_large_url'] || pin['image_medium_url']
      end

      def score_image_variant(bucket_key, entry)
        key = bucket_key.to_s.downcase
        priority = IMAGE_BUCKET_PRIORITY[key] || 0
        width = entry['width'].to_i
        height = entry['height'].to_i
        area = width.positive? && height.positive? ? (width * height) : 0
        url_score = Image.score_url_quality(entry['url']) * 1_000
        priority + area + url_score
      end

      def deep_find_image(node)
        return nil unless node

        stack = [node]
        best = nil
        best_score = -1
        until stack.empty?
          current = stack.pop
          case current
          when Hash
            if current['images'].is_a?(Hash)
              url = best_image_url(current)
              if url
                score = Image.score_url_quality(url)
                if score > best_score
                  best = url
                  best_score = score
                end
              end
            end
            stack.concat(current.values)
          when Array
            stack.concat(current)
          end

# step-1
