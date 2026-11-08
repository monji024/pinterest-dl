# frozen_string_literal: true

require 'uri'
require_relative 'transport'
require_relative 'cookie_jar'

module PinterestDL
  class Client
    MAX_REDIRECTS = Transport::MAX_REDIRECTS
    RETRYABLE_HTTP_CODES = Transport::RETRYABLE_HTTP_CODES

    attr_reader :config, :cookie_jar, :transport

    def initialize(config: PinterestDL.config, transport: nil, cookie_jar: nil)
      @config = config.dup
      @cookie_jar = cookie_jar || @config.cookie_jar
      @transport = transport || Transport.new(config: @config, cookie_jar: @cookie_jar)
      @cache = {}
      @last_url = nil
      @mutex = Mutex.new
    end

    def last_url
      @mutex.synchronize { @last_url || @transport.last_url }
    end

    def get(url, headers: {}, use_cache: true)
      cache_key = [url.to_s, headers].hash
      if use_cache
        cached = @mutex.synchronize do
          if @cache.key?(cache_key)
            val = @cache.delete(cache_key)
            @cache[cache_key] = val
            val
          end
        end
        if cached
          body, final_url = cached
          @mutex.synchronize { @last_url = final_url }
          return body
        end
      end

      response = @transport.get(url, headers: headers)
      final_url = @transport.last_url
      @mutex.synchronize { @last_url = final_url }
      body = response.body
      store_cache(cache_key, [body, final_url]) if use_cache
      body

# step-1
