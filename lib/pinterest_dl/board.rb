# frozen_string_literal: true

require 'json'
require 'uri'
require_relative 'paginator'
require_relative 'media_type'
require_relative 'extractors/pin_data'

module PinterestDL
  class Board
    PAGE_SIZE = 50
    RESERVED_PATHS = %w[pin search ideas today settings business resource _/_/].freeze

    def initialize(client: PinterestDL::Client.new, config: PinterestDL.config)
      @client = client
      @config = config
    end

    def call(board_url, limit: 50, pages: 10, type: :all)
      parsed_type = MediaType.parse(type)
      username, slug, section = parse_url(board_url)
      html = start_session(username, slug)
      board_id = board_id_from_page(html, slug) || find_board_id(username, slug)
      resource, options = feed_request(board_id, section)

      paginator = Paginator.new(max_pages: pages, limit: limit, type: parsed_type) do |bookmarks, _page_idx|
        fetch_page(resource, options, bookmarks)
      end

      results = paginator.to_a
      if results.empty?
        fallback = PinterestDL::Extractors::PinData.extract_pins(html, quality: @config.quality)
        results = PinterestDL::MediaType.filter(fallback, parsed_type)
      end
      results.first(limit)
    end

    private

    def parse_url(board_url)
      url = board_url.to_s.strip
      raise PinterestDL::InvalidURLError.new("Not a Pinterest board URL: #{board_url}", url: board_url) if url.empty?

      if url.include?('pin.it/')
        @client.raw_get(url)
        url = @client.last_url
      end

      uri = URI(url)
      parts = uri.path.to_s.split('/').reject(&:empty?)
      valid = uri.host.to_s.downcase.include?('pinterest.') &&
              [2, 3].include?(parts.size) &&
              !RESERVED_PATHS.include?(parts.first.to_s.downcase)
      raise PinterestDL::InvalidURLError.new("Not a Pinterest board URL: #{board_url}", url: board_url) unless valid

      parts
    rescue URI::InvalidURIError => e
      raise PinterestDL::InvalidURLError.new("Not a Pinterest board URL: #{board_url}", url: board_url, cause_error: e)
    end

    def start_session(username, slug)
      target = "https://www.pinterest.com/#{username}/#{slug}/"
      response = @client.raw_get(target)
      @page_url = @client.last_url || target
      @host = URI(@page_url).host || 'www.pinterest.com'
      @source_path = URI(@page_url).path || "/#{username}/#{slug}/"
      response.body
    end

    def board_id_from_page(html, slug)
      PinterestDL::Extractors::PinData.each_script_payload(html) do |data|
        stack = [data]
        until stack.empty?
          node = stack.pop
          case node
          when Hash
            return node['id'].to_s if board_node?(node, slug)

            stack.concat(node.values)
          when Array
            stack.concat(node)
          end
        end
      end
      html.to_s[/"board_id"\s*:\s*"(\d+)"/, 1]

# step-0
