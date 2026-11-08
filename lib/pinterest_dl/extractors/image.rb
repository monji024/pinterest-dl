# frozen_string_literal: true

module PinterestDL
  module Extractors
    module Image
      QUALITY_PATH = {
        originals: 'originals',
        '1200x': '1200x',
        '736x': '736x',
        '564x': '564x',
        '474x': '474x',
        '236x': '236x'
      }.freeze

      QUALITY_RANK = {
        'orig' => 100,
        'originals' => 100,
        '1200x' => 80,
        '736x' => 60,
        '600x315' => 50,
        '564x' => 45,
        '474x' => 35,
        '236x' => 20,
        '170x' => 15,
        '136x136' => 10,
        '60x60' => 5
      }.freeze

      BUCKET_REGEX = /(?:originals|1200x|736x|564x|474x|236x|\d+x\d*)/i.freeze

      PINIMG_URL_REGEX = %r{
        https://i\d*\.pinimg\.com/
        (?:originals|1200x|736x|564x|474x|236x|\d+x\d*)/
        [A-Za-z0-9_\-/]+\.(?:jpg|jpeg|png|gif|webp)
      }ix.freeze

      module_function

      def extract(html, quality: :originals)
        url = from_json_ld(html) || from_open_graph(html) || from_srcset(html) || from_raw_pattern(html)
        return nil unless url

        apply_quality(url, quality)
      end

      def from_json_ld(html)
        PinterestDL::Extractors::JsonLd.content_url(html, 'ImageObject')
      end

      def from_open_graph(html)
        PinterestDL::Extractors::Meta.content(html, 'og:image') ||
          PinterestDL::Extractors::Meta.content(html, 'twitter:image:src') ||
          PinterestDL::Extractors::Meta.content(html, 'twitter:image')
      end

      def from_srcset(html)
        candidates = []
        html.to_s.scan(/srcset=["']([^"']+)["']/i).each do |(srcset)|
          srcset.split(',').each do |entry|
            parts = entry.strip.split(/\s+/)
            url = parts[0]
            next unless url && url.match?(%r{\Ahttps://i\d*\.pinimg\.com/}i)

            scale = parts[1].to_s[/\A(\d+)[wx]\z/i, 1].to_i
            candidates << [scale, url]
          end
        end
        return nil if candidates.empty?

        candidates.max_by(&:first).last
      end

      def from_raw_pattern(html)
        matches = html.to_s.scan(PINIMG_URL_REGEX)
        return nil if matches.empty?

        matches.max_by { |u| score_url_quality(u) }
      end

      def score_url_quality(url)
        bucket = url.to_s[%r{i\d*\.pinimg\.com/([^/]+)/}i, 1].to_s.downcase
        return QUALITY_RANK[bucket] if QUALITY_RANK.key?(bucket)

        if (m = bucket.match(/\A(\d+)x(\d+)?\z/))
          w = m[1].to_i
          h = (m[2] || m[1]).to_i
          return [w * h / 10_000, 90].min
        end
        1
      end

      def apply_quality(url, quality)
        return url unless url.to_s.match?(%r{i\d*\.pinimg\.com}i)

        target = QUALITY_PATH[quality.to_sym]
        return url unless target

        url.sub(%r{/#{BUCKET_REGEX}/}, "/#{target}/")
      end
    end
  end
end