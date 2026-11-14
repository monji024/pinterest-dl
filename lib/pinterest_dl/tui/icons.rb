# frozen_string_literal: true

module PinterestDL
  module TUI
    class Icons
      def initialize(theme:)
        @theme = theme
      end

      def wifi(status)
        case status
        when :online
          "#{@theme.paint('ᯤ', color: :green, bold: true)} #{@theme.paint('Online', color: :green, bold: true)}"
        when :proxy
          "#{@theme.paint('ᯤ', color: :cyan, bold: true)} #{@theme.paint('Proxy', color: :cyan, bold: true)}"
        when :rate_limited
          "#{@theme.paint('ᯤ', color: :yellow, bold: true)} #{@theme.paint('429', color: :yellow, bold: true)}"
        when :checking
          "#{@theme.paint('ᯤ', color: :purple, bold: true)} #{@theme.paint('Sync', color: :purple, bold: true)}"
        else
          "#{@theme.paint('ᯤ', color: :red, bold: true)} #{@theme.paint('Offline', color: :red, bold: true)}"
        end
      end

      def signal_bars(active: true)
        return '╷││┃' if @theme.color_mode == :mono

        if active
          "#{@theme.paint('╷', color: :purple)}" \
          "#{@theme.paint('│', color: :cyan)}" \
          "#{@theme.paint('│', color: :green)}" \
          "#{@theme.paint('┃', color: :green, bold: true)}"
        else
          "#{@theme.paint('╷', color: :border_dim)}" \
          "#{@theme.paint('│', color: :purple)}" \
          "#{@theme.paint('│', color: :purple, bold: true)}" \
          "#{@theme.paint('┃', color: :cyan)}"
        end
      end

      def search
        @theme.paint('⌕', color: :pink, bold: true)
      end

      def image
        @theme.paint('⊞', color: :purple, bold: true)
      end

      def video
        @theme.paint('▸', color: :pink, bold: true)
      end

      def quality_glyph
        @theme.paint('★', color: :yellow, bold: true)
      end

      def size_glyph
        @theme.paint('⊞', color: :cyan, bold: true)
      end

      def format_glyph
        @theme.paint('◈', color: :purple, bold: true)
      end

      def creator_glyph
        @theme.paint('◉', color: :pink, bold: true)
      end

      def clock_glyph
        @theme.paint('◉', color: :pink, bold: true)
      end

      def download
        @theme.paint('↓', color: :pink, bold: true)
      end

      def pause
        @theme.paint('║', color: :purple, bold: true)
      end

      def resume
        @theme.paint('▸', color: :green, bold: true)
      end

      def trash
        @theme.paint('✕', color: :red, bold: true)
      end

      def check
        @theme.paint('✓', color: :green, bold: true)
      end

      def placeholder_canvas(width:, height:, label:, video: false)
        w = [width.to_i, 4].max
        h = [height.to_i, 2].max
        mid = h / 2
        Array.new(h) do |row|
          if video && row.zero? && w >= 4
            badge = @theme.paint(' ▸ ', color: :white, background: :pink, bold: true)
            pad = [w - 3, 0].max
            @theme.fit("#{' ' * pad}#{badge}", w)
          elsif row == mid
            txt = @theme.truncate(label, [w - 2, 1].max)
            pad = [(w - @theme.visible_length(txt)) / 2, 0].max
            @theme.fit((' ' * pad) + @theme.paint(txt, color: :dim_text), w)
          else
            @theme.fit('', w)
          end
        end
      end
    end
  end
end
