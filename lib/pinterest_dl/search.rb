# frozen_string_literal: true

require 'json'
require 'net/http'
require 'uri'

module PinterestDL
  class Search
    S_URL = 'https://www.pinterest.com/resource/BaseSearchResource/get/'

    def initialize(client: PinterestDL::Client.new, config: PinterestDL.config)
      @client = client
      @config = config
    end

    def call(query, limit: 25, pages: 5, type: :all)
      raise ArgumentError, 'query must not be empty' if query.to_s.strip.empty?

# step-0
