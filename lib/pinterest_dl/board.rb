# frozen_string_literal: true

require 'json'
require 'uri'
require_relative 'paginator'
require_relative 'media_type'
require_relative 'security'
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

      uri = URI.parse(url)
      if Security.shortener_host?(uri.host)
        @client.raw_get(url)
        url = @client.last_url.to_s
        uri = URI.parse(url)
      end

      parts = uri.path.to_s.split('/').reject(&:empty?)
      valid = %w[http https].include?(uri.scheme.to_s.downcase) &&
              uri.user.nil? && uri.password.nil? &&
              Security.pinterest_host?(uri.host) &&
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
    end

    def board_node?(node, slug)
      node['type'] == 'board' && node['id'].to_s.match?(/\A\d+\z/) &&
        node['url'].to_s.downcase.include?("/#{slug.to_s.downcase}/")
    end

    def find_board_id(username, slug)
      json = call_resource('BoardResource', username: username, slug: slug, field_set_key: 'detailed')
      data = json.dig('resource_response', 'data')
      id = data.is_a?(Hash) && data['id']
      raise PinterestDL::NotFoundError, "Board not found: #{username}/#{slug} (private boards need --cookies)" unless id

      id.to_s
    end

    def feed_request(board_id, section)
      @section = section
      unless section
        options = {
          board_id: board_id,
          field_set_key: 'react_grid_pin',
          filter_section_pins: true,
          sort: 'default',
          layout: 'default',
          page_size: PAGE_SIZE,
          redux_normalize_feed: true
        }
        return ['BoardFeedResource', options]
      end

      ['BoardSectionPinsResource', { section_id: find_section_id(board_id, section), page_size: PAGE_SIZE }]
    end

    def find_section_id(board_id, slug)
      json = call_resource('BoardSectionsResource', board_id: board_id)
      data = json.dig('resource_response', 'data')
      found = data.is_a?(Array) && data.find { |s| s.is_a?(Hash) && s['slug'].to_s.casecmp?(slug.to_s) }
      raise PinterestDL::NotFoundError, "Section not found: #{slug}" unless found

      found['id']
    end

    def fetch_page(resource, options, bookmarks)
      req_options = bookmarks && !bookmarks.empty? ? options.merge(bookmarks: bookmarks) : options
      json = call_resource(resource, req_options)

      data = json.dig('resource_response', 'data')
      pins = data.is_a?(Array) ? data.filter_map { |r| build_pin(r) } : []
      next_bookmarks = json.dig('resource_response', 'bookmark') ||
                       json.dig('resource', 'options', 'bookmarks')
      { pins: pins, bookmarks: Array(next_bookmarks) }
    end

    def call_resource(name, options)
      data = { options: options, context: {} }.to_json
      uri = URI("https://#{@host}/resource/#{name}/get/")
      uri.query = URI.encode_www_form('source_url' => @source_path, 'data' => data)

      body = @client.get(uri.to_s, use_cache: false, headers: api_headers)
      parsed = JSON.parse(body.to_s)
      raise PinterestDL::NotFoundError, "Unexpected response from Pinterest (#{name})" unless parsed.is_a?(Hash)

      parsed
    rescue JSON::ParserError, TypeError
      raise PinterestDL::NotFoundError, "Unexpected response from Pinterest (#{name})"
    end

    def api_headers
      handler = @section ? 'www/[username]/[slug]/[section_slug].js' : 'www/[username]/[slug].js'
      {
        'Accept' => 'application/json, text/javascript, */*, q=0.01',
        'X-Requested-With' => 'XMLHttpRequest',
        'X-Pinterest-AppState' => 'active',
        'X-Pinterest-Source-Url' => @source_path,
        'X-Pinterest-PWS-Handler' => handler,
        'X-CSRFToken' => @client.cookie('csrftoken', @page_url) || 'undefined',
        'Referer' => @page_url
      }
    end

    def build_pin(raw)
      PinterestDL::Extractors::PinData.build_pin_hash(raw, quality: @config.quality)
    end
  end
end
