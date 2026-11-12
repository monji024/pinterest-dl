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
                  host_only: false,
                  path: '/',
                  secure: false,
                  http_only: false,
                  expires: nil,
                  same_site: nil
                )
              )
            end
          end
        end
      end
    end

    def header_for(url_or_uri, allow_local: false)
      uri = url_or_uri.is_a?(URI) ? url_or_uri : URI.parse(url_or_uri.to_s)
      return '' unless Security.cookie_eligible_host?(uri.host, allow_local: allow_local)

      now = Time.now
      matched = @mutex.synchronize do
        @entries.reject! { |c| c.expired?(now) }
        @entries
          .select { |c| c.matches?(uri, now: now) }
          .sort_by { |c| -c.path.to_s.length }
      end

      seen = {}
      pairs = matched.each_with_object([]) do |cookie, acc|
        next if seen[cookie.name]

        seen[cookie.name] = true
        acc << "#{cookie.name}=#{cookie.value}"
      end
      pairs.join('; ')
    rescue URI::InvalidURIError
      ''
    end

    def value_for(name, url_or_uri = 'https://www.pinterest.com', allow_local: true)
      target = url_or_uri.to_s.strip.empty? ? 'https://www.pinterest.com' : url_or_uri.to_s
      uri = target.is_a?(URI) ? target : URI.parse(target)
      return nil unless Security.cookie_eligible_host?(uri.host, allow_local: allow_local)

      now = Time.now
      @mutex.synchronize do
        @entries.reject! { |c| c.expired?(now) }
        found = @entries
                .select { |c| c.name == name.to_s && c.matches?(uri, now: now) }
                .max_by { |c| c.path.to_s.length }
        found&.value
      end
    rescue URI::InvalidURIError
      nil
    end

    def to_cookie_string(domain: 'https://www.pinterest.com')
      header_for(domain, allow_local: true)
    end

    private

    def parse_set_cookie(raw_line, uri)
      segments = raw_line.to_s.split(';').map(&:strip).reject(&:empty?)
      return nil if segments.empty?

      first = segments.shift
      name, value = first.split('=', 2)
      return nil if name.nil? || value.nil? || name.strip.empty?

      origin_host = Security.clean_host(uri.host)
      attrs = {
        name: name.strip,
        value: value.strip,
        domain: origin_host,
        host_only: true,
        path: default_cookie_path(uri.path),
        secure: false,
        http_only: false,
        expires: nil,
        same_site: nil
      }

      segments.each do |seg|
        attr_name, attr_val = seg.split('=', 2)
        key = attr_name.to_s.strip.downcase
        val = attr_val&.strip
        case key
        when 'domain'
          next if val.nil? || val.empty?

          normalized = val.downcase.sub(/\A\./, '').chomp('.')
          next unless domain_allowed_for_origin?(normalized, origin_host)

          attrs[:domain] = normalized
          attrs[:host_only] = false
        when 'path'
          attrs[:path] = val && val.start_with?('/') ? val : '/'
        when 'secure'
          attrs[:secure] = true
        when 'httponly'
          attrs[:http_only] = true
        when 'max-age'
          seconds = val.to_i
          attrs[:expires] = seconds <= 0 ? Time.at(0) : Time.now + seconds
        when 'expires'
          attrs[:expires] = parse_expiry(val)
        when 'samesite'
          attrs[:same_site] = val&.downcase
        end
      end

      if Security.pinterest_host?(attrs[:domain]) && attrs[:host_only]
        attrs[:domain] = 'pinterest.com'
        attrs[:host_only] = false
      end

      Cookie.new(**attrs)
    end

    def domain_allowed_for_origin?(cookie_domain, origin_host)
      return false if cookie_domain.empty? || !cookie_domain.include?('.') && origin_host != cookie_domain
      return true if origin_host == cookie_domain
      return true if cookie_domain == 'pinterest.com' && Security.pinterest_host?(origin_host)

      origin_host.end_with?(".#{cookie_domain}")
    end

    def default_cookie_path(uri_path)
      path = uri_path.to_s
      return '/' if path.empty? || !path.start_with?('/') || path == '/'

      last_slash = path.rindex('/')
      last_slash.nil? || last_slash.zero? ? '/' : path[0...last_slash]
    end

    def parse_expiry(raw)
      return nil if raw.nil? || raw.empty?

      Time.httpdate(raw)
    rescue ArgumentError
      begin
        Time.parse(raw)
      rescue ArgumentError
        nil
      end
    end

    def upsert_unlocked(cookie)
      @entries.reject! do |existing|
        existing.name == cookie.name &&
          existing.domain == cookie.domain &&
          existing.path == cookie.path
      end
      return if cookie.value.empty? || cookie.expired?

      @entries << cookie
    end
  end
end
