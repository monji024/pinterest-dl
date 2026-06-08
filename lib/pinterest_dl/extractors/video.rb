# frozen_string_literal: true

module PinterestDL
  module Extractors
    module Video
      module_function

      def extract(html)
        url = from_json_ld(html) || from_open_graph(html) || from_content_url(html) || from_raw_pattern(html)
        return nil unless url

        unescape(url)
      end

      def from_json_ld(html)
        PinterestDL::Extractors::JsonLd.content_url(html, 'VideoObject')
      end

      def from_open_graph(html)
        PinterestDL::Extractors::Meta.content(html, 'og:video')
      end

      def from_content_url(html)
        match = html.to_s.match(/"contentUrl"\s*:\s*"([^"]+\.mp4[^"]*)"/)
        match && match[1]
      end

      def from_raw_pattern(html)
        clean = html.to_s.gsub('\\u002F', '/').gsub('\\/', '/')
        match = clean.match(%r{https://v\d*\.pinimg\.com/videos/[^"'\s\\<>]+?\.mp4})
        match && match[0]
      end

      def unescape(url)
        url.to_s.gsub('\\u002F', '/').gsub('\\', '')
      end
    end

    module Meta
      module_function

      def content(html, key)
        html.to_s.scan(/<meta\b[^>]*>/i).each do |tag|
          next unless tag.match?(/(?:property|name)=["']#{Regexp.escape(key)}["']/i)

          match = tag.match(/content=["']([^"']+)["']/i)
          return match[1] if match
        end
        nil
      end
    end


# step-2
