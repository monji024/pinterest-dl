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

        next_uri = resolve_redirect_uri!(uri, location)
        current_headers = sanitize_redirect_headers(uri, next_uri, current_headers)
        current_url = next_uri.to_s
      end

      raise RedirectError.new("Too many redirects for #{current_url}", url: current_url)
    end

    def call_resource(host:, resource_name:, source_path:, options:, headers: {}, client: nil)
      payload = { options: options, context: {} }.to_json
      uri = URI("https://#{host}/resource/#{resource_name}/get/")
      uri.query = URI.encode_www_form('source_url' => source_path, 'data' => payload)

      raw_body = if client
                   client.get(uri.to_s, use_cache: false, headers: headers)
                 else
                   get(uri.to_s, headers: headers).body
                 end

      parse_and_validate_resource_json!(raw_body, resource_name: resource_name, url: uri.to_s)
    end

    def parse_and_validate_resource_json!(raw_body, resource_name: 'Resource', url: nil)
      if raw_body.nil? || raw_body.to_s.strip.empty?
        raise InvalidResponseError.new("Empty response from Pinterest (#{resource_name})", url: url)
      end

      parsed = JSON.parse(raw_body.to_s)
      raise InvalidResponseError.new("Expected JSON object from #{resource_name}", url: url) unless parsed.is_a?(Hash)

      res = parsed['resource_response']
      if res.is_a?(Hash) && res['error'].is_a?(Hash)
        err_msg = res.dig('error', 'message') || res.dig('error', 'code') || 'API error'
        http_code = res['http_status'].to_i
        raise AuthenticationError.new(err_msg.to_s, url: url, status_code: 401) if http_code == 401
        raise ForbiddenError.new(err_msg.to_s, url: url, status_code: 403) if http_code == 403
        raise RateLimitError.new(err_msg.to_s, url: url, status_code: 429) if http_code == 429
      end

      parsed
    rescue JSON::ParserError, TypeError => e
      raise InvalidResponseError.new("Unexpected response from Pinterest (#{resource_name})", url: url, cause_error: e)
    end

    def backoff_delay(attempt, base_wait: @config.retry_wait, max_wait: @config.max_retry_wait, jitter_ratio: @config.retry_jitter)

# step-1
