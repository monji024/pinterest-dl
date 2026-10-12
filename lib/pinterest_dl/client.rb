# frozen_string_literal: true

# Monji024
require 'net/http'
require 'uri'
require 'openssl'

module PinterestDL
  class Client
    MAX_REDIRECTS = 5

    attr_reader :last_url

    def initialize(config: PinterestDL.config)
      @config = config
      @cache = {}
      @cookies = Hash.new { |hash, key| hash[key] = {} }
      @last_request_at = nil
      @last_url = nil
    end

    def get(url, headers: {}, use_cache: true)
      cache_key = [url, headers].hash
      if use_cache && @cache.key?(cache_key)
        body, @last_url = @cache[cache_key]
        return body
      end

      body = fetch(url, headers: headers).body
      @cache[cache_key] = [body, @last_url] if use_cache
      body
    end

    def raw_get(url, headers: {})
      fetch(url, headers: headers)
    end

    def cookie(name, url = @last_url)
      @cookies[site_key(URI(url))][name]
    end

    def clear_cache
      @cache.clear
    end

    private

    def fetch(url, headers: {})
      (MAX_REDIRECTS + 1).times do
        response = request_with_retries(url, headers: headers)
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

    def request_with_retries(url, headers: {})
      attempts = 0
      begin
        throttle!
        uri = URI(url)
        http = build_http(uri)
        req = Net::HTTP::Get.new(uri, default_headers(uri).merge(headers))
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

    def check_response(response, url)
      case response
      when Net::HTTPSuccess
        response
      when Net::HTTPTooManyRequests
        raise PinterestDL::RateLimitError.new(
          "Rate limited while requesting #{url}",
          retry_after: response['Retry-After']
        )
      when Net::HTTPNotFound
        raise PinterestDL::NotFoundError, "Nothing found at #{url}"
      when Net::HTTPForbidden
        raise PinterestDL::RateLimitError, "Request to #{url} was blocked (HTTP 403)"
      else
        raise PinterestDL::NetworkError, "Unexpected response #{response.code} from #{url}"
      end
    end

    def build_http(uri)
      http = Net::HTTP.new(uri.host, uri.port)
      http.use_ssl = (uri.scheme == 'https')
      http.open_timeout = @config.open_timeout
      http.read_timeout = @config.read_timeout
      http
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
      parts.concat(@cookies[site_key(uri)].map { |name, value| "#{name}=#{value}" })
      parts.join('; ')
    end

    def save_cookies(response, url)
      jar = @cookies[site_key(URI(url))]
      (response.get_fields('set-cookie') || []).each do |line|
        name, value = line.split(';').first.to_s.split('=', 2)
        next if name.nil? || value.nil?

        value.empty? ? jar.delete(name.strip) : jar[name.strip] = value
      end
    end

    def site_key(uri)
      uri.host.to_s.split('.').last(2).join('.')
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
