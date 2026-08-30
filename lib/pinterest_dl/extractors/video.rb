# frozen_string_literal: true

# Monji024
module PinterestDL
  module Extractors
    module Video
      module_function

      def extract(html)
        url = from_json_ld(html) || from_open_graph(html) || from_content_url(html)
        return nil unless url

        unescape(url)
      end

      def from_json_ld(html)
        PinterestDL::Extractors::JsonLd.content_url(html, 'VideoObject')
      end

      def from_open_graph(html)
        match = html.match(/<meta[^>]*property=["']og:video["'][^>]*content=["']([^"']+)["']/)
        match && match[1]
      end

      def from_content_url(html)
        match = html.match(/"contentUrl"\s*:\s*"([^"]+\.mp4[^"]*)"/)
        match && match[1]
      end

      def unescape(url)
        url.gsub('\\u002F', '/').gsub('\\', '')
      end
    end

    module JsonLd
      module_function

      def content_url(html, type)
        html.to_s.scan(%r{<script[^>]*type=["']application/ld\+json["'][^>]*>(.*?)</script>}m).each do |(raw)|
          data = safe_parse(raw)
          next unless data

          data = data[0] if data.is_a?(Array) && !data.empty?
          next unless data.is_a?(Hash)

          return data['contentUrl'] if data['@type'] == type && data['contentUrl']
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
