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
            secure: false,
            http_only: false,
            expires: nil,
            same_site: nil
          )
          upsert_unlocked(cookie)
        end
      end
    end

    def load_netscape_file(file_path)
      @mutex.synchronize do
        File.foreach(file_path) do |line|
          stripped = line.strip
          next if stripped.empty?
          if stripped.start_with?('#HttpOnly_')
            stripped = stripped.sub(/\A#HttpOnly_/, '')
            http_only = true
          elsif stripped.start_with?('#')
            next
          else
            http_only = false
          end

          fields = stripped.split("\t")
          if fields.size >= 7
            domain, include_subdomains, path, secure_flag, expiry_raw, name, value = fields
            next unless Security.pinterest_host?(domain.sub(/\A\./, ''))

            exp_int = expiry_raw.to_i
            expires = exp_int.positive? ? Time.at(exp_int) : nil
            cookie = Cookie.new(
              name: name.strip,
              value: value.to_s.strip,
              domain: domain.sub(/\A\./, '').downcase,
              host_only: include_subdomains.to_s.upcase != 'TRUE' && !domain.start_with?('.'),
              path: path.to_s.empty? ? '/' : path.strip,
              secure: secure_flag.to_s.upcase == 'TRUE',
              http_only: http_only,
              expires: expires,
              same_site: nil
            )
            upsert_unlocked(cookie)
          elsif stripped.include?('=') && !stripped.include?("\t")
            stripped.split(';').each do |pair|
              k, v = pair.strip.split('=', 2)
              next if k.nil? || v.nil? || k.empty?

              upsert_unlocked(
                Cookie.new(
                  name: k,
                  value: v,
                  domain: 'pinterest.com',

# step-2
