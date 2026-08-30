# frozen_string_literal: true

# Monji024
require 'net/http'
require 'uri'
require 'openssl'

module PinterestDL
  class Client
    def initialize(config: PinterestDL.config)
      @config = config
      @cache = {}
      @last_request_at = nil
    end

    def get(url, headers: {}, use_cache: true)
      cache_key = [url, headers].hash
      return @cache[cache_key] if use_cache && @cache.key?(cache_key)

      response = request_with_retries(url, headers: headers)
      body = handle_response(response, url)
      @cache[cache_key] = body if use_cache
      body
    end

    def raw_get(url, headers: {})
      response = request_with_retries(url, headers: headers)
      handle_response(response, url, raw: true)
      response
    end

    def clear_cache
      @cache.clear
    end

    private

    def request_with_retries(url, headers: {})
      attempts = 0
      begin
        throttle!
        uri = URI(url)
        http = build_http(uri)
        req = Net::HTTP::Get.new(uri, default_headers.merge(headers))
        http.request(req)
      rescue Timeout::Error, Errno::ECONNRESET, Errno::ECONNREFUSED,
             SocketError, OpenSSL::SSL::SSLError, EOFError => e
        attempts += 1
        if attempts <= @config.max_retries
          @config.logger.warn("request to #{url} failed (#{e.class}), retrying (#{attempts}/#{@config.max_retries})")
          sleep(@config.retry_wait * attempts)
          retry
        end
        raise PinterestDL::NetworkError.new("Failed to reach #{url}: #{e.message}", cause_error: e)
      end
    end

    def handle_response(response, url, raw: false)
      case response
      when Net::HTTPSuccess
        raw ? response : response.body
      when Net::HTTPTooManyRequests
        raise PinterestDL::RateLimitError.new(
          "Rate limited while requesting #{url}",
          retry_after: response['Retry-After']
        )
      when Net::HTTPNotFound
        raise PinterestDL::NotFoundError, "Nothing found at #{url}"
      when Net::HTTPRedirection
        location = response['location']
        raise PinterestDL::NotFoundError, "Redirected without a location header (#{url})" unless location

        location = URI.join(url, location).to_s if location.start_with?('/')
        get_or_raw(location, raw: raw)
      when Net::HTTPForbidden
        raise PinterestDL::RateLimitError, "Request to #{url} was blocked (HTTP 403)"
      else
        raise PinterestDL::NetworkError, "Unexpected response #{response.code} from #{url}"
      end
    end

    def get_or_raw(url, raw:)
      raw ? raw_get(url) : get(url)
    end

    def build_http(uri)
      http = Net::HTTP.new(uri.host, uri.port)
      http.use_ssl = (uri.scheme == 'https')
      http.open_timeout = @config.open_timeout
      http.read_timeout = @config.read_timeout
      http
    end

    def default_headers
      headers = { 'User-Agent' => @config.user_agent }
      headers['Cookie'] = @config.cookies if @config.authenticated?
      headers
    end

    def throttle!
      return if @config.rate_limit_interval <= 0
      return unless @last_request_at

      elapsed = Time.now - @last_request_at
      wait = @config.rate_limit_interval - elapsed
      sleep(wait) if wait.positive?
    ensure
      @last_request_at = Time.now
    end
  end
end
