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

    def reset!
      @user_agent = DEFAULT_USER_AGENT
      @cookies = nil
      @open_timeout = 10
      @read_timeout = 20
      @write_timeout = 20
      @max_retries = 3
      @retry_wait = 1.0
      @quality = :originals
      @rate_limit_interval = 0.0
      @proxy = ENV['HTTPS_PROXY'] || ENV['https_proxy'] || ENV['HTTP_PROXY'] || ENV['http_proxy']
      @max_cache_entries = 256
      @concurrency = 4
      @overwrite = true
      @logger = default_logger
      self
    end

    def quality=(value)
      value = value.to_sym
      valid = VALID_QUALITIES.join(', ')
      raise ArgumentError, "quality must be one of: #{valid}" unless VALID_QUALITIES.include?(value)

      @quality = value
    end

    def cookies=(value)
      if value.nil? || value.to_s.strip.empty?
        @cookies = nil
        return
      end

      raw = value.to_s.strip
      @cookies = File.file?(raw) ? parse_cookie_file(raw) : raw
    end

    def concurrency=(value)
      num = value.to_i
      raise ArgumentError, 'concurrency must be at least 1' if num < 1

      @concurrency = num
    end

    def authenticated?
      !@cookies.nil? && !@cookies.empty?
    end

    private

    def parse_cookie_file(path)
      pairs = []
      File.foreach(path) do |line|
        stripped = line.strip
        next if stripped.empty? || stripped.start_with?('#')

        fields = stripped.split("\t")
        if fields.size >= 7
          domain, _flag, _path, _secure, _expiry, name, val = fields
          next unless domain.include?('pinterest.')

          pairs << "#{name}=#{val}"
        elsif stripped.include?('=') && !stripped.include?("\t")
          pairs << stripped
        end
      end
      pairs.join('; ')
    end

    def default_logger
      Logger.new($stderr).tap do |log|
        log.level = Logger::WARN
        log.formatter = proc { |severity, _time, _progname, msg| "[pinterest-dl] #{severity}: #{msg}\n" }
      end
    end
  end
end