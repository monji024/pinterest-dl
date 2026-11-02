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
end
