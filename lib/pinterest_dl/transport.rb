# frozen_string_literal: true

require 'json'
require 'net/http'
require 'openssl'
require 'time'
require 'uri'
require_relative 'errors'
require_relative 'security'
require_relative 'cookie_jar'

module PinterestDL
  class Transport
    MAX_REDIRECTS = 5
    RETRYABLE_HTTP_CODES = %w[408 429 500 502 503 504].freeze
    SENSITIVE_REDIRECT_HEADERS = %w[Cookie Authorization X-CSRFToken X-Pinterest-Source-Url].freeze

    attr_reader :last_url, :cookie_jar, :config

    def initialize(config: PinterestDL.config, cookie_jar: nil)
      @config = config
      @cookie_jar = cookie_jar || config.cookie_jar.dup
      @last_request_at = nil
      @last_url = nil
      @mutex = Mutex.new
    end

    def get(url, headers: {}, &stream_block)
      current_url = url.to_s
      current_headers = headers.dup

      (MAX_REDIRECTS + 1).times do
        uri = validate_target_url!(current_url)
        response = request_with_retries(uri, headers: current_headers, &stream_block)
        @cookie_jar.set_from_header(response.get_fields('set-cookie'), uri.to_s)

        unless response.is_a?(Net::HTTPRedirection)
          check_response!(response, uri.to_s)
          @last_url = uri.to_s
          return response
        end

        location = response['location']
        unless location
          raise RedirectError.new("Redirected without a location header (#{uri})", url: uri.to_s, status_code: response.code.to_i)
        end

# step-0
