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
        )
      end

      return true if ALLOWED_CONTENT_TYPES.include?(mime) || mime.start_with?('image/', 'video/')

      raise InvalidMediaError.new(
        "Unsupported Content-Type #{mime.inspect} from #{url}",
        url: url,
        content_type: mime
      )
    end

    def detect_signature(bytes)
      return nil if bytes.nil?

      raw = bytes.b
      return :jpeg if raw.start_with?(JPEG_MAGIC)
      return :png if raw.start_with?(PNG_MAGIC)
      return :gif if raw.start_with?(GIF87_MAGIC) || raw.start_with?(GIF89_MAGIC)
      return :webp if raw.bytesize >= 12 && raw.start_with?(RIFF_MAGIC) && raw.byteslice(8, 4) == WEBP_MAGIC
      return :bmp if raw.start_with?(BMP_MAGIC)
      return :mp4 if raw.bytesize >= 8 && raw.byteslice(4, 4) == FTYP_MAGIC
      return :webm if raw.start_with?(EBML_MAGIC)

      nil
    end


# step-2
