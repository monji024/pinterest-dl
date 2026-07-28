#!/usr/bin/env ruby
# Pinterest downloader
# creator: Monji 
# ver: 1.0.3
# github: https://github.com/monji024/pinterest-dl

require 'net/http'
require 'uri'
require 'json'
require 'openssl'


module PinterestDL
  ver = '1.0.3'.freeze
  github  = 'https://github.com/monji024/pinterest-dl'.freeze

  puts "pinterest-dl v#{ver} (#{github})\n\n"

  USER_AGENT = 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/91.0.4472.124 Safari/537.36'.freeze

  class << self
    def get_image_url(pin_url)
      html = fetch_html(pin_url)
      return nil unless html

      # 1 -> json-ld
      url = extract_json_ld(html, 'ImageObject')
      return url if url
      # 2 -> open graph
      match = html.match(%r{<meta[^>]*property="og:image"[^>]*content="([^"]+)"})
      if match
        url = match[1]
        puts "image url: #{url}"
        return url
      end
      # 3 -> direct i.pinimg.com patterns
      match = html.match(%r{https://i\.pinimg\.com/(?:originals|474x|236x|736x)/[^"\s]+})
      if match
        url = match[0]
        reset = "\e[0m"
        green = "\e[32m"
        puts "#{green}image url :#{reset} #{url}"
        return url
      end
      puts 'No found:)'
      nil
    end


    def get_video_url(pin_url)
      html = fetch_html(pin_url)
      return nil unless html

      # 1 -> json-ld
      url = extract_json_ld(html, 'VideoObject')
      if url
        url = url.gsub('\\u002F', '/').gsub('\\', '')
        puts "ok : #{url}"
        return url
      end
      # 2 -> Open Graph video
      match = html.match(%r{<meta[^>]*property="og:video"[^>]*content="([^"]+)"})
      if match
        url = match[1].gsub('\\u002F', '/').gsub('\\', '')
        puts "video url: #{url}"
        return url
      end
      # 3 -> contentUrl in page source
      match = html.match(/"contentUrl"\s*:\s*"([^"]+\.mp4[^"]*)"/)
      if match
        url = match[1].gsub('\\u002F', '/').gsub('\\', '')
        green = "\e[32m"
        reset = "\e[0m"
        puts "#{green}video url :#{reset} #{url}"
        return url
      end

      puts 'No found'
      nil
    end
    def search(query, limit: 25)
      source_path = "/search/pins/?q=#{URI.encode_www_form_component(query)}"
      home_uri = URI("https://www.pinterest.com#{source_path}")
      http = Net::HTTP.new(home_uri.host, home_uri.port)
      http.use_ssl = true
      http.open_timeout = 10
      http.read_timeout = 20
      home_req = Net::HTTP::Get.new(home_uri, 'User-Agent' => USER_AGENT)
      home_resp = http.request(home_req)
      cookies = (home_resp.get_fields('set-cookie') || []).map { |c| c.split(';').first }
      cookie_header = cookies.join('; ')
      csrf = cookies.find { |c| c.start_with?('csrftoken=') }&.split('=', 2)&.last || 'undefined'
      data = {
        options: { query: query, scope: 'pins', page_size: limit },
        context: {}}.to_json
      res_uri = URI('https://www.pinterest.com/resource/BaseSearchResource/get/')
      res_uri.query = URI.encode_www_form('source_url' => source_path, 'data' => data)
      req = Net::HTTP::Get.new(res_uri)
      req['User-Agent'] = USER_AGENT
      req['Accept'] = 'application/json, text/javascript, */*, q=0.01'
      req['X-Requested-With'] = 'XMLHttpRequest'
      req['X-Pinterest-PWS-Handler'] = 'www/search/[scope].js'
      req['X-CSRFToken'] = csrf
      req['Referer'] = home_uri.to_s
      req['Cookie'] = cookie_header
      resp = http.request(req)
      unless resp.is_a?(Net::HTTPSuccess)
        puts "\e[31msearch http err!:\e[0m #{resp.code}"
        return []
      end
      json = begin
        JSON.parse(resp.body)
      rescue JSON::ParserError
        nil
      end
      return [] unless json
      raw_results = (json.dig('resource_response', 'data', 'results') || []).first(limit)
      pins = raw_results.filter_map do |r|
        id = r['id']
        next nil unless id
        orig_image = r.dig('images', 'orig', 'url')
        fallback_image = r['images']&.values&.map { |v| v.is_a?(Hash) ? v['url'] : nil }&.compact&.last
        image_url = orig_image || fallback_image
        video_url = r.dig('videos', 'video_list')&.values&.first&.dig('url')
        {
          id: id,
          pin_url: "https://www.pinterest.com/pin/#{id}/",
          title: r['title'] || r['grid_title'],
          description: r['description'],
          image_url: image_url,
          video_url: video_url
        }
      end
      green = "\e[32m"
      reset = "\e[0m"
      puts "#{green}found #{pins.size} pin(s) for \"#{query}\"#{reset}"
      pins
    rescue StandardError => e
      puts "\e[31msearch err!:\e[0m #{e.message}"
      []
    end
    def search_json(query, limit: 25)
      JSON.pretty_generate(search(query, limit: limit))
    end
    def search_images(query, limit: 25)
      search(query, limit: limit).filter_map { |p| p[:image_url] }
    end
    def search_videos(query, limit: 25)
      search(query, limit: limit).filter_map { |p| p[:video_url] }
    end
    private

    def fetch_html(url)
      uri = URI(url)
      http = Net::HTTP.new(uri.host, uri.port)
      http.use_ssl = (uri.scheme == 'https')
      http.max_retries = 2
      http.open_timeout = 10
      http.read_timeout = 20
      resp = http.request(Net::HTTP::Head.new(uri, 'User-Agent' => USER_AGENT))
      5.times do
        break unless resp.is_a?(Net::HTTPRedirection)
        location = resp['location']
        location = URI.join(uri.to_s, location) if location.start_with?('/')
        uri = URI(location)
        http = Net::HTTP.new(uri.host, uri.port)
        http.use_ssl = (uri.scheme == 'https')
        resp = http.request(Net::HTTP::Head.new(uri, 'User-Agent' => USER_AGENT))
      end
      # get final page
      req = Net::HTTP::Get.new(uri, 'User-Agent' => USER_AGENT)
      resp = http.request(req)
      return resp.body if resp.is_a?(Net::HTTPSuccess)
      nil
    rescue StandardError => e
      red = "\e[31m"
      reset = "\e[0m"
      puts "#{red}http err!:#{reset} #{e.message}"
      nil
    end
    def extract_json_ld(html, type)
      match = html.match(%r{<script[^>]*type="application/ld\+json"[^>]*>(.*?)</script>}m)
      return nil unless match
      begin
        data = JSON.parse(match[1])
        data = data[0] if data.is_a?(Array) && !data.empty?
        return data['contentUrl'] if data['@type'] == type && data['contentUrl']
      rescue JSON::ParserError
      end
      nil
    end
  end
end