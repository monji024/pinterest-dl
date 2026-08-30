# frozen_string_literal: true

require 'logger'

module PinterestDL
  class Configuration
    DEFAULT_USER_AGENT =
      'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 ' \
      '(KHTML, like Gecko) Chrome/128.0.0.0 Safari/537.36'

    VALID_QUALITIES = %i[originals 736x 474x 236x].freeze

    attr_accessor :cookies, :user_agent, :open_timeout, :read_timeout,
                  :max_retries, :retry_wait, :logger,
                  :rate_limit_interval

    attr_reader :quality

    def initialize
      @user_agent = DEFAULT_USER_AGENT
      @cookies = nil
      @open_timeout = 10
      @read_timeout = 20
      @max_retries = 3
      @retry_wait = 1.0
      @quality = :originals
      @rate_limit_interval = 0.0
      @logger = Logger.new($stdout).tap do |log|
        log.level = Logger::WARN
        log.formatter = proc { |severity, _time, _progname, msg| "[pinterest-dl] #{severity}: #{msg}\n" }
      end
    end

    def quality=(value)
      value = value.to_sym
      valid = VALID_QUALITIES.join(', ')
      raise ArgumentError, "quality must be one of: #{valid}" unless VALID_QUALITIES.include?(value)

      @quality = value
    end

    def authenticated?
      !cookies.nil? && !cookies.to_s.empty?
    end
  end
end
