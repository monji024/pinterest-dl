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

# step-0
