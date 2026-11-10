# frozen_string_literal: true

require_relative '../test_helper'
require 'socket'

class ClientTest < Minitest::Test
  def setup
    @config = PinterestDL::Configuration.new(allow_local_network: true, retry_wait: 0.01, max_retries: 2)
    @config.logger.level = Logger::FATAL
    @request_counts = Hash.new(0)
    @server = TCPServer.new('127.0.0.1', 0)
    @base = "http://127.0.0.1:#{@server.addr[1]}"
    @thread = Thread.new { serve }
  end

  def teardown
    @thread.kill
    @server.close
  end

  def serve
    loop do
      sock = @server.accept
      request_line = sock.gets.to_s
      path = request_line.split[1]
      @request_counts[path] += 1
      cookie = nil
      while (line = sock.gets) && line != "\r\n"
        cookie = line if line.downcase.start_with?('cookie:')
      end
      if path == '/drop'
        sock.close
        next
      end
      status, extra, body = respond(path, cookie.to_s.include?('sess=1'), @request_counts[path])
      sock.write "HTTP/1.1 #{status}\r\n#{extra}Content-Length: #{body.bytesize}\r\nConnection: close\r\n\r\n#{body}"
      sock.close
    rescue StandardError
      nil
    end
  end

  def respond(path, has_cookie, count)
    case path
    when '/start' then ['302 Found', "Location: /page\r\n", '']
    when '/page' then page_response(has_cookie)
    when '/loop' then ['302 Found', "Location: /loop\r\n", '']
    when '/evil_redirect' then ['302 Found', "Location: https://evil-domain.example.org/steal\r\n", '']
    when '/relative' then ['301 Moved Permanently', "Location: sub/page\r\n", '']
    when '/sub/page' then ['200 OK', "Set-Cookie: csrftoken=abc123; Path=/\r\n", 'ok']
    when '/unauth' then ['401 Unauthorized', '', 'denied']
    when '/forbidden' then ['403 Forbidden', '', 'blocked']
    when '/ratelimit' then ['429 Too Many Requests', "Retry-After: 0.01\r\n", 'slow down']
    when '/flaky' then count < 2 ? ['503 Service Unavailable', "Retry-After: 0.01\r\n", 'busy'] : ['200 OK', '', 'recovered']
    else ['404 Not Found', '', 'nope']
    end
  end

  def page_response(has_cookie)
    return ['200 OK', '', 'final page'] if has_cookie

    ['302 Found', "Location: /page\r\nSet-Cookie: sess=1; Path=/\r\n", '']
  end

  def build_client
    PinterestDL::Client.new(config: @config)
  end

  def test_follows_redirects_and_keeps_cookies
    client = build_client
    assert_equal 'final page', client.get("#{@base}/start")
    assert_equal "#{@base}/page", client.last_url
  end

  def test_raises_on_redirect_loop
    error = assert_raises(PinterestDL::NetworkError) { build_client.get("#{@base}/loop") }
    assert_includes error.message, 'Too many redirects'
  end

  def test_blocks_untrusted_cross_domain_redirect
    assert_raises(PinterestDL::RedirectError) { build_client.get("#{@base}/evil_redirect") }
  end

  def test_raw_get_returns_the_final_response
    client = build_client
    response = client.raw_get("#{@base}/relative")

    assert_equal 'ok', response.body
    assert_equal "#{@base}/sub/page", client.last_url
    assert_equal 'abc123', client.cookie('csrftoken')
  end

  def test_raises_not_found
    assert_raises(PinterestDL::NotFoundError) { build_client.get("#{@base}/missing") }
  end

  def test_cookie_lookup_handles_nil_url_safely
    client = build_client
    assert_nil client.cookie('csrftoken')
  end

  def test_caches_get_responses_until_cleared
    client = build_client
    assert_equal 'ok', client.get("#{@base}/sub/page")
    assert_equal 'ok', client.get("#{@base}/sub/page")
    assert_equal 1, @request_counts['/sub/page']
    client.clear_cache
    assert_equal 0, client.cache_size
  end

  def test_raises_authentication_error_on_401
    assert_raises(PinterestDL::AuthenticationError) { build_client.get("#{@base}/unauth") }
  end

  def test_distinguishes_403_forbidden_from_429_rate_limit
    err_403 = assert_raises(PinterestDL::ForbiddenError) { build_client.get("#{@base}/forbidden") }
    assert_equal 403, err_403.status_code

    err_429 = assert_raises(PinterestDL::RateLimitError) { build_client.get("#{@base}/ratelimit") }
    assert_equal 429, err_429.status_code
    assert_equal '0.01', err_429.retry_after
  end

  def test_retries_transient_503_and_recovers
    client = build_client
    assert_equal 'recovered', client.get("#{@base}/flaky")
    assert_equal 2, @request_counts['/flaky']
  end

  def test_raises_connection_error_on_dropped_socket
    assert_raises(PinterestDL::ConnectionError) { build_client.get("#{@base}/drop") }
  end
end
