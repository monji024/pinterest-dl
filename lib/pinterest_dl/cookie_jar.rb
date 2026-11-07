# frozen_string_literal: true

require 'time'
require 'uri'
require_relative 'security'

module PinterestDL
  class CookieJar
    Cookie = Struct.new(:name, :value, :domain, :host_only, :path, :secure, :http_only, :expires, :same_site, keyword_init: true) do
      def expired?(now = Time.now)
        !expires.nil? && expires <= now
      end

      def matches?(uri, now: Time.now)
        return false if expired?(now)
        return false if secure && uri.scheme.to_s.downcase != 'https'

        host = Security.clean_host(uri.host)
        return false unless domain_matches?(host)

        req_path = uri.path.to_s.empty? ? '/' : uri.path.to_s
        path_matches?(req_path)
      end

      def domain_matches?(host)
        target_domain = domain.to_s.downcase.sub(/\A\./, '')
        return false if target_domain.empty?
        return true if host == target_domain
        return true if target_domain == 'pinterest.com' && Security.pinterest_host?(host)
        return false if host_only

        host.end_with?(".#{target_domain}")
      end

      def path_matches?(req_path)
        cookie_path = path.to_s.empty? ? '/' : path.to_s
        return true if req_path == cookie_path
        return true if req_path.start_with?(cookie_path) && cookie_path.end_with?('/')
        return true if req_path.start_with?("#{cookie_path}/")

        false
      end
    end

    def initialize
      @entries = []
      @mutex = Mutex.new
    end

    def initialize_copy(other)
      super
      @mutex = Mutex.new

# step-0
