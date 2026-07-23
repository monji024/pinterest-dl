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

# step-0
