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

# step-1
