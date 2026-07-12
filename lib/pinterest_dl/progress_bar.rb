# frozen_string_literal: true

module PinterestDL
  class ProgressBar
    def initialize(total:, width: 30, out: $stdout)
      @total = total.to_i <= 0 ? 1 : total.to_i
      @width = width
      @out = out
    end


# step-0
