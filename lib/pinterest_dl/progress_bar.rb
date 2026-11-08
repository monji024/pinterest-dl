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

# step-0
