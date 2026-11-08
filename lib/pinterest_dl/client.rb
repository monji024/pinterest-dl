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
    end

    def raw_get(url, headers: {})
      response = @transport.get(url, headers: headers)
      @mutex.synchronize { @last_url = @transport.last_url }
      response
    end

    def stream_get(url, headers: {}, &block)
      raise ArgumentError, 'stream_get requires a block' unless block_given?

      response = @transport.get(url, headers: headers) do |res|
        if block.arity == 2
          res.read_body { |chunk| block.call(chunk, res) }
        else
          res.read_body(&block)
        end
      end
      @mutex.synchronize { @last_url = @transport.last_url }
      response
    end

    def cookie(name, url = nil)
      target = url || last_url || 'https://www.pinterest.com'
      allow_local = @config.respond_to?(:allow_local_network) ? @config.allow_local_network : true
      @cookie_jar.value_for(name, target, allow_local: allow_local)
    end

    def clear_cache
      @mutex.synchronize { @cache.clear }
    end

    def cache_size
      @mutex.synchronize { @cache.size }
    end

    private

    def store_cache(key, value)
      @mutex.synchronize do
        max = @config.respond_to?(:max_cache_entries) ? @config.max_cache_entries.to_i : 256
        return if max <= 0

        @cache.delete(key)
        @cache.shift while @cache.size >= max
        @cache[key] = value
      end
    end
  end
end