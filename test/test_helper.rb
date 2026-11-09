# frozen_string_literal: true

$LOAD_PATH.unshift(File.expand_path('../lib', __dir__))

if ENV['COVERAGE'] == '1' || ENV['CI'] == 'true'
  begin
    require 'simplecov'
    SimpleCov.start do
      add_filter '/test/'
      enable_coverage :branch
    end
  rescue LoadError
    nil
  end
end

require 'cgi'
require 'pinterest-dl'
require 'minitest/autorun'

module FixtureHelper
  FIXTURES_DIR = File.expand_path('fixtures', __dir__).freeze

  def fixture_path(name)
    File.join(FIXTURES_DIR, name)
  end

  def read_fixture(name)
    File.read(fixture_path(name))
  end
end

class FakeClient
  FakeResponse = Struct.new(:body, :response_headers, :code) do
    def get_fields(name)
      (response_headers || {})[name.downcase] || (response_headers || {})[name] || []
    end

    def [](name)
      hdrs = response_headers || {}
      val = hdrs[name] || hdrs[name.downcase] || hdrs[name.to_sym]
      val.is_a?(Array) ? val.first : val
    end
  end

  def initialize(responses = {}, raw_headers: {})
    @responses = responses
    @raw_headers = raw_headers
    @calls = []
    @request_headers_history = []
  end

  attr_reader :calls, :last_headers, :last_use_cache, :last_url, :request_headers_history

  def get(url, headers: {}, use_cache: true)
    @calls << url
    @last_url = url
    @last_headers = headers
    @request_headers_history << headers
    @last_use_cache = use_cache
    body_for(url)
  end

  def raw_get(url, headers: {})
    @calls << url
    @last_url = url
    @last_headers = headers
    @request_headers_history << headers
    hdrs = headers_for(url)
    body = body_for(url)
    status = (hdrs['status'] || hdrs[:status] || '200').to_s
    FakeResponse.new(body, hdrs, status)
  end

  def cookie(name, _url = nil)
    lines = @raw_headers.values.flat_map do |hdrs|
      h = hdrs.is_a?(Array) ? hdrs.last : hdrs
      (h && (h['set-cookie'] || h['Set-Cookie'])) || []
    end
    lines.filter_map do |line|
      key, value = line.split(';').first.split('=', 2)
      value if key == name
    end.last
  end

  private

  def body_for(url)
    @responses.each do |key, body|
      matched = key.is_a?(Regexp) ? key.match?(url) : key == url
      next unless matched

      if body.is_a?(Array)
        item = body.size > 1 ? body.shift : body.first
        return item.is_a?(Proc) ? item.call(url) : item
      end
      return body.is_a?(Proc) ? body.call(url) : body
    end
    raise "FakeClient: no stubbed response for #{url}"
  end

  def headers_for(url)
    @raw_headers.each do |key, hdrs|
      matched = key.is_a?(Regexp) ? key.match?(url) : key == url
      next unless matched

      if hdrs.is_a?(Array)
        item = hdrs.size > 1 ? hdrs.shift : hdrs.first
        return item.is_a?(Proc) ? item.call(url) : item
      end
      return hdrs.is_a?(Proc) ? hdrs.call(url) : hdrs
    end
    {}
  end
end
