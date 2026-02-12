#!/usr/bin/env ruby
# pinterest-dl.rb
# Pinterest downloader
# creator: Monji 
# ver: 1.0.0
# github: https://github.com/monji024/pinterest-dl

require 'net/http'
require 'uri'
require 'json'
require 'openssl'


module PinterestDL
  ver = '1.0.0'.freeze
  craetor  = 'Monji'.freeze
  github  = 'https://github.com/monji024/pinterest-dl'.freeze

  puts "pinterest-dl v#{ver} by #{craetor} (#{github})\n\n"

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

      puts 'No found'
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
