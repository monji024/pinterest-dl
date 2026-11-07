# frozen_string_literal: true

require 'logger'
require_relative 'errors'
require_relative 'security'
require_relative 'cookie_jar'

module PinterestDL
  class Configuration
    DEFAULT_USER_AGENT =
      'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 ' \
      '(KHTML, like Gecko) Chrome/131.0.0.0 Safari/537.36'

    VALID_QUALITIES = %i[originals 1200x 736x 564x 474x 236x].freeze
    DEFAULT_MAX_FILE_SIZE = 500 * 1024 * 1024

    attr_accessor :user_agent, :open_timeout, :read_timeout, :write_timeout,
                  :max_retries, :retry_wait, :max_retry_wait, :retry_jitter,
                  :rate_limit_interval, :proxy, :max_cache_entries,
                  :overwrite, :max_file_size, :max_speed, :verify_content_type,
                  :progress, :resume, :deduplicate, :collision_strategy,
                  :allow_local_network, :https_only, :min_free_disk_space
    attr_reader :quality, :cookies, :concurrency, :cookie_jar, :logger

    def initialize(**options)
      reset!
      apply_options(options)
    end

    def initialize_copy(other)
      super
      @cookie_jar = other.cookie_jar.dup
      @cookies = other.cookies&.dup
      @user_agent = other.user_agent&.dup
      @proxy = other.proxy&.dup
    end

    def reset!
      @user_agent = DEFAULT_USER_AGENT
      @cookies = nil
      @cookie_jar = CookieJar.new
      @open_timeout = 10
      @read_timeout = 20
      @write_timeout = 20
      @max_retries = 3
      @retry_wait = 1.0
      @max_retry_wait = 30.0
      @retry_jitter = 0.25
      @quality = :originals
      @rate_limit_interval = 0.0

# step-1
