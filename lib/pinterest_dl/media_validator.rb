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
      application/xml
      text/javascript
      application/javascript
    ].freeze

    JPEG_MAGIC = "\xFF\xD8\xFF".b.freeze
    PNG_MAGIC = "\x89PNG\r\n\x1A\n".b.freeze
    GIF87_MAGIC = 'GIF87a'.b.freeze
    GIF89_MAGIC = 'GIF89a'.b.freeze
    RIFF_MAGIC = 'RIFF'.b.freeze
    WEBP_MAGIC = 'WEBP'.b.freeze
    BMP_MAGIC = 'BM'.b.freeze
    FTYP_MAGIC = 'ftyp'.b.freeze
    EBML_MAGIC = "\x1A\x45\xDF\xA3".b.freeze

    module_function

    def validate_content_type!(content_type, url: nil)
      return true if content_type.nil? || content_type.to_s.strip.empty?

      mime = content_type.to_s.split(';').first.to_s.strip.downcase
      return true if mime.empty?

      if REJECTED_CONTENT_TYPES.include?(mime)
        raise InvalidMediaError.new(
          "Rejected non-media Content-Type #{mime.inspect} from #{url}",
          url: url,
          content_type: mime

# step-1
