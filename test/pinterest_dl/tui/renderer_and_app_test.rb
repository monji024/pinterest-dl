# frozen_string_literal: true

require_relative '../../test_helper'
require 'stringio'
require 'tmpdir'
require 'pinterest_dl/tui'

class TUIRendererAndAppTest < Minitest::Test
  class FakeSession
    attr_reader :search_calls, :board_calls, :media_calls, :download_calls

    def initialize(pins: [], search_error: nil)
      @pins = pins
      @search_error = search_error
      @search_calls = []
      @board_calls = []
      @media_calls = []
      @download_calls = []
    end

    def config
      @config ||= PinterestDL::Configuration.new
    end

    def search(query, limit: 25, type: :all)
      @search_calls << { query: query, limit: limit, type: type }
      raise @search_error if @search_error

      @pins
    end

    def board(board_url, limit: 50, type: :all)
      @board_calls << { board_url: board_url, limit: limit, type: type }
      raise @search_error if @search_error

      @pins
    end

    def get_media(pin_url, quality: :originals)
      @media_calls << { pin_url: pin_url, quality: quality }
      { image_url: 'https://i.pinimg.com/originals/single.jpg', video_url: nil }
    end

    def download(url, path:, **_options, &progress)
      @download_calls << { url: url, path: path }
      File.binwrite(path, 'OK')
      progress&.call({ received: 2, total: 2, speed: 20.0, url: url })
      path
    end
  end

  def sample_pins
    [
      {
        id: '111',
        pin_url: 'https://www.pinterest.com/pin/111/',
        title: 'Sakura Night Wallpaper',
        description: 'Full anime aesthetic wallpaper description for preview panel',
        creator: 'sakura_art',
        image_url: 'https://i.pinimg.com/originals/11/11/sakura.jpg',
        video_url: nil
      },
      {
        id: '222',
        pin_url: 'https://www.pinterest.com/pin/222/',
        title: 'Neon City Rain',
        description: 'Cyberpunk rain street loop video',
        creator: 'cyber_loop',
        image_url: 'https://i.pinimg.com/originals/22/22/neon.jpg',
        video_url: 'https://v1.pinimg.com/videos/mc/720p/neon.mp4'
      }
    ]
  end

  def test_renderer_maintains_exact_alignment_renders_limit_box_and_clean_categories
    theme = PinterestDL::TUI::Theme.new(color_mode: :mono)
    icons = PinterestDL::TUI::Icons.new(theme: theme)
    preview = PinterestDL::TUI::Preview.new(theme: theme, icons: icons, external_tools: false)
    fixed_clock = -> { Time.new(2026, 11, 22, 21, 42, 0) }
    renderer = PinterestDL::TUI::Renderer.new(theme: theme, icons: icons, preview: preview, clock: fixed_clock)
    state = PinterestDL::TUI::State.new
    state.search_query = 'anime wallpaper'
    state.replace_pins(sample_pins)

    [[40, 12], [60, 20], [80, 24], [120, 34], [160, 44]].each do |cols, rows|
      frame = renderer.render(state, queue_items: [], width: cols, height: rows)
      lines = frame.split("\n", -1)
      assert_equal rows, lines.size
      assert(lines.all? { |l| theme.visible_length(l) == cols })
    end

    frame = renderer.render(state, queue_items: [], width: 120, height: 34)
    assert_includes frame, 'Limit: 25'
    assert_includes frame, ' All '
    assert_includes frame, ' Images '
    refute_includes frame, '★ All'
    assert_includes frame, 'Sakura ...'
    assert_includes frame, 'Sakura Night Wallpaper'
    assert_includes frame, '◂ originals ▸'
    assert_includes frame, 'Image • JPG'
    assert(renderer.hit_regions.any? { |r| r[:action] == :limit_box })
    assert(renderer.hit_regions.any? { |r| r[:action] == :quality_next })
  end

  def test_app_supports_custom_search_limit_quality_clicks_queue_list_and_batch_download
    Dir.mktmpdir do |dir|
      session = FakeSession.new(pins: sample_pins)
      term = PinterestDL::TUI::Terminal.new(input: StringIO.new(''), output: StringIO.new, env: {})
      app = PinterestDL::TUI::App.new(
        session: session,
        terminal: term,
        theme: PinterestDL::TUI::Theme.new(color_mode: :mono),
        output_dir: dir,
        external_preview: false
      )

      assert_equal 25, app.state.search_limit
      app.perform_search('anime wallpaper', async: false)
      assert_equal 25, session.search_calls.last[:limit]

      app.apply_search_limit(75, async: false)
      assert_equal 75, app.state.search_limit
      assert_equal 75, session.search_calls.last[:limit]

      app.render_frame
      q_next = app.renderer.hit_regions.find { |r| r[:action] == :quality_next }
      refute_nil q_next
      app.handle_key({ type: :mouse, button: :left, x: q_next[:x1], y: q_next[:y1], pressed: true })
      assert_equal :'1200x', app.state.image_quality

      card_regions = app.renderer.hit_regions.select { |r| r[:action] == :card }
      assert_equal 2, card_regions.size
      second_card = card_regions[1]
      app.handle_key({ type: :mouse, button: :left, x: second_card[:x1] + 2, y: second_card[:y1] + 2, pressed: true })
      assert_equal '222', app.state.selected_pin[:id]

      app.handle_key('s')
      assert_equal 2, app.state.selected_batch_count

      app.handle_key('b')
      deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + 2.0
      sleep(0.01) until app.queue.completed_count == 2 || Process.clock_gettime(Process::CLOCK_MONOTONIC) > deadline
      assert_equal 2, app.queue.completed_count

      queue_frame = app.render_frame
      assert_includes queue_frame, 'Download Queue (2)'
      assert(app.renderer.hit_regions.any? { |r| r[:action] == :queue_select })
      assert_equal :quit, app.handle_key('q')
    ensure
      app&.shutdown
    end
  end

  def test_cli_tui_subcommand_launches_without_extra_flags
    called_with = nil
    PinterestDL::TUI.stub(:start, ->(**kwargs) { called_with = kwargs }) do
      out = StringIO.new
      err = StringIO.new
      code = PinterestDL::CLI.run(['tui'], out: out, err: err)
      assert_equal 0, code
    end

    refute_nil called_with
    assert_equal './downloads', called_with[:output_dir]
    assert_kind_of PinterestDL::Session, called_with[:session]
  end
end
