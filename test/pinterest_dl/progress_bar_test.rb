# frozen_string_literal: true

require_relative '../test_helper'
require 'stringio'
require 'tmpdir'

class ProgressBarTest < Minitest::Test
  def test_renders_progress_bar_to_output
    out = StringIO.new
    bar = PinterestDL::ProgressBar.new(total: 4, width: 10, out: out)

    bar.update(2)
    assert_includes out.string, '[#####-----] 2/4 (50%)'

    bar.update(4)
    assert_includes out.string, "[##########] 4/4 (100%)\n"
  end

  def test_handles_zero_total_without_zero_division
    out = StringIO.new
    bar = PinterestDL::ProgressBar.new(total: 0, width: 10, out: out)
    bar.update(1)
    assert_includes out.string, '[##########] 1/1'
  end

  def test_clamps_progress_when_done_exceeds_total
    out = StringIO.new
    bar = PinterestDL::ProgressBar.new(total: 2, width: 10, out: out)
    bar.update(5)
    assert_includes out.string, '[##########] 5/2'
  end

  def test_renders_byte_mode_with_percentage_size_speed_and_eta
    out = StringIO.new
    bar = PinterestDL::ProgressBar.new(
      total: 0,
      width: 10,
      out: out,
      label: 'clip.mp4',
      media_type: :video,
      byte_mode: true
    )

    bar.start(total_bytes: 1024 * 1024)
    bar.update(512 * 1024, bytes_received: 512 * 1024, total_bytes: 1024 * 1024, speed: 512 * 1024)
    bar.finish(final_bytes: 1024 * 1024)

    assert_includes out.string, '[VIDEO] clip.mp4 [#####-----] 50% 512.0 KB/1.0 MB 512.0 KB/s ETA 00:01'
    assert_includes out.string, '[VIDEO] clip.mp4 [##########] 100% 1.0 MB/1.0 MB'
  end
end
