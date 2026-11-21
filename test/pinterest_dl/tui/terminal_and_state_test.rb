# frozen_string_literal: true

require_relative '../../test_helper'
require 'stringio'
require 'pinterest_dl/tui'

class TUITerminalAndStateTest < Minitest::Test
  def test_terminal_decodes_keys_mouse_events_and_explicit_row_render
    input = StringIO.new("\e[A\e[B\e[C\e[D\e[Z\t\r\x7f\x01\x03\e[<0;15;8M\e[<64;10;5M\e[<2;20;9M")
    output = StringIO.new
    term = PinterestDL::TUI::Terminal.new(input: input, output: output)

    refute term.tty?
    assert_equal :up, term.read_key
    assert_equal :down, term.read_key
    assert_equal :right, term.read_key
    assert_equal :left, term.read_key
    assert_equal :shift_tab, term.read_key
    assert_equal :tab, term.read_key
    assert_equal :enter, term.read_key
    assert_equal :backspace, term.read_key
    assert_equal :ctrl_a, term.read_key
    assert_equal :ctrl_c, term.read_key

    click = term.read_key
    assert_equal({ type: :mouse, button: :left, x: 15, y: 8, pressed: true }, click)
    wheel = term.read_key
    assert_equal({ type: :mouse, button: :wheel_up, x: 10, y: 5, pressed: true }, wheel)
    rclick = term.read_key
    assert_equal({ type: :mouse, button: :right, x: 20, y: 9, pressed: true }, rclick)

    term.with_screen { term.render_frame("LINE1\nLINE2") }
    assert_includes output.string, PinterestDL::TUI::Terminal::ENTER_ALT_SCREEN
    assert_includes output.string, PinterestDL::TUI::Terminal::ENABLE_MOUSE
    assert_includes output.string, "\e[1;1HLINE1"
    assert_includes output.string, "\e[2;1HLINE2"
    assert_includes output.string, PinterestDL::TUI::Terminal::DISABLE_MOUSE
    assert_includes output.string, PinterestDL::TUI::Terminal::LEAVE_ALT_SCREEN
  end

  def test_state_filters_media_navigates_grid_and_manages_batch_selection
    state = PinterestDL::TUI::State.new
    state.grid_columns = 2
    pins = [
      { id: '1', title: 'Sakura Night', image_url: 'https://i.pinimg.com/originals/1.jpg', video_url: nil },
      { id: '2', title: 'Neon City', image_url: 'https://i.pinimg.com/originals/2.jpg',
        video_url: 'https://v1.pinimg.com/videos/mc/720p/2.mp4' },
      { id: '3', title: 'Torii Gate', image_url: 'https://i.pinimg.com/originals/3.jpg', video_url: nil }
    ]
    state.replace_pins(pins)

    assert_equal 3, state.pins.size
    assert state.toggle_pin_selection
    assert_equal 1, state.selected_batch_count
    state.toggle_select_all_visible!
    assert_equal 3, state.selected_batch_count
    state.toggle_select_all_visible!
    assert_equal 0, state.selected_batch_count

    state.select_category(1)
    assert_equal(:images, state.active_category[:key])
    assert_equal(%w[1 3], state.pins.map { |p| p[:id] })

    state.select_category(2)
    assert_equal(:videos, state.active_category[:key])
    assert_equal(['2'], state.pins.map { |p| p[:id] })

    state.cycle_quality!
    assert_equal :'1080p', state.video_quality

    state.select_category(0)
    assert_equal 3, state.pins.size
    state.move_gallery(:down)
    assert_equal '3', state.selected_pin[:id]
    state.move_gallery(:up)
    assert_equal '1', state.selected_pin[:id]
  end

  def test_terminal_detects_graphics_protocols
    kitty = PinterestDL::TUI::Terminal.new(input: StringIO.new, output: StringIO.new, env: { 'KITTY_WINDOW_ID' => '1' })
    iterm = PinterestDL::TUI::Terminal.new(input: StringIO.new, output: StringIO.new, env: { 'TERM_PROGRAM' => 'iTerm.app' })
    sixel = PinterestDL::TUI::Terminal.new(input: StringIO.new, output: StringIO.new, env: { 'WT_SESSION' => 'abc' })
    plain = PinterestDL::TUI::Terminal.new(input: StringIO.new, output: StringIO.new, env: { 'TERM' => 'xterm-256color' })

    assert_equal :kitty, kitty.graphics_protocol
    assert_equal :iterm2, iterm.graphics_protocol
    assert_equal :sixel, sixel.graphics_protocol
    assert_equal :none, plain.graphics_protocol
  end

  def test_terminal_reads_persian_and_multibyte_utf8_without_crashing
    input = StringIO.new('سلام'.b)
    term = PinterestDL::TUI::Terminal.new(input: input, output: StringIO.new)

    chars = Array.new(4) { term.read_key }
    assert_equal %w[س ل ا م], chars
    assert(chars.all?(&:valid_encoding?))
  end
end
