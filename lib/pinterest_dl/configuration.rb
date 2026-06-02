# frozen_string_literal: true

require 'logger'

module PinterestDL
  class Configuration
    DEFAULT_USER_AGENT =
      'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 ' \
      '(KHTML, like Gecko) Chrome/131.0.0.0 Safari/537.36'

    VALID_QUALITIES = %i[originals 1200x 736x 564x 474x 236x].freeze

    attr_accessor :user_agent, :open_timeout, :read_timeout, :write_timeout,
                  :max_retries, :retry_wait, :logger, :rate_limit_interval,
                  :proxy, :max_cache_entries, :concurrency, :overwrite
    attr_reader :quality, :cookies

    def initialize
      reset!
    end


# step-1
