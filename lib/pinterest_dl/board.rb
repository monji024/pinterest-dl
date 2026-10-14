# frozen_string_literal: true

require 'json'
require 'uri'

module PinterestDL
  class Board
    PAGE_SIZE = 50

    def initialize(client: PinterestDL::Client.new, config: PinterestDL.config)
      @client = client
      @config = config
    end

    def call(board_url, limit: 50, pages: 10, type: :all)
      username, slug, section = parse_url(board_url)
      html = start_session(username, slug)
      board_id = board_id_from_page(html, slug) || find_board_id(username, slug)
      resource, options = feed_request(board_id, section)

      results = []
      bookmarks = nil
      pages_fetched = 0

      loop do
        page = fetch_page(resource, options, bookmarks)
        results.concat(PinterestDL::MediaType.filter(page[:pins], type))
        bookmarks = page[:bookmarks]
        pages_fetched += 1

        break if results.size >= limit
        break if bookmarks.empty? || bookmarks == ['-end-']
        break if pages_fetched >= pages
        break if page[:pins].empty?
      end

      results.first(limit)
    end

    private

    def parse_url(board_url)
      url = board_url.to_s
      if url.include?('pin.it/')
        @client.raw_get(url)
        url = @client.last_url
      end

      uri = URI(url)
      parts = uri.path.to_s.split('/').reject(&:empty?)
      valid = uri.host.to_s.include?('pinterest') && [2, 3].include?(parts.size) && parts.first != 'pin'
      raise PinterestDL::InvalidURLError, "Not a Pinterest board URL: #{board_url}" unless valid

      parts
    rescue URI::InvalidURIError
      raise PinterestDL::InvalidURLError, "Not a Pinterest board URL: #{board_url}"
    end

    def start_session(username, slug)
      response = @client.raw_get("https://www.pinterest.com/#{username}/#{slug}/")
      @page_url = @client.last_url
      @host = URI(@page_url).host
      @source_path = URI(@page_url).path
      response.body
    end

    def board_id_from_page(html, slug)
      html.to_s.scan(PinterestDL::Extractors::PinData::SCRIPT_PATTERN).each do |(raw)|
        data = PinterestDL::Extractors::PinData.safe_parse(raw)
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
      nil
    end

    def board_node?(node, slug)
      node['type'] == 'board' && node['id'].to_s.match?(/\A\d+\z/) && node['url'].to_s.include?("/#{slug}/")
    end

    def find_board_id(username, slug)
      json = call_resource('BoardResource', username: username, slug: slug, field_set_key: 'detailed')
      data = json.dig('resource_response', 'data')
      id = data.is_a?(Hash) && data['id']
      raise PinterestDL::NotFoundError, "Board not found: #{username}/#{slug} (private boards need --cookies)" unless id

      id
    end

    def feed_request(board_id, section)
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
      found = data.is_a?(Array) && data.find { |s| s['slug'] == slug }
      raise PinterestDL::NotFoundError, "Section not found: #{slug}" unless found

      found['id']
    end

    def fetch_page(resource, options, bookmarks)
      options = options.merge(bookmarks: bookmarks) if bookmarks && !bookmarks.empty?
      json = call_resource(resource, options)

      data = json.dig('resource_response', 'data')
      pins = data.is_a?(Array) ? data.filter_map { |r| build_pin(r) } : []
      { pins: pins, bookmarks: Array(json.dig('resource_response', 'bookmark')) }
    end

    def call_resource(name, options)
      data = { options: options, context: {} }.to_json
      uri = URI("https://#{@host}/resource/#{name}/get/")
      uri.query = URI.encode_www_form('source_url' => @source_path, 'data' => data)

      body = @client.get(uri.to_s, use_cache: false, headers: api_headers)
      JSON.parse(body)
    rescue JSON::ParserError, TypeError
      raise PinterestDL::NotFoundError, "Unexpected response from Pinterest (#{name})"
    end

    def api_headers
      {
        'Accept' => 'application/json, text/javascript, */*, q=0.01',
        'X-Requested-With' => 'XMLHttpRequest',
        'X-Pinterest-PWS-Handler' => 'www/[username]/[slug].js',
        'X-CSRFToken' => @client.cookie('csrftoken', @page_url) || 'undefined',
        'Referer' => @page_url
      }
    end

    def build_pin(raw)
      return nil unless raw.is_a?(Hash)
      return nil if raw['type'] && raw['type'] != 'pin'

      id = raw['id']
      return nil unless id

      {
        id: id,
        pin_url: "https://www.pinterest.com/pin/#{id}/",
        title: raw['title'] || raw['grid_title'],
        description: raw['description'],
        creator: raw.dig('pinner', 'username') || raw.dig('pinner', 'full_name'),
        image_url: raw.dig('images', 'orig', 'url'),
        video_url: PinterestDL::Extractors::PinData.first_video_url(raw)
      }
    end
  end
end
