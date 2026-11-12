# frozen_string_literal: true

require 'ipaddr'
require 'resolv'
require 'uri'

module PinterestDL
  module Security
    PINTEREST_DOMAIN_REGEX = /\A(?:[a-z0-9-]+\.)*pinterest\.(?:com|[a-z]{2,3}(?:\.[a-z]{2})?)\z/i
    PINIMG_DOMAIN_REGEX = /\A(?:[a-z0-9-]+\.)*pinimg\.com\z/i
    SHORTENER_DOMAIN_REGEX = /\Apin\.it\z/i

    PRIVATE_CIDRS = [
      IPAddr.new('0.0.0.0/8'),
      IPAddr.new('10.0.0.0/8'),
      IPAddr.new('100.64.0.0/10'),
      IPAddr.new('127.0.0.0/8'),
      IPAddr.new('169.254.0.0/16'),
      IPAddr.new('172.16.0.0/12'),
      IPAddr.new('192.0.0.0/24'),
      IPAddr.new('192.0.2.0/24'),
      IPAddr.new('192.168.0.0/16'),
      IPAddr.new('198.18.0.0/15'),
      IPAddr.new('198.51.100.0/24'),
      IPAddr.new('203.0.113.0/24'),
      IPAddr.new('224.0.0.0/4'),
      IPAddr.new('240.0.0.0/4'),
      IPAddr.new('::/128'),
      IPAddr.new('::1/128'),
      IPAddr.new('fc00::/7'),
      IPAddr.new('fe80::/10'),
      IPAddr.new('ff00::/8')
    ].freeze

    SENSITIVE_KEY_PATTERN = /
      (cookie|set-cookie|csrftoken|x-csrftoken|sessionid|_pinterest_sess|_auth|authorization|token|password|secret)
      (\s*[:=]\s*)
      ([^\s,;'"&]+)
    /ix

    URL_CREDENTIAL_PATTERN = %r{(https?://[^/\s:@]+:)([^@\s/]+)(@)}i

    module_function

    def parse_and_validate_url!(raw_url, allow_local: false, allowed_hosts: nil, https_only: false)
      str = raw_url.to_s.strip
      raise InvalidURLError.new('URL must not be empty', url: raw_url) if str.empty?

      uri = URI.parse(str)
      validate_scheme!(uri, raw_url, https_only: https_only)
      validate_host_presence!(uri, raw_url)
      validate_no_credentials!(uri, raw_url)
      validate_ssrf!(uri, raw_url, allow_local: allow_local)
      validate_allowed_host!(uri, raw_url, allowed_hosts: allowed_hosts, allow_local: allow_local)
      uri
    rescue URI::InvalidURIError => e
      raise InvalidURLError.new("Malformed URL: #{raw_url}", url: raw_url, cause_error: e)
    end

    def validate_scheme!(uri, raw_url, https_only: false)
      schemes = https_only ? %w[https] : %w[http https]
      return if schemes.include?(uri.scheme.to_s.downcase)

      raise InvalidURLError.new("Unsupported URL scheme #{uri.scheme.inspect} for #{raw_url}", url: raw_url)
    end

    def validate_host_presence!(uri, raw_url)
      host = uri.host.to_s.strip
      raise InvalidURLError.new("Missing host in URL: #{raw_url}", url: raw_url) if host.empty?
      raise InvalidURLError.new("Invalid host in URL: #{raw_url}", url: raw_url) if host.include?(' ')
    end

    def validate_no_credentials!(uri, raw_url)
      return if uri.user.nil? && uri.password.nil?

      raise InvalidURLError.new("Credentials in URL are not allowed: #{redact(raw_url.to_s)}", url: redact(raw_url.to_s))
    end

    def validate_ssrf!(uri, raw_url, allow_local: false)
      return if allow_local

      host = clean_host(uri.host)
      if host == 'localhost' || host.end_with?('.localhost') || host.end_with?('.local') || host.end_with?('.internal')
        raise SSRFError.new("Blocked internal host #{host}", url: raw_url)
      end

      ip = parse_ip(host)
      if ip
        raise SSRFError.new("Blocked internal IP address #{ip}", url: raw_url) if private_ip?(ip)

        return
      end

      return if trusted_domain?(host)

      resolve_ips(host).each do |resolved|
        raise SSRFError.new("Host #{host} resolved to restricted address #{resolved}", url: raw_url) if private_ip?(resolved)
      end
    end

    def validate_allowed_host!(uri, raw_url, allowed_hosts: nil, allow_local: false)
      return if allowed_hosts.nil?

      host = clean_host(uri.host)
      return if allow_local && local_host?(host)

      matched = Array(allowed_hosts).any? do |pattern|
        pattern.is_a?(Regexp) ? pattern.match?(host) : host == pattern.to_s.downcase
      end
      return if matched

      raise InvalidURLError.new("Host #{host.inspect} is not in the allowed host list", url: raw_url)
    end

    def pinterest_host?(host)
      PINTEREST_DOMAIN_REGEX.match?(clean_host(host))
    end

    def pinimg_host?(host)
      PINIMG_DOMAIN_REGEX.match?(clean_host(host))
    end

    def shortener_host?(host)
      SHORTENER_DOMAIN_REGEX.match?(clean_host(host))
    end

    def trusted_domain?(host)
      pinterest_host?(host) || pinimg_host?(host) || shortener_host?(host)
    end

    def cookie_eligible_host?(host, allow_local: false)
      cleaned = clean_host(host)
      return true if allow_local && local_host?(cleaned)

      pinterest_host?(cleaned)
    end

    def same_security_domain?(source_uri, target_uri)
      src_host = clean_host(source_uri.host)
      dst_host = clean_host(target_uri.host)
      return true if src_host == dst_host
      return true if pinterest_host?(src_host) && pinterest_host?(dst_host)

      false
    end

    def allowed_redirect_target?(source_uri, target_uri, allow_local: false)
      dst_host = clean_host(target_uri.host)
      return false if target_uri.scheme == 'http' && source_uri.scheme == 'https' && !allow_local
      return true if allow_local && local_host?(dst_host)

      trusted_domain?(dst_host) || clean_host(source_uri.host) == dst_host
    end

    def local_host?(host)
      cleaned = clean_host(host)
      return true if cleaned == 'localhost'

      ip = parse_ip(cleaned)
      !ip.nil? && private_ip?(ip)
    end

    def private_ip?(ip_addr)
      addr = ip_addr.is_a?(IPAddr) ? ip_addr : parse_ip(ip_addr.to_s)
      return false unless addr

      addr = addr.native if addr.respond_to?(:ipv4_mapped?) && addr.ipv4_mapped?
      PRIVATE_CIDRS.any? { |cidr| cidr.include?(addr) }
    end

    def parse_ip(str)
      IPAddr.new(str)
    rescue IPAddr::InvalidAddressError, IPAddr::AddressFamilyError
      nil
    end

    def resolve_ips(host)
      Resolv.getaddresses(host).filter_map { |addr| parse_ip(addr) }
    rescue StandardError
      []
    end

    def clean_host(host)
      host.to_s.strip.downcase.sub(/\A\[(.*)\]\z/, '\1').chomp('.')
    end

    def redact(text)
      return '' if text.nil?

      sanitized = text.to_s.dup
      sanitized.gsub!(URL_CREDENTIAL_PATTERN, '\1[REDACTED]\3')
      sanitized.gsub!(SENSITIVE_KEY_PATTERN, '\1\2[REDACTED]')
      sanitized
    end

    def redact_headers(headers)
      return {} unless headers.is_a?(Hash)

      headers.each_with_object({}) do |(key, value), out|
        out[key] = if key.to_s.match?(/\A(cookie|set-cookie|authorization|x-csrftoken|proxy-authorization)\z/i)
                     '[REDACTED]'
                   else
                     redact(value.to_s)
                   end
      end
    end
  end
end
