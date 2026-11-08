# frozen_string_literal: true

require_relative 'errors'

module PinterestDL
  module MediaValidator
    ALLOWED_CONTENT_TYPES = %w[
      image/jpeg
      image/jpg
      image/png
      image/gif
      image/webp
      image/avif
      image/bmp
      video/mp4
      video/quicktime
      video/webm
      application/octet-stream
      binary/octet-stream
    ].freeze

    REJECTED_CONTENT_TYPES = %w[
      text/html
      application/xhtml+xml
      application/json
      text/plain
      text/xml

# step-0
