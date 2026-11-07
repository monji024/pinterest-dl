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
      @entries = other.entries_snapshot.map(&:dup)
    end

    def entries_snapshot
      @mutex.synchronize { @entries.map(&:dup) }
    end

    def clear
      @mutex.synchronize { @entries.clear }
    end

    def empty?
      @mutex.synchronize { @entries.empty? }
    end

    def set_from_header(set_cookie_fields, origin_url)
      fields = Array(set_cookie_fields).flatten.compact
      return if fields.empty?

      uri = URI.parse(origin_url.to_s)
      @mutex.synchronize do
        fields.each do |raw_line|
          cookie = parse_set_cookie(raw_line, uri)
          upsert_unlocked(cookie) if cookie
        end
      end
    rescue URI::InvalidURIError
      nil
    end

    def load_raw(raw_cookies, default_domain: '.pinterest.com')
      return if raw_cookies.nil? || raw_cookies.to_s.strip.empty?

      text = raw_cookies.to_s.strip
      if File.file?(text)
        load_netscape_file(text)
      else
        load_cookie_string(text, default_domain: default_domain)
      end
    end

    def load_cookie_string(cookie_str, default_domain: '.pinterest.com')
      @mutex.synchronize do
        cookie_str.to_s.split(';').each do |pair|
          name, value = pair.strip.split('=', 2)
          next if name.nil? || value.nil? || name.strip.empty?

          cookie = Cookie.new(
            name: name.strip,
            value: value.strip,
            domain: default_domain.sub(/\A\./, ''),
            host_only: false,
            path: '/',

# step-1
