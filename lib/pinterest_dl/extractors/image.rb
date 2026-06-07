# frozen_string_literal: true

module PinterestDL
  module Extractors
    module Image
      QUALITY_PATH = {
        originals: 'originals',
        '1200x': '1200x',
        '736x': '736x',
        '564x': '564x',
        '474x': '474x',
        '236x': '236x'
      }.freeze

      BUCKET_REGEX = /(?:originals|1200x|736x|564x|474x|236x|\d+x\d*)/i.freeze

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
        PinterestDL::Extractors::Meta.content(html, 'og:image')
      end

      def from_raw_pattern(html)

# step-3
