# frozen_string_literal: true

require_relative '../test_helper'
require 'tmpdir'

class CookieJarTest < Minitest::Test
  def test_stores_and_matches_domain_and_path_attributes
    jar = PinterestDL::CookieJar.new
    jar.set_from_header(
      [
        'csrftoken=abc123; Domain=.pinterest.com; Path=/; Secure',
        'board_scoped=secret99; Domain=www.pinterest.com; Path=/someuser/board; HttpOnly'
      ],
      'https://www.pinterest.com/someuser/board/'
    )

    root_hdr = jar.header_for('https://www.pinterest.com/pin/1/')
    assert_includes root_hdr, 'csrftoken=abc123'
    refute_includes root_hdr, 'board_scoped=secret99'

    sub_hdr = jar.header_for('https://www.pinterest.com/someuser/board/section')
    assert_includes sub_hdr, 'csrftoken=abc123'
    assert_includes sub_hdr, 'board_scoped=secret99'
  end

  def test_never_sends_cookies_to_cdn_or_external_domains
    jar = PinterestDL::CookieJar.new
    jar.load_raw('sessionid=topsecret; csrftoken=csrf123')

    assert_includes jar.header_for('https://www.pinterest.com/pin/1/'), 'sessionid=topsecret'
    assert_includes jar.header_for('https://de.pinterest.com/pin/1/'), 'sessionid=topsecret'
    assert_equal '', jar.header_for('https://i.pinimg.com/originals/a.jpg')
    assert_equal '', jar.header_for('https://v1.pinimg.com/videos/a.mp4')
    assert_equal '', jar.header_for('https://pin.it/short')
    assert_equal '', jar.header_for('https://evil.com/steal')
  end

  def test_secure_cookies_are_not_sent_over_plain_http
    jar = PinterestDL::CookieJar.new
    jar.set_from_header(['_pinterest_sess=sec_val; Domain=.pinterest.com; Path=/; Secure'], 'https://www.pinterest.com/')

    assert_equal '_pinterest_sess=sec_val', jar.header_for('https://www.pinterest.com/')
    assert_equal '', jar.header_for('http://www.pinterest.com/')
  end

  def test_expired_cookies_are_evicted
    jar = PinterestDL::CookieJar.new
    jar.set_from_header(['temp=1; Path=/; Max-Age=0'], 'https://www.pinterest.com/')
    assert_equal '', jar.header_for('https://www.pinterest.com/')
  end

  def test_rejects_domain_attribute_for_unrelated_origin
    jar = PinterestDL::CookieJar.new
    jar.set_from_header(['hijack=1; Domain=evil.com; Path=/'], 'https://www.pinterest.com/')
    assert_equal '', jar.header_for('https://evil.com/', allow_local: true)
  end

  def test_loads_netscape_cookie_file_and_ignores_non_pinterest_entries
    Dir.mktmpdir do |dir|
      file = File.join(dir, 'cookies.txt')
      File.write(file, <<~COOKIES)
        # Netscape HTTP Cookie File
        .pinterest.com\tTRUE\t/\tTRUE\t2147483647\t_pinterest_sess\tsess_from_file
        #HttpOnly_.pinterest.com\tTRUE\t/\tFALSE\t2147483647\tcsrftoken\tcsrf_from_file
        .google.com\tTRUE\t/\tTRUE\t2147483647\tNID\tgoogle_cookie
      COOKIES

      jar = PinterestDL::CookieJar.new
      jar.load_raw(file)

      hdr = jar.header_for('https://www.pinterest.com/pin/1/')
      assert_includes hdr, '_pinterest_sess=sess_from_file'
      assert_includes hdr, 'csrftoken=csrf_from_file'
      refute_includes hdr, 'google_cookie'
    end
  end
end
