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


# step-1
