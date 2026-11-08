# frozen_string_literal: true

require 'json'

module PinterestDL
  module Extractors
    module Video
      module_function

      def extract(html)
        url = from_json_ld(html) ||
              from_open_graph(html) ||
              from_video_tag(html) ||
              from_content_url(html) ||
              from_raw_pattern(html)
        return nil unless url

        unescape(url)
      end

      def from_json_ld(html)
        PinterestDL::Extractors::JsonLd.content_url(html, 'VideoObject')
      end

      def from_open_graph(html)
        PinterestDL::Extractors::Meta.content(html, 'og:video') ||
          PinterestDL::Extractors::Meta.content(html, 'og:video:secure_url') ||
          PinterestDL::Extractors::Meta.content(html, 'og:video:url')
      end

      def from_video_tag(html)
        html.to_s.scan(/<(?:video|source)\b[^>]*\bsrc=["']([^"']+\.mp4[^"']*)["'][^>]*>/i).each do |(src)|
          return src if src.include?('pinimg.com')
        end
        nil
      end

      def from_content_url(html)
        match = html.to_s.match(/"contentUrl"\s*:\s*"([^"]+\.mp4[^"]*)"/)
        match && match[1]
      end

      def from_raw_pattern(html)
        clean = html.to_s.gsub('\\u002F', '/').gsub('\\/', '/')
        matches = clean.scan(%r{https://v\d*\.pinimg\.com/videos/[^"'\s\\<>]+?\.mp4})
        return nil if matches.empty?

        matches.max_by { |u| score_video_url(u) }
      end

      def score_video_url(url)
        str = url.to_s
        return 1080 if str.include?('/1080p/') || str.include?('_1080w')
        return 720 if str.include?('/720p/') || str.include?('_720w') || str.include?('/expMp4/')
        return 540 if str.include?('/540p/')
        return 480 if str.include?('/480p/')
        return 360 if str.include?('/360p/')

        100
      end

      def unescape(url)
        url.to_s.gsub('\\u002F', '/').gsub('\\', '')
      end
    end

    module Meta
      module_function

      def content(html, key)
        escaped = Regexp.escape(key)
        html.to_s.scan(/<meta\b[^>]*>/i).each do |tag|
          next unless tag.match?(/\b(?:property|name|itemprop)\s*=\s*["']#{escaped}["']/i)

          match = tag.match(/\bcontent\s*=\s*["']([^"']+)["']/i)
          return match[1] if match
        end
        nil
      end
    end

    module JsonLd
      module_function

      def content_url(html, type)
        html.to_s.scan(%r{<script[^>]*type\s*=\s*["']application/ld\+json["'][^>]*>(.*?)</script>}mi).each do |(raw)|
          found = find_type_url(safe_parse(raw), type)
          return found if found
        end
        nil
      end

      def find_type_url(node, type)
        stack = [node]
        until stack.empty?
          current = stack.pop
          case current
          when Hash
            node_types = Array(current['@type']).map(&:to_s)
            if node_types.include?(type)
              url = current['contentUrl'] || current['url']
              return url if url.is_a?(String) && !url.empty?
            end
            stack.concat(current.values)
          when Array
            stack.concat(current)
          end
        end
        nil
      end

      def safe_parse(raw)
        JSON.parse(raw.to_s.strip)
      rescue JSON::ParserError
        nil
      end
    end
  end
end
