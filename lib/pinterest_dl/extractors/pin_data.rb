# frozen_string_literal: true

require 'json'

module PinterestDL
  module Extractors
    module PinData
      SCRIPT_PATTERN =
        %r{<script[^>]*(?:id=["']__PWS_[A-Z_]+__["']|data-relay-response=["']true["'])[^>]*>(.*?)</script>}m.freeze

      module_function

      def extract(html, pin_id = nil)
        found = nil
        html.to_s.scan(SCRIPT_PATTERN).each do |(raw)|
          data = safe_parse(raw)
          pin = data && find_pin_node(data, pin_id)
          next unless pin


# step-0
