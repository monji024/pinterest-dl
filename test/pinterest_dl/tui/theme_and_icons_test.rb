# frozen_string_literal: true

require_relative '../../test_helper'
require 'pinterest_dl/tui'

class TUIThemeAndIconsTest < Minitest::Test
  def test_detects_color_modes_sanitizes_unicode_and_truncates_card_titles
    truecolor = PinterestDL::TUI::Theme.new(env: { 'COLORTERM' => 'truecolor' })
    ansi256 = PinterestDL::TUI::Theme.new(env: { 'TERM' => 'xterm-256color' })
    mono = PinterestDL::TUI::Theme.new(env: { 'NO_COLOR' => '1', 'COLORTERM' => 'truecolor' })

    assert_equal :truecolor, truecolor.color_mode
    assert_equal :ansi256, ansi256.color_mode
    assert_equal :mono, mono.color_mode

    styled = truecolor.paint('Sakura Night Wallpaper', color: :pink, bold: true)
    fitted = truecolor.fit(styled, 10)
    assert_equal 10, truecolor.visible_length(fitted)
    assert_equal 'Sakura Nig', truecolor.strip_ansi(fitted)

    assert_equal 'Sakura ...', truecolor.truncate_chars('Sakura Night Wallpaper', 7)
    assert_equal 'Short', truecolor.truncate_chars('Short', 7)
    assert_equal 'clean text', truecolor.sanitize_display("clean\u{1F525} text")

    wrapped = truecolor.wrap_text('Anime aesthetic wallpaper with pink cherry blossoms at night', 18, max_lines: 3)
    assert_operator wrapped.size, :<=, 3
    assert(wrapped.all? { |l| truecolor.visible_length(l) <= 18 })

    bar = truecolor.gradient_bar(0.5, width: 10)
    assert_equal 10, truecolor.visible_length(bar)
  end

  def test_icons_render_wifi_media_glyphs_and_clean_placeholder
    theme = PinterestDL::TUI::Theme.new(color_mode: :mono)
    icons = PinterestDL::TUI::Icons.new(theme: theme)

    assert_includes icons.wifi(:online), 'ᯤ'
    assert_includes icons.wifi(:online), 'Online'
    assert_includes icons.wifi(:proxy), 'Proxy'
    assert_includes icons.wifi(:rate_limited), '429'
    assert_includes icons.wifi(:offline), 'Offline'
    assert_equal '⊞', icons.image
    assert_equal '▸', icons.video

    canvas = icons.placeholder_canvas(width: 14, height: 4, label: 'Loading...', video: true)
    assert_equal 4, canvas.size
    assert(canvas.all? { |row| theme.visible_length(row) == 14 })
    assert_includes canvas.first, '▸'
    assert_includes canvas.join("\n"), 'Loading...'
  end
end
