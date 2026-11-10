# frozen_string_literal: true

require_relative '../test_helper'

class SecurityTest < Minitest::Test
  def test_blocks_private_and_loopback_ips_when_allow_local_is_false
    %w[
      http://127.0.0.1/admin
      http://10.0.0.1/secret
      http://172.16.0.5/internal
      http://192.168.1.1/router
      http://169.254.169.254/latest/meta-data/
      http://localhost:8080/test
      http://[::1]/loopback
    ].each do |internal_url|
      assert_raises(PinterestDL::SSRFError, "Expected #{internal_url} to be blocked") do
        PinterestDL::Security.parse_and_validate_url!(internal_url, allow_local: false)
      end
    end
  end

  def test_allows_loopback_when_allow_local_is_true
    uri = PinterestDL::Security.parse_and_validate_url!('http://127.0.0.1:4567/page', allow_local: true)
    assert_equal '127.0.0.1', uri.host
  end

  def test_rejects_unsupported_schemes_and_credentials_in_url
    assert_raises(PinterestDL::InvalidURLError) do
      PinterestDL::Security.parse_and_validate_url!('file:///etc/passwd')
    end
    assert_raises(PinterestDL::InvalidURLError) do
      PinterestDL::Security.parse_and_validate_url!('ftp://i.pinimg.com/file.jpg')
    end
    assert_raises(PinterestDL::InvalidURLError) do
      PinterestDL::Security.parse_and_validate_url!('https://user:secret@www.pinterest.com/pin/1/')
    end
  end

  def test_recognizes_pinterest_and_pinimg_hosts_accurately
    assert PinterestDL::Security.pinterest_host?('www.pinterest.com')
    assert PinterestDL::Security.pinterest_host?('de.pinterest.com')
    assert PinterestDL::Security.pinterest_host?('www.pinterest.co.uk')
    refute PinterestDL::Security.pinterest_host?('evilpinterest.com')
    refute PinterestDL::Security.pinterest_host?('pinterest.com.attacker.net')

    assert PinterestDL::Security.pinimg_host?('i.pinimg.com')
    assert PinterestDL::Security.pinimg_host?('v1.pinimg.com')
    refute PinterestDL::Security.pinimg_host?('fakepinimg.com')
  end

  def test_cookie_eligibility_restricts_cookies_to_pinterest_domains_only
    assert PinterestDL::Security.cookie_eligible_host?('www.pinterest.com')
    assert PinterestDL::Security.cookie_eligible_host?('fr.pinterest.com')
    refute PinterestDL::Security.cookie_eligible_host?('i.pinimg.com')
    refute PinterestDL::Security.cookie_eligible_host?('v1.pinimg.com')
    refute PinterestDL::Security.cookie_eligible_host?('pin.it')
    refute PinterestDL::Security.cookie_eligible_host?('attacker.example.com')
  end

  def test_validates_cross_domain_redirect_targets
    src = URI('https://pin.it/abc')
    good_dst = URI('https://www.pinterest.com/pin/123/')
    evil_dst = URI('https://evil.example.com/phish')
    downgrade_dst = URI('http://www.pinterest.com/pin/123/')

    assert PinterestDL::Security.allowed_redirect_target?(src, good_dst)
    refute PinterestDL::Security.allowed_redirect_target?(src, evil_dst)
    refute PinterestDL::Security.allowed_redirect_target?(src, downgrade_dst)
  end

  def test_redacts_cookies_tokens_and_credentials_from_logs
    raw = 'Cookie: sessionid=supersecret123; csrftoken=tok999 proxy=http://admin:my_pass@10.0.0.1:8080'
    cleaned = PinterestDL::Security.redact(raw)

    refute_includes cleaned, 'supersecret123'
    refute_includes cleaned, 'tok999'
    refute_includes cleaned, 'my_pass'
    assert_includes cleaned, '[REDACTED]'
  end
end
