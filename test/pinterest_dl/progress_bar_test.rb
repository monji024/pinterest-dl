# frozen_string_literal: true

require_relative '../test_helper'
require 'stringio'

class ProgressBarTest < Minitest::Test
  def test_renders_progress_bar_to_output
    out = StringIO.new
    bar = PinterestDL::ProgressBar.new(total: 4, width: 10, out: out)

    bar.update(2)
    assert_includes out.string, '[#####-----] 2/4 (50%)'

    bar.update(4)
    assert_includes out.string, "[##########] 4/4 (100%)
"
  end

  def test_handles_zero_total_without_zero_division
    out = StringIO.new
    bar = PinterestDL::ProgressBar.new(total: 0, width: 10, out: out)
    bar.update(1)
    assert_includes out.string, '[##########] 1/1'
  end
end
