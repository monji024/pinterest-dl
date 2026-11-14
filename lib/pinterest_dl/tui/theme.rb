# frozen_string_literal: true

module PinterestDL
  module TUI
    class Theme
      RESET = "\e[0m"
      BOLD = "\e[1m"
      DIM = "\e[2m"

      PALETTE = {
        bg: [13, 9, 26],
        bg_panel: [18, 13, 34],
        bg_pill: [32, 22, 58],
        pink: [255, 59, 141],
        hot_pink: [255, 105, 180],
        purple: [180, 108, 255],
        border_dim: [108, 72, 162],
        border_muted: [68, 46, 108],
        cyan: [92, 225, 255],
        green: [74, 222, 128],
        yellow: [251, 191, 36],
        red: [248, 81, 110],
        white: [245, 240, 255],
        soft_text: [186, 168, 216],
        dim_text: [128, 110, 162]
      }.freeze

      ANSI256_MAP = {
        bg: 17,
        bg_panel: 17,
        bg_pill: 53,
        pink: 198,
        hot_pink: 205,
        purple: 141,
        border_dim: 97,
        border_muted: 60,
        cyan: 81,
        green: 78,
        yellow: 220,
        red: 203,
        white: 231,
        soft_text: 183,
        dim_text: 103
      }.freeze

      ANSI16_MAP = {
        bg: 40,
        bg_panel: 40,
        bg_pill: 45,
        pink: 95,
        hot_pink: 95,
        purple: 35,
        border_dim: 35,
        border_muted: 90,
        cyan: 96,
        green: 92,
        yellow: 93,
        red: 91,
        white: 97,
        soft_text: 37,
        dim_text: 90
      }.freeze

      BORDER_ROUND = {
        tl: '╭', tr: '╮', bl: '╰', br: '╯', h: '─', v: '│'
      }.freeze

      BORDER_HEAVY = {
        tl: '┏', tr: '┓', bl: '┗', br: '┛', h: '━', v: '┃'
      }.freeze

      attr_reader :color_mode

      def initialize(color_mode: nil, env: ENV)
        @color_mode = color_mode || detect_color_mode(env)
      end

      def fg(color_name)
        return '' if @color_mode == :mono

        case @color_mode
        when :truecolor
          rgb = PALETTE[color_name] || PALETTE[:white]
          "\e[38;2;#{rgb[0]};#{rgb[1]};#{rgb[2]}m"
        when :ansi256
          "\e[38;5;#{ANSI256_MAP[color_name] || 231}m"
        else
          "\e[#{ANSI16_MAP[color_name] || 97}m"
        end
      end

      def bg(color_name)
        return '' if @color_mode == :mono

        case @color_mode
        when :truecolor
          rgb = PALETTE[color_name] || PALETTE[:bg]
          "\e[48;2;#{rgb[0]};#{rgb[1]};#{rgb[2]}m"
        when :ansi256
          "\e[48;5;#{ANSI256_MAP[color_name] || 17}m"
        else
          "\e[40m"
        end
      end

      def paint(text, color: nil, background: nil, bold: false, dim: false)
        return text.to_s if @color_mode == :mono

        seq = +''
        seq << BOLD if bold
        seq << DIM if dim
        seq << fg(color) if color
        seq << bg(background) if background
        return text.to_s if seq.empty?

        "#{seq}#{text}#{RESET}"
      end

      def apply_canvas_bg(line)
        return line.to_s if @color_mode == :mono

        base = bg(:bg)
        "#{base}#{line.to_s.gsub(RESET, "#{RESET}#{base}")}"
      end

      def sanitize_display(text)
        out = +''
        text.to_s.gsub(/\s+/, ' ').strip.each_char do |ch|
          cp = ch.ord
          next if cp < 0x20 || cp == 0x7F || combining_mark?(cp)
          next if cp >= 0x1F000 && cp <= 0x1FAFF

          out << (cp >= 0x1D400 && cp <= 0x1D7FF ? normalize_math_alnum(cp) : ch)
        end
        out.gsub(/\s+/, ' ').strip
      end

      def gradient_bar(ratio, width:)
        clamped = [[ratio.to_f, 0.0].max, 1.0].min
        filled = (width * clamped).round
        empty = [width - filled, 0].max
        return "#{'#' * filled}#{'-' * empty}" if @color_mode == :mono

        out = +''
        filled.times do |i|
          pos = filled > 1 ? (i.to_f / (filled - 1)) : 1.0
          out << if @color_mode == :truecolor
                   r = (148 + (107 * pos)).round
                   g = (72 - (10 * pos)).round
                   b = (255 - (85 * pos)).round
                   "\e[38;2;#{r};#{g};#{b}m█"
                 else
                   "#{fg(pos > 0.5 ? :pink : :purple)}█"
                 end
        end
        out << "#{fg(:border_muted)}#{'░' * empty}" if empty.positive?
        out << RESET
      end

      def border(selected: false)
        selected ? BORDER_HEAVY : BORDER_ROUND
      end

      def strip_ansi(text)
        text.to_s.gsub(/\e\[[0-9;?]*[A-Za-z]/, '')
      end

      def char_width(ch)
        cp = ch.ord
        return 0 if cp < 0x20 || cp == 0x7F
        return 0 if combining_mark?(cp)
        return 2 if wide_codepoint?(cp)

        1
      end

      def visible_length(text)
        strip_ansi(text).each_char.sum { |ch| char_width(ch) }
      end

      def fit(text, target_width)
        return '' if target_width <= 0

        clipped = clip_ansi(text.to_s, target_width)
        vis = visible_length(clipped)
        vis < target_width ? "#{clipped}#{' ' * (target_width - vis)}" : clipped
      end

      def truncate(text, max_width, ellipsis: '...')
        str = sanitize_display(text)
        return '' if max_width <= 0
        return str if visible_length(str) <= max_width

        ell_w = visible_length(ellipsis)
        return clip_plain(str, max_width) if max_width <= ell_w

        "#{clip_plain(str, max_width - ell_w)}#{ellipsis}"
      end

      def truncate_chars(text, max_chars, ellipsis: '...')
        str = sanitize_display(text)
        return '' if max_chars <= 0
        return str if str.length <= max_chars

        "#{str[0, max_chars]}#{ellipsis}"
      end

      def wrap_text(text, max_width, max_lines: 3)
        str = sanitize_display(text)
        return [] if str.empty? || max_width <= 0 || max_lines <= 0

        lines = []
        current = +''
        str.split(' ').each do |word|
          if current.empty?
            current = clip_plain(word, max_width)
          elsif visible_length(current) + 1 + visible_length(word) <= max_width
            current = "#{current} #{word}"
          else
            lines << current
            break if lines.size >= max_lines

            current = clip_plain(word, max_width)
          end
        end
        lines << current if !current.empty? && lines.size < max_lines
        if lines.size == max_lines && str.length > lines.join(' ').length
          lines[-1] = truncate(lines[-1], max_width)
        end
        lines
      end

      def clip_ansi(text, max_cols)
        return text if visible_length(text) <= max_cols

        out = +''
        cols = 0
        has_ansi = false
        idx = 0
        len = text.length

        while idx < len
          if text[idx] == "\e"
            m = text.match(/\G\e\[[0-9;?]*[A-Za-z]/, idx)
            if m
              out << m[0]
              has_ansi = true
              idx += m[0].length
              next
            end
          end

          ch = text[idx]
          cw = char_width(ch)
          break if cols + cw > max_cols

          out << ch
          cols += cw
          idx += 1
        end

        out << RESET if has_ansi
        out
      end

      private

      def normalize_math_alnum(cp)
        offset = (cp - 0x1D400) % 52
        offset < 26 ? (65 + offset).chr : (97 + (offset - 26)).chr
      rescue RangeError
        ''
      end

      def clip_plain(str, max_cols)
        out = +''
        cols = 0
        str.each_char do |ch|
          cw = char_width(ch)
          break if cols + cw > max_cols

          out << ch
          cols += cw
        end
        out
      end

      def combining_mark?(cp)
        (cp >= 0x0300 && cp <= 0x036F) ||
          (cp >= 0xFE00 && cp <= 0xFE0F) ||
          cp == 0x200D ||
          (cp >= 0x064B && cp <= 0x065F)
      end

      def wide_codepoint?(cp)
        (cp >= 0x1100 && cp <= 0x115F) ||
          (cp >= 0x2E80 && cp <= 0xA4CF) ||
          (cp >= 0xAC00 && cp <= 0xD7A3) ||
          (cp >= 0xF900 && cp <= 0xFAFF) ||
          (cp >= 0xFE10 && cp <= 0xFE6F) ||
          (cp >= 0xFF00 && cp <= 0xFF60) ||
          (cp >= 0xFFE0 && cp <= 0xFFE6) ||
          (cp >= 0x1F300 && cp <= 0x1FAFF)
      end

      def detect_color_mode(env)
        return :mono if env['NO_COLOR'] && !env['NO_COLOR'].empty?
        return :mono if env['TERM'].to_s == 'dumb'

        colorterm = env['COLORTERM'].to_s.downcase
        return :truecolor if colorterm.include?('truecolor') || colorterm.include?('24bit')
        return :ansi256 if env['TERM'].to_s.include?('256color')

        :truecolor
      end
    end
  end
end
