# frozen_string_literal: true

require_relative '../test_helper'
require 'socket'

class ClientTest < Minitest::Test
  def setup
    PinterestDL.config.logger.level = Logger::FATAL
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
      path = sock.gets.to_s.split[1]
      cookie = nil
      while (line = sock.gets) && line != "\r\n"
        cookie = line if line.downcase.start_with?('cookie:')
      end
      status, extra, body = respond(path, cookie.to_s.include?('sess=1'))
      sock.write "HTTP/1.1 #{status}\r\n#{extra}Content-Length: #{body.bytesize}\r\nConnection: close\r\n\r\n#{body}"
      sock.close
    end
  end

  def respond(path, has_cookie)
    case path
    when '/start' then ['302 Found', "Location: /page\r\n", '']
    when '/page' then page_response(has_cookie)
    when '/loop' then ['302 Found', "Location: /loop\r\n", '']
    when '/relative' then ['301 Moved Permanently', "Location: sub/page\r\n", '']
    when '/sub/page' then ['200 OK', "Set-Cookie: csrftoken=abc123; Path=/\r\n", 'ok']
    else ['404 Not Found', '', 'nope']
    end
  end

  def page_response(has_cookie)
    return ['200 OK', '', 'final page'] if has_cookie

    ['302 Found', "Location: /page\r\nSet-Cookie: sess=1; Path=/\r\n", '']
  end

  def test_follows_redirects_and_keeps_cookies
    client = PinterestDL::Client.new
    assert_equal 'final page', client.get("#{@base}/start")
    assert_equal "#{@base}/page", client.last_url
  end

  def test_raises_on_redirect_loop
    error = assert_raises(PinterestDL::NetworkError) { PinterestDL::Client.new.get("#{@base}/loop") }
    assert_includes error.message, 'Too many redirects'
  end

  def test_raw_get_returns_the_final_response
    client = PinterestDL::Client.new
    response = client.raw_get("#{@base}/relative")

    assert_equal 'ok', response.body
    assert_equal "#{@base}/sub/page", client.last_url
    assert_equal 'abc123', client.cookie('csrftoken')
  end

  def test_raises_not_found
    assert_raises(PinterestDL::NotFoundError) { PinterestDL::Client.new.get("#{@base}/missing") }
  end
end
