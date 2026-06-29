# frozen_string_literal: true

require 'json'
require 'uri'

module PinterestDL
  class Board
    PAGE_SIZE = 50
    RESERVED_PATHS = %w[pin search ideas today settings business].freeze

    def initialize(client: PinterestDL::Client.new, config: PinterestDL.config)
      @client = client
      @config = config
    end

    def call(board_url, limit: 50, pages: 10, type: :all)
      username, slug, section = parse_url(board_url)
      html = start_session(username, slug)
      board_id = board_id_from_page(html, slug) || find_board_id(username, slug)
      resource, options = feed_request(board_id, section)

# step-0
