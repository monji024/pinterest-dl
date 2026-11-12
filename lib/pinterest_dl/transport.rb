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
      exp = [attempt.to_i - 1, 0].max
      raw = base_wait.to_f * (2**exp)
      capped = max_wait ? [raw, max_wait.to_f].min : raw
      jitter_max = capped * jitter_ratio.to_f
      jitter = jitter_max.positive? ? rand(0.0..jitter_max) : 0.0
      [capped + jitter, max_wait ? max_wait.to_f : (capped + jitter)].min
    end

    def parse_retry_after(header_value, now: Time.now)
      str = header_value.to_s.strip
      return nil if str.empty?

      if str.match?(/\A\d+(\.\d+)?\z/)
        val = str.to_f
        return [val, 0.0].max
      end

      target_time = Time.httpdate(str)
      [target_time - now, 0.0].max
    rescue ArgumentError
      nil
    end

    private

    class RetryableResponseSignal < StandardError; end
    private_constant :RetryableResponseSignal

    def validate_target_url!(raw_url)
      allow_local = @config.respond_to?(:allow_local_network) ? @config.allow_local_network : false
      https_only = @config.respond_to?(:https_only) ? @config.https_only : false
      Security.parse_and_validate_url!(raw_url, allow_local: allow_local, https_only: https_only)
    end

    def resolve_redirect_uri!(source_uri, location)
      target_str = URI.join(source_uri.to_s, location.to_s).to_s
      allow_local = @config.respond_to?(:allow_local_network) ? @config.allow_local_network : false
      https_only = @config.respond_to?(:https_only) ? @config.https_only : false
      target_uri = Security.parse_and_validate_url!(target_str, allow_local: allow_local, https_only: https_only)

      unless Security.allowed_redirect_target?(source_uri, target_uri, allow_local: allow_local)
        raise RedirectError.new(
          "Blocked cross-domain redirect from #{source_uri.host} to untrusted host #{target_uri.host}",
          url: target_uri.to_s
        )
      end

      target_uri
    rescue URI::InvalidURIError => e
      raise RedirectError.new("Invalid redirect location #{location.inspect}", url: source_uri.to_s, cause_error: e)
    end

    def sanitize_redirect_headers(source_uri, target_uri, headers)
      return headers if Security.same_security_domain?(source_uri, target_uri)

      headers.reject do |k, _|
        SENSITIVE_REDIRECT_HEADERS.any? { |s| s.casecmp?(k.to_s) }
      end
    end

    def request_with_retries(uri, headers: {}, &stream_block)
      attempts = 0
      max_retries = @config.max_retries.to_i
      begin
        throttle!
        http = build_http(uri)
        req = Net::HTTP::Get.new(uri, default_headers(uri).merge(headers))
        response = perform_request(http, req, &stream_block)

        if retryable_response?(response) && attempts < max_retries
          attempts += 1
          wait = retry_delay_for(response, attempts)
          @config.logger.warn(
            Security.redact("HTTP #{response.code} from #{uri}, retrying in #{wait.round(2)}s (#{attempts}/#{max_retries})")
          )
          sleep(wait) if wait.positive?
          raise RetryableResponseSignal
        end

        response
      rescue RetryableResponseSignal
        retry
      rescue Net::OpenTimeout, Net::ReadTimeout, Net::WriteTimeout, Timeout::Error, Errno::ETIMEDOUT => e
        attempts += 1
        if attempts <= max_retries
          wait = backoff_delay(attempts)
          msg = "Timeout requesting #{uri} (#{e.class}), retrying in #{wait.round(2)}s (#{attempts}/#{max_retries})"
          @config.logger.warn(Security.redact(msg))
          sleep(wait) if wait.positive?
          retry
        end
        raise TimeoutError.new("Timed out requesting #{uri}: #{e.message}", url: uri.to_s, cause_error: e)
      rescue OpenSSL::SSL::SSLError => e
        attempts += 1
        if attempts <= max_retries
          wait = backoff_delay(attempts)
          msg = "SSL error requesting #{uri} (#{e.class}), retrying in #{wait.round(2)}s (#{attempts}/#{max_retries})"
          @config.logger.warn(Security.redact(msg))
          sleep(wait) if wait.positive?
          retry
        end
        raise SSLError.new("SSL error connecting to #{uri}: #{e.message}", url: uri.to_s, cause_error: e)
      rescue Errno::ECONNRESET, Errno::ECONNREFUSED, Errno::EHOSTUNREACH, Errno::ENETUNREACH,
             Errno::EPIPE, SocketError, EOFError => e
        attempts += 1
        if attempts <= max_retries
          wait = backoff_delay(attempts)
          msg = "Connection to #{uri} failed (#{e.class}), retrying in #{wait.round(2)}s (#{attempts}/#{max_retries})"
          @config.logger.warn(Security.redact(msg))
          sleep(wait) if wait.positive?
          retry
        end
        raise ConnectionError.new("Failed to reach #{uri}: #{e.message}", url: uri.to_s, cause_error: e)
      end
    end

    def perform_request(http, req, &stream_block)
      return http.request(req) unless stream_block

      captured = nil
      http.request(req) do |response|
        if response.is_a?(Net::HTTPSuccess) || response.is_a?(Net::HTTPPartialContent)
          stream_block.call(response)
        end
        captured = response
      end
      captured
    end

    def retryable_response?(response)
      RETRYABLE_HTTP_CODES.include?(response.code.to_s)
    end

    def retry_delay_for(response, attempts)
      parsed = parse_retry_after(response['Retry-After'])
      if parsed
        max_wait = @config.respond_to?(:max_retry_wait) && @config.max_retry_wait ? @config.max_retry_wait.to_f : 60.0
        [parsed, max_wait].min
      else
        backoff_delay(attempts)
      end
    end

    def check_response!(response, url)
      code = response.code.to_i
      case response
      when Net::HTTPSuccess, Net::HTTPPartialContent
        response
      when Net::HTTPRequestedRangeNotSatisfiable
        raise RangeNotSatisfiableError.new(
          "Range not satisfiable for #{url} (HTTP 416)",
          url: url,
          status_code: 416,
          content_range: response['Content-Range'] || response['content-range']
        )
      when Net::HTTPTooManyRequests
        raise RateLimitError.new(
          "Rate limited while requesting #{url} (HTTP 429)",
          url: url,
          status_code: 429,
          retry_after: response['Retry-After']
        )
      when Net::HTTPUnauthorized
        raise AuthenticationError.new("Authentication required for #{url} (HTTP 401)", url: url, status_code: 401)
      when Net::HTTPForbidden
        raise ForbiddenError.new("Request to #{url} was forbidden (HTTP 403)", url: url, status_code: 403)
      when Net::HTTPNotFound, Net::HTTPGone
        raise NotFoundError.new("Nothing found at #{url} (HTTP #{code})", url: url, status_code: code)
      when Net::HTTPServerError
        raise ServerError.new("Pinterest server error #{code} from #{url}", url: url, status_code: code)
      else
        if code == 416
          raise RangeNotSatisfiableError.new(
            "Range not satisfiable for #{url} (HTTP 416)",
            url: url,
            status_code: 416,
            content_range: response['Content-Range'] || response['content-range']
          )
        end
        raise NetworkError.new("Unexpected HTTP response #{code} from #{url}", url: url, status_code: code)
      end
    end

    def build_http(uri)
      http = build_proxy_http(uri)
      if uri.scheme == 'https'
        http.use_ssl = true
        http.verify_mode = OpenSSL::SSL::VERIFY_PEER
      end
      http.open_timeout = @config.open_timeout
      http.read_timeout = @config.read_timeout
      http.write_timeout = @config.write_timeout if http.respond_to?(:write_timeout=) && @config.respond_to?(:write_timeout)
      http
    end

    def build_proxy_http(uri)
      proxy_url = @config.respond_to?(:proxy) ? @config.proxy : nil
      return Net::HTTP.new(uri.host, uri.port) if proxy_url.nil? || proxy_url.to_s.strip.empty?

      p_uri = URI(proxy_url.to_s)
      Net::HTTP.new(uri.host, uri.port, p_uri.host, p_uri.port, p_uri.user, p_uri.password)
    rescue URI::InvalidURIError
      Net::HTTP.new(uri.host, uri.port)
    end

    def default_headers(uri)
      headers = {
        'User-Agent' => @config.user_agent,
        'Accept-Language' => 'en-US,en;q=0.9'
      }
      allow_local = @config.respond_to?(:allow_local_network) ? @config.allow_local_network : false
      cookie_line = @cookie_jar.header_for(uri, allow_local: allow_local)
      headers['Cookie'] = cookie_line unless cookie_line.empty?
      headers
    end

    def throttle!
      return if @config.rate_limit_interval.to_f <= 0

      @mutex.synchronize do
        if @last_request_at
          elapsed = monotonic_now - @last_request_at
          wait = @config.rate_limit_interval - elapsed
          sleep(wait) if wait.positive?
        end
        @last_request_at = monotonic_now
      end
    end

    def monotonic_now
      Process.clock_gettime(Process::CLOCK_MONOTONIC)
    end
  end
end
