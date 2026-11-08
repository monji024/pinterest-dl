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

# step-0
