# frozen_string_literal: true

begin
  require 'io/console'
rescue LoadError
  nil
end

module PinterestDL
  class ProgressBar
    UNITS = %w[B KB MB GB TB].freeze
    MAX_LABEL_LENGTH = 18

    attr_reader :total, :width, :out, :enabled, :label, :media_type

    def initialize(total: 0, width: 24, out: $stdout, enabled: true, label: nil, media_type: nil, byte_mode: false)
      @byte_mode = byte_mode
      @known_total = total.to_i.positive? && !byte_mode
      @total = total.to_i <= 0 ? 1 : total.to_i
      @width = width
      @out = out
      @enabled = enabled
      @label = label
      @media_type = media_type
      @started_at = monotonic_now
      @last_received = 0
      @last_total_bytes = nil
      @last_line_len = 0
      @finished_newline = false
      @mutex = Mutex.new
    end

    def start(total_bytes: nil, label: nil, media_type: nil)
      return unless @enabled

      @mutex.synchronize do
        @started_at = monotonic_now
        @finished_newline = false
        @last_line_len = 0
        @label = label if label
        @media_type = media_type if media_type
        @last_total_bytes = total_bytes if total_bytes && total_bytes.positive?
        if @byte_mode && @last_total_bytes
          render_byte_progress(0, @last_total_bytes, speed: 0.0, label: @label, media_type: @media_type)
        end
      end
    end

    def update(done, bytes_received: nil, total_bytes: nil, speed: nil, label: nil, media_type: nil)
      return unless @enabled

      @mutex.synchronize do
        eff_label = label || @label
        eff_type = media_type || @media_type
        if @byte_mode || (bytes_received && total_bytes)
          rec = bytes_received || done.to_i
          tot = total_bytes || @last_total_bytes || (@known_total ? @total : nil)
          @last_received = rec
          @last_total_bytes = tot if tot && tot.positive?
          render_byte_progress(rec, tot, speed: speed, label: eff_label, media_type: eff_type)
        else
          render_item_progress(done, label: eff_label, media_type: eff_type)
        end
      end
    end

    def finish(final_bytes: nil)
      return unless @enabled

      @mutex.synchronize do
        if @byte_mode && !@finished_newline
          rec = final_bytes || @last_received
          tot = @last_total_bytes || (rec.positive? ? rec : nil)
          render_byte_progress(rec, tot, speed: nil, label: @label, media_type: @media_type, force_complete: true)
        end
        unless @finished_newline
          @out.print "\n"
          @out.flush
          @finished_newline = true
        end
      end
    end

    def self.format_bytes(bytes)
      val = bytes.to_f
      return '0 B' if val <= 0

      idx = 0
      while val >= 1024.0 && idx < UNITS.size - 1
        val /= 1024.0
        idx += 1
      end
      idx.zero? ? "#{val.to_i} #{UNITS[idx]}" : format('%<val>.1f %<unit>s', val: val, unit: UNITS[idx])
    end

    def self.format_eta(seconds)
      return '--:--' if seconds.nil? || seconds.infinite? || seconds.nan? || seconds.negative?

      sec = seconds.round
      return '99:59+' if sec > 359_999

      hours = sec / 3600
      mins = (sec % 3600) / 60
      rem = sec % 60
      if hours.positive?
        format('%<h>02d:%<m>02d:%<s>02d', h: hours, m: mins, s: rem)
      else
        format('%<m>02d:%<s>02d', m: mins, s: rem)
      end
    end

    def self.truncate_label(text, max_len: MAX_LABEL_LENGTH)
      str = text.to_s
      return str if str.length <= max_len || max_len < 6

      ext = File.extname(str)
      if !ext.empty? && ext.length < max_len - 4
        keep = max_len - ext.length - 2
        head = [keep - 3, 3].max
        tail = [keep - head, 1].max
        stem = File.basename(str, ext)
        "#{stem[0, head]}..#{stem[-tail, tail]}#{ext}"
      else
        "#{str[0, max_len - 2]}.."
      end
    end

    private

    def render_item_progress(done, label: nil, media_type: nil)
      ratio = [[done.to_f / @total, 0.0].max, 1.0].min
      filled = (@width * ratio).round
      bar = ('#' * filled) + ('-' * (@width - filled))
      pct = ((done.to_f / @total) * 100).round
      badge = media_type ? "[#{media_type.to_s.upcase}] " : ''
      short_label = label && !label.empty? ? " #{self.class.truncate_label(label)}" : ''
      line = "#{badge}[#{bar}] #{done}/#{@total} (#{pct}%)#{short_label}"
      write_in_place(line, newline: done >= @total)
    end

    def render_byte_progress(received, total_bytes, speed: nil, label: nil, media_type: nil, force_complete: false)
      return if @finished_newline && !force_complete

      elapsed = [monotonic_now - @started_at, 0.001].max
      current_speed = speed || (received.to_f / elapsed)
      speed_str = "#{self.class.format_bytes(current_speed)}/s"
      badge = media_type ? "[#{media_type.to_s.upcase}] " : ''
      short_label = label && !label.empty? ? "#{self.class.truncate_label(label)} " : ''

      if total_bytes && total_bytes.positive?
        ratio = force_complete ? 1.0 : [[received.to_f / total_bytes, 0.0].max, 1.0].min
        pct = (ratio * 100).round
        remaining = [total_bytes - received, 0].max
        eta_sec = current_speed.positive? ? (remaining.to_f / current_speed) : nil
        eta_str = ratio >= 1.0 ? '00:00' : self.class.format_eta(eta_sec)
        size_str = "#{self.class.format_bytes(received)}/#{self.class.format_bytes(total_bytes)}"
        tail = " #{pct}% #{size_str} #{speed_str} ETA #{eta_str}"
        eff_width = adaptive_bar_width(badge.length + short_label.length + tail.length + 2)
        filled = (eff_width * ratio).round
        bar = ('#' * filled) + ('-' * (eff_width - filled))
        line = "#{badge}#{short_label}[#{bar}]#{tail}"
        write_in_place(line, newline: received >= total_bytes || force_complete)
      else
        size_str = self.class.format_bytes(received)
        line = "#{badge}#{short_label}#{size_str} #{speed_str}"
        write_in_place(line, newline: force_complete)
      end
    end

    def adaptive_bar_width(non_bar_len)
      cols = detect_terminal_columns
      return @width unless cols && cols.positive?

      available = cols - non_bar_len - 1
      [[available, 6].max, @width].min
    end

    def detect_terminal_columns
      if @out.respond_to?(:winsize)
        cols = @out.winsize[1].to_i
        return cols if cols.positive?
      end
      env_cols = ENV['COLUMNS'].to_i
      return env_cols if env_cols.positive?

      nil
    rescue StandardError
      nil
    end

    def write_in_place(line, newline: false)
      cols = detect_terminal_columns
      clipped = cols && cols > 10 && line.length >= cols ? line[0, cols - 1] : line
      pad_count = [@last_line_len - clipped.length, 0].max
      padded = pad_count.positive? ? "#{clipped}#{' ' * pad_count}" : clipped
      @last_line_len = clipped.length

      @out.print "\r#{padded}"
      if newline
        @out.print "\n"
        @finished_newline = true
        @last_line_len = 0
      end
      @out.flush
    end

    def monotonic_now
      Process.clock_gettime(Process::CLOCK_MONOTONIC)
    end
  end
end
