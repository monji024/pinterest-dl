# frozen_string_literal: true

module PinterestDL
  class ProgressBar
    def initialize(total:, width: 30, out: $stdout)
      @total = total.to_i <= 0 ? 1 : total.to_i
      @width = width
      @out = out
    end

    def update(done)
      ratio = [[done.to_f / @total, 0.0].max, 1.0].min
      filled = (@width * ratio).round
      bar = ('#' * filled) + ('-' * (@width - filled))
      @out.print "\r[#{bar}] #{done}/#{@total} (#{((done.to_f / @total) * 100).round}%)"
      @out.print "\n" if done >= @total
      @out.flush
    end
  end
end
