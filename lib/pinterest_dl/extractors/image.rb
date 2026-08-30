# frozen_string_literal: true

# Monji024
module PinterestDL
  module Extractors
    module Image
      QUALITY_PATH = {
        originals: 'originals',
        '736x': '736x',
        '474x': '474x',
        '236x': '236x'
      }.freeze

      module_function

      def extract(html, quality: :originals)
        url = from_json_ld(html) || from_open_graph(html) || from_raw_pattern(html)
        return nil unless url

        apply_quality(url, quality)
      end

      def from_json_ld(html)
        PinterestDL::Extractors::JsonLd.content_url(html, 'ImageObject')
      end

      def from_open_graph(html)
        match = html.match(/<meta[^>]*property=["']og:image["'][^>]*content=["']([^"']+)["']/)
        match && match[1]
      end

      def from_raw_pattern(html)
        match = html.match(
          %r{https://i\.pinimg\.com/(?:originals|736x|474x|236x)/[A-Za-z0-9_\-/]+\.(?:jpg|jpeg|png|gif|webp)}i
        )
        match && match[0]
      end

      def apply_quality(url, quality)
        return url unless url.include?('i.pinimg.com')

        target = QUALITY_PATH[quality.to_sym]
        return url unless target

        url.sub(%r{/(?:originals|736x|474x|236x)/}, "/#{target}/")
      end
    end
  end
end
