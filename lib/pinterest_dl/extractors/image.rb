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

      QUALITY_RANK = {
        'orig' => 100,
        'originals' => 100,
        '1200x' => 80,
        '736x' => 60,
        '600x315' => 50,
        '564x' => 45,
        '474x' => 35,
        '236x' => 20,
        '170x' => 15,
        '136x136' => 10,
        '60x60' => 5
      }.freeze

      BUCKET_REGEX = /(?:originals|1200x|736x|564x|474x|236x|\d+x\d*)/i.freeze

      PINIMG_URL_REGEX = %r{
        https://i\d*\.pinimg\.com/
        (?:originals|1200x|736x|564x|474x|236x|\d+x\d*)/
        [A-Za-z0-9_\-/]+\.(?:jpg|jpeg|png|gif|webp)
      }ix.freeze

      module_function

      def extract(html, quality: :originals)
        url = from_json_ld(html) || from_open_graph(html) || from_srcset(html) || from_raw_pattern(html)
        return nil unless url

        apply_quality(url, quality)
      end

      def from_json_ld(html)
        PinterestDL::Extractors::JsonLd.content_url(html, 'ImageObject')
      end

      def from_open_graph(html)
        PinterestDL::Extractors::Meta.content(html, 'og:image') ||

# step-0
