# frozen_string_literal: true

# Monji024
module PinterestDL
  class ProgressBar
    def initialize(total:, width: 30, out: $stdout)
      @total = total.zero? ? 1 : total
      @width = width
      @out = out
    end

    def update(done)
      ratio = done.to_f / @total
      filled = (@width * ratio).round
      bar = ('#' * filled) + ('-' * (@width - filled))
      @out.print "\r[#{bar}] #{done}/#{@total} (#{(ratio * 100).round}%)"
      @out.print "\n" if done >= @total
      @out.flush
    end
  end
end
