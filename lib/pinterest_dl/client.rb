# frozen_string_literal: true

require 'net/http'
require 'uri'
require 'openssl'

module PinterestDL
  class Client
    MAX_REDIRECTS = 5
    RETRYABLE_HTTP_CODES = %w[408 429 500 502 503 504].freeze

    attr_reader :last_url

    def initialize(config: PinterestDL.config)
      @config = config
      @cache = {}
      @cookies = Hash.new { |hash, key| hash[key] = {} }
      @last_request_at = nil
      @last_url = nil
      @mutex = Mutex.new
    end

    def get(url, headers: {}, use_cache: true)
      cache_key = [url, headers].hash
      if use_cache
        cached = @mutex.synchronize { @cache[cache_key] }
        if cached
          body, @last_url = cached
          return body
        end
      end

      body = fetch(url, headers: headers).body
      store_cache(cache_key, [body, @last_url]) if use_cache
      body
    end

    def raw_get(url, headers: {})
      fetch(url, headers: headers)
    end

    def stream_get(url, headers: {}, &block)
      raise ArgumentError, 'stream_get requires a block' unless block_given?

      fetch(url, headers: headers, &block)
    end

    def cookie(name, url = @last_url)
      target = url.to_s.empty? ? 'https://www.pinterest.com' : url.to_s
      key = site_key(URI(target))
      @mutex.synchronize { @cookies[key][name] }
    rescue URI::InvalidURIError
      nil
    end

    def clear_cache
      @mutex.synchronize { @cache.clear }
    end

    private

    def store_cache(key, value)
      @mutex.synchronize do
        max = @config.respond_to?(:max_cache_entries) ? @config.max_cache_entries.to_i : 256
        @cache.shift if max.positive? && @cache.size >= max
        @cache[key] = value if max.positive?
      end
    end

    def fetch(url, headers: {}, &stream_block)
      (MAX_REDIRECTS + 1).times do
        response = request_with_retries(url, headers: headers, &stream_block)
        save_cookies(response, url)
        unless response.is_a?(Net::HTTPRedirection)
          check_response(response, url)
          @last_url = url
          return response
        end

        location = response['location']
        raise PinterestDL::NotFoundError, "Redirected without a location header (#{url})" unless location

        url = URI.join(url, location).to_s
      end

      raise PinterestDL::NetworkError, "Too many redirects for #{url}"
    end

    def request_with_retries(url, headers: {}, &stream_block)
      attempts = 0
      begin
        throttle!
        uri = URI(url)
        http = build_http(uri)
        req = Net::HTTP::Get.new(uri, default_headers(uri).merge(headers))
        response = perform_request(http, req, &stream_block)

        if retryable_response?(response) && attempts < @config.max_retries
          attempts += 1
          wait = retry_delay_for(response, attempts)
          @config.logger.warn("HTTP #{response.code} from #{url}, retrying in #{wait}s (#{attempts}/#{@config.max_retries})")
          sleep(wait) if wait.positive?
          raise RetryableResponseSignal
        end

        response
      rescue RetryableResponseSignal
        retry
      rescue Timeout::Error, Errno::ECONNRESET, Errno::ECONNREFUSED, Errno::ETIMEDOUT,
             Errno::EHOSTUNREACH, SocketError, OpenSSL::SSL::SSLError, EOFError => e
        attempts += 1
        if attempts <= @config.max_retries
          @config.logger.warn("request to #{url} failed (#{e.class}), retrying (#{attempts}/#{@config.max_retries})")
          sleep(@config.retry_wait * attempts)
          retry
        end
        raise PinterestDL::NetworkError.new("Failed to reach #{url}: #{e.message}", cause_error: e)
      end
    end

    class RetryableResponseSignal < StandardError; end
    private_constant :RetryableResponseSignal

    def perform_request(http, req, &stream_block)
      return http.request(req) unless stream_block

      http.request(req) do |response|
        if response.is_a?(Net::HTTPSuccess)
          response.read_body(&stream_block)
        end
        return response
      end
    end

    def retryable_response?(response)
      RETRYABLE_HTTP_CODES.include?(response.code.to_s)
    end

    def retry_delay_for(response, attempts)
      header = response['Retry-After'].to_s.strip
      if header.match?(/\A\d+(\.\d+)?\z/)
        header.to_f
      else
        @config.retry_wait * attempts
      end
    end

    def check_response(response, url)
      case response
      when Net::HTTPSuccess
        response
      when Net::HTTPTooManyRequests
        raise PinterestDL::RateLimitError.new(
          "Rate limited while requesting #{url}",
          retry_after: response['Retry-After']
        )
      when Net::HTTPUnauthorized
        raise PinterestDL::AuthenticationError, "Authentication required for #{url}"
      when Net::HTTPNotFound
        raise PinterestDL::NotFoundError, "Nothing found at #{url}"
      when Net::HTTPForbidden
        raise PinterestDL::RateLimitError, "Request to #{url} was blocked (HTTP 403)"
      else
        raise PinterestDL::NetworkError, "Unexpected response #{response.code} from #{url}"
      end
    end

    def build_http(uri)
      http = build_proxy_http(uri)
      http.use_ssl = (uri.scheme == 'https')
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
      cookie_line = cookie_header(uri)
      headers['Cookie'] = cookie_line unless cookie_line.empty?
      headers
    end

    def cookie_header(uri)
      parts = []
      parts << @config.cookies.to_s if @config.authenticated?
      key = site_key(uri)
      jar_pairs = @mutex.synchronize { @cookies[key].map { |name, value| "#{name}=#{value}" } }
      parts.concat(jar_pairs)
      parts.join('; ')
    end

    def save_cookies(response, url)
      fields = response.get_fields('set-cookie')
      return if fields.nil? || fields.empty?

      key = site_key(URI(url))
      @mutex.synchronize do
        jar = @cookies[key]
        fields.each do |line|

# step-12
