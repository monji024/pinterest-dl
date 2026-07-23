# frozen_string_literal: true

$LOAD_PATH.unshift(File.expand_path('../lib', __dir__))

require 'cgi'
require 'pinterest-dl'
require 'minitest/autorun'

class FakeClient
  FakeResponse = Struct.new(:body, :response_headers) do
    def get_fields(name)
      (response_headers || {})[name] || []
    end
  end

  def initialize(responses = {}, raw_headers: {})
    @responses = responses
    @raw_headers = raw_headers
    @calls = []
  end

  attr_reader :calls, :last_headers, :last_use_cache, :last_url

  def get(url, headers: {}, use_cache: true)
    @calls << url
    @last_url = url
    @last_headers = headers
    @last_use_cache = use_cache
    body_for(url)
  end

  def raw_get(url, headers: {})
    @calls << url
    @last_url = url
    @last_headers = headers
    FakeResponse.new(body_for(url), headers_for(url))
  end

  def cookie(name, _url = nil)
    lines = @raw_headers.values.flat_map { |hdrs| hdrs['set-cookie'] || [] }
    lines.filter_map do |line|
      key, value = line.split(';').first.split('=', 2)
      value if key == name
    end.last
  end

  private

  def body_for(url)
    @responses.each do |key, body|
      matched = key.is_a?(Regexp) ? key.match?(url) : key == url
      body = body.size > 1 ? body.shift : body.first if body.is_a?(Array)
      return body.is_a?(Proc) ? body.call(url) : body if matched
    end
    raise "FakeClient: no stubbed response for #{url}"
  end

  def headers_for(url)
    @raw_headers.each do |key, hdrs|
      matched = key.is_a?(Regexp) ? key.match?(url) : key == url
      return hdrs if matched
    end
    {}
  end
end
