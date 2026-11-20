# frozen_string_literal: true

require_relative 'tui/theme'
require_relative 'tui/icons'
require_relative 'tui/terminal'
require_relative 'tui/preview'
require_relative 'tui/download_queue'
require_relative 'tui/state'
require_relative 'tui/renderer'
require_relative 'tui/app'

module PinterestDL
  module TUI
    DEFAULT_COOKIE_PATHS = [
      './cookies.txt',
      '~/cookies.txt',
      '~/.config/pinterest-dl/cookies.txt'
    ].freeze

    module_function

    def start(**options)
      App.new(**options).run
    end

    def build_auto_session(proxy: nil, cookies: nil, env: ENV)
      detected_proxy = proxy || detect_proxy(env)
      detected_cookies = cookies || detect_cookies_file
      PinterestDL.session do |cfg|
        cfg.proxy = detected_proxy if detected_proxy
        cfg.cookies = detected_cookies if detected_cookies
      end
    end

    def detect_proxy(env = ENV)
      %w[HTTPS_PROXY https_proxy HTTP_PROXY http_proxy ALL_PROXY all_proxy].each do |var|
        val = env[var].to_s.strip
        return val unless val.empty?
      end
      nil
    end

    def detect_cookies_file(paths = DEFAULT_COOKIE_PATHS)
      paths.each do |raw|
        expanded = File.expand_path(raw)
        return expanded if File.file?(expanded) && File.readable?(expanded)
      end
      nil
    rescue StandardError
      nil
    end
  end
end
