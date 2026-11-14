# frozen_string_literal: true

begin
  require 'io/console'
rescue LoadError
  nil
end

module PinterestDL
  module TUI
    class Terminal
      ENTER_ALT_SCREEN = "\e[?1049h"
      LEAVE_ALT_SCREEN = "\e[?1049l"
      HIDE_CURSOR = "\e[?25l"
      SHOW_CURSOR = "\e[?25h"
      ENABLE_MOUSE = "\e[?1000h\e[?1006h"
      DISABLE_MOUSE = "\e[?1006l\e[?1000l"
      SYNC_START = "\e[?2026h"
      SYNC_END = "\e[?2026l"
      CLEAR_HOME = "\e[2J\e[H"
      CLEAR_EOL = "\e[K"
      KITTY_CLEAR_IMAGES = "\e_Ga=d,d=A,q=2\e\\"
      RESET = "\e[0m"

      DEFAULT_WIDTH = 120
      DEFAULT_HEIGHT = 34

      attr_reader :input, :output, :graphics_protocol

      def initialize(input: $stdin, output: $stdout, env: ENV)
        @input = input
        @output = output
        @env = env
        @active = false
        @graphics_protocol = detect_graphics_protocol(env)
      end

      def kitty_graphics?
        @graphics_protocol == :kitty
      end

      def tty?
        @input.respond_to?(:tty?) && @input.tty? && @output.respond_to?(:tty?) && @output.tty?
      end

      def size
        if @output.respond_to?(:winsize)
          rows, cols = @output.winsize
          return [cols, rows] if cols.to_i.positive? && rows.to_i.positive?
        end
        cols = @env['COLUMNS'].to_i
        rows = @env['LINES'].to_i
        [cols.positive? ? cols : DEFAULT_WIDTH, rows.positive? ? rows : DEFAULT_HEIGHT]
      rescue StandardError
        [DEFAULT_WIDTH, DEFAULT_HEIGHT]
      end

      def with_screen
        enter_screen
        if @input.respond_to?(:raw) && tty?
          @input.raw { yield self }
        else
          yield self
        end
      ensure
        leave_screen
      end

      def enter_screen
        return if @active

        @active = true
        @output.print("#{ENTER_ALT_SCREEN}#{HIDE_CURSOR}#{ENABLE_MOUSE}#{CLEAR_HOME}")
        @output.flush
      end

      def leave_screen
        return unless @active

        @active = false
        clear_gfx = kitty_graphics? ? KITTY_CLEAR_IMAGES : ''
        @output.print("#{clear_gfx}#{DISABLE_MOUSE}#{RESET}#{SHOW_CURSOR}#{LEAVE_ALT_SCREEN}")
        @output.flush
      end

      def clear_screen
        clear_gfx = kitty_graphics? ? KITTY_CLEAR_IMAGES : ''
        @output.print("#{clear_gfx}#{CLEAR_HOME}")
        @output.flush
      end

      def render_frame(frame_string, overlays: [])
        lines = frame_string.split("\n", -1)
        buf = +SYNC_START
        buf << KITTY_CLEAR_IMAGES if kitty_graphics?
        lines.each_with_index do |line, idx|
          buf << "\e[#{idx + 1};1H#{line}#{CLEAR_EOL}#{RESET}"
        end
        buf << "\e[J"
        if @graphics_protocol != :none && overlays && !overlays.empty?
          overlays.each { |ov| buf << ov }
        end
        buf << SYNC_END
        @output.print(buf)
        @output.flush
      end

      def read_key(timeout: 0.08)
        return nil unless select_ready?(timeout)

        ch = read_utf8_char_nonblock
        return nil if ch.nil?

        decode_key(ch)
      end

      def decode_key(first_char)
        case first_char
        when "\x01" then :ctrl_a
        when "\x03" then :ctrl_c
        when "\r", "\n" then :enter
        when "\t" then :tab
        when "\x7f", "\b" then :backspace
        when "\e" then read_escape_sequence
        else first_char
        end
      end

      private

      def detect_graphics_protocol(env)
        forced = env['PINTEREST_DL_GRAPHICS'].to_s.strip.downcase
        return forced.to_sym if %w[kitty iterm2 sixel none].include?(forced)

        term = env['TERM'].to_s.downcase
        prog = env['TERM_PROGRAM'].to_s.downcase
        lc_term = env['LC_TERMINAL'].to_s.downcase

        if !env['KITTY_WINDOW_ID'].to_s.empty? || !env['GHOSTTY_RESOURCES_DIR'].to_s.empty? ||
           term.include?('kitty') || term.include?('ghostty') || %w[wezterm ghostty konsole].include?(prog)
          return :kitty
        end

        if %w[iterm.app tabby hyper warpterminal].include?(prog) || lc_term == 'iterm2'
          return :iterm2
        end

        if !env['WT_SESSION'].to_s.empty? || term.include?('foot') || term.include?('mlterm') ||
           term.include?('contour') || term.include?('sixel')
          return :sixel
        end

        :none
      end

      def select_ready?(timeout)
        return true unless @input.is_a?(IO)

        !IO.select([@input], nil, nil, timeout).nil?
      rescue IOError, Errno::EBADF, Errno::EINTR
        false
      end

      def read_byte_nonblock
        return @input.getbyte unless @input.is_a?(IO)

        chunk = @input.read_nonblock(1)
        chunk&.getbyte(0)
      rescue IO::WaitReadable, IOError, Errno::EINTR
        nil
      end

      def read_char_nonblock
        byte = read_byte_nonblock
        byte&.chr(Encoding::ASCII_8BIT)
      end

      def read_utf8_char_nonblock
        first = read_byte_nonblock
        return nil if first.nil?

        needed = utf8_byte_length(first)
        return first.chr(Encoding::UTF_8) if needed == 1

        bytes = [first]
        (needed - 1).times do
          select_ready?(0.02)
          nxt = read_byte_nonblock
          break if nxt.nil?

          bytes << nxt
        end

        str = bytes.pack('C*').force_encoding(Encoding::UTF_8)
        str.valid_encoding? ? str : nil
      rescue StandardError
        nil
      end

      def utf8_byte_length(first_byte)
        return 1 if first_byte < 0x80
        return 2 if (first_byte & 0xE0) == 0xC0
        return 3 if (first_byte & 0xF0) == 0xE0
        return 4 if (first_byte & 0xF8) == 0xF0

        1
      end

      def read_escape_sequence
        return :escape unless select_ready?(0.02)

        second = read_char_nonblock
        return :escape if second.nil?
        return :escape unless second == '['

        third = read_char_nonblock
        return parse_sgr_mouse if third == '<'

        decode_csi_key(third)
      end

      def decode_csi_key(third)
        case third
        when 'A' then :up
        when 'B' then :down
        when 'C' then :right
        when 'D' then :left
        when 'Z' then :shift_tab
        when '3'
          read_char_nonblock
          :delete
        when '5'
          read_char_nonblock
          :page_up
        when '6'
          read_char_nonblock
          :page_down
        else
          :escape
        end
      end

      def parse_sgr_mouse
        buf = +''
        24.times do
          ch = read_char_nonblock
          break if ch.nil?

          return build_mouse_event(buf, pressed: ch == 'M') if %w[M m].include?(ch)

          buf << ch
        end
        :escape
      end

      def build_mouse_event(payload, pressed:)
        parts = payload.split(';')
        return :escape unless parts.size == 3

        code = parts[0].to_i
        col = parts[1].to_i
        row = parts[2].to_i
        button = decode_mouse_button(code)
        return :escape unless button

        { type: :mouse, button: button, x: col, y: row, pressed: pressed }
      end

      def decode_mouse_button(code)
        return :wheel_up if code == 64
        return :wheel_down if code == 65

        case code & 0b11
        when 0 then :left
        when 1 then :middle
        when 2 then :right
        end
      end
    end
  end
end
