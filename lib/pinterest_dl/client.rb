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

# step-0
