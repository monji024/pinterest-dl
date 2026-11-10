# frozen_string_literal: true

require_relative '../test_helper'
require 'stringio'
require 'tmpdir'

class CLITest < Minitest::Test
  def test_prints_version_and_exits_zero
    out = StringIO.new
    err = StringIO.new
    code = PinterestDL::CLI.run(['--version'], out: out, err: err)

    assert_equal 0, code
    assert_equal PinterestDL::VERSION, out.string.strip
  end

  def test_prints_help_and_exits_zero
    out = StringIO.new
    err = StringIO.new
    code = PinterestDL::CLI.run(['--help'], out: out, err: err)

    assert_equal 0, code
    assert_includes out.string, 'Usage:'
    assert_includes out.string, '--no-progress'
    assert_includes out.string, '--format'
  end

  def test_unknown_command_prints_helpful_error_and_exits_one
    out = StringIO.new
    err = StringIO.new
    code = PinterestDL::CLI.run(%w[unknown https://www.pinterest.com/pin/1/], out: out, err: err)

    assert_equal 1, code
    assert_includes err.string, "Unknown command 'unknown'"
    assert_includes err.string, 'Hint:'
  end

  def test_json_format_outputs_structured_error_on_invalid_url
    out = StringIO.new
    err = StringIO.new
    code = PinterestDL::CLI.run(%w[--json image https://example.com/bad], out: out, err: err)

    assert_equal 1, code
    parsed = JSON.parse(err.string)
    assert_includes parsed['error'], 'Not a Pinterest pin URL'
    refute_nil parsed['hint']
  end
end
