# frozen_string_literal: true

require_relative '../session'
require_relative 'theme'
require_relative 'icons'
require_relative 'terminal'
require_relative 'preview'
require_relative 'download_queue'
require_relative 'state'
require_relative 'renderer'

module PinterestDL
  module TUI
    class App
      attr_reader :state, :queue, :terminal, :renderer, :preview

      def initialize(session: nil, terminal: nil, theme: nil, output_dir: './downloads',
                     external_preview: true, search_limit: State::DEFAULT_SEARCH_LIMIT)
        @session = session || TUI.build_auto_session
        @terminal = terminal || Terminal.new
        @theme = theme || Theme.new
        @icons = Icons.new(theme: @theme)
        @mutex = Mutex.new
        @dirty = true
        @resized = false
        @running = false
        @bg_threads = []
        @preview = Preview.new(
          theme: @theme,
          icons: @icons,
          session: @session,
          external_tools: external_preview,
          graphics_protocol: @terminal.graphics_protocol,
          on_ready: -> { mark_dirty }
        )
        @state = State.new(
          output_dir: output_dir,
          proxy_enabled: !@session.config.proxy.to_s.empty?,
          search_limit: search_limit
        )
        @renderer = Renderer.new(theme: @theme, icons: @icons, preview: @preview)
        @queue = DownloadQueue.new(session: @session, output_dir: output_dir, on_update: -> { mark_dirty })
      end

      def run
        @running = true
        prev_winch = install_resize_handler
        @terminal.with_screen do
          render_if_dirty
          event_loop
        end
      ensure
        restore_resize_handler(prev_winch)
        shutdown
      end

      def handle_key(key)
        return :quit if key == :ctrl_c
        return handle_mouse(key) if key.is_a?(Hash) && key[:type] == :mouse

        @mutex.synchronize { @state.status_message = nil }
        if %i[search add_url set_limit].include?(@state.mode)
          handle_input_key(key)
        elsif @state.mode == :help
          handle_help_key(key)
        else
          handle_normal_key(key)
        end
      end

      def handle_mouse(event)
        return :continue unless event[:pressed]

        case event[:button]
        when :wheel_up
          @mutex.synchronize { @state.move_gallery(:up) }
          return :continue
        when :wheel_down
          @mutex.synchronize { @state.move_gallery(:down) }
          return :continue
        end

        region = @renderer.region_at(event[:x], event[:y])
        return :continue unless region

        dispatch_mouse_region(region, event[:button])
        :continue
      end

      def render_frame
        width, height = @terminal.size
        items = @queue.items
        speed = @queue.active_speed
        @mutex.synchronize do
          @renderer.render(@state, queue_items: items, width: width, height: height, active_speed: speed)
        end
      end

      def perform_search(query, async: true)
        clean = query.to_s.strip
        return if clean.empty?

        @mutex.synchronize do
          @state.search_query = clean
          @state.loading = true
          @state.error_banner = nil
          @state.status_message = nil
          @state.network_status = :checking
          @dirty = true
        end

        work = proc { execute_search_query(clean) }
        async ? spawn_background(&work) : work.call
      end

      def perform_add_url(url, async: true)
        clean = url.to_s.strip
        return if clean.empty?

        @mutex.synchronize do
          @state.loading = true
          @state.error_banner = nil
          @state.status_message = nil
          @state.network_status = :checking
          @dirty = true
        end

        work = proc { execute_url_load(clean) }
        async ? spawn_background(&work) : work.call
      end

      def apply_search_limit(value, async: true)
        new_limit, active_query = @mutex.synchronize do
          lim = @state.update_search_limit(value)
          @state.status_message = "Search limit set to #{lim}"
          [lim, @state.search_query.dup]
        end
        perform_search(active_query, async: async) unless active_query.empty?
        new_limit
      end

      def enqueue_batch_download
        pins, img_q, vid_q, out_dir = @mutex.synchronize do
          selected = @state.selected_batch_pins
          targets = selected.empty? ? @state.pins.dup : selected
          [targets, @state.image_quality, @state.video_quality, @state.output_dir]
        end
        return [] if pins.empty?

        queued = @queue.enqueue_batch(pins, quality: img_q, video_quality: vid_q, output_dir: out_dir)
        @mutex.synchronize do
          @state.clear_selection!
          @state.queue_selected_index = [@queue.items.size - 1, 0].max
          @state.error_banner = nil
          @state.status_message = "Added #{queued.size} item(s) to Download Queue -> #{out_dir}"
        end
        queued
      rescue StandardError => e
        @mutex.synchronize { @state.error_banner = e.message }
        []
      end

      def shutdown
        @running = false
        @preview.shutdown
        @queue.shutdown
        @bg_threads.each { |t| t.join(0.5) }
      end

      private

      def event_loop
        last_clock_min = Time.now.min
        while @running
          if @resized
            @resized = false
            @preview.clear_ueberzug
            @preview.clear_cache
            @terminal.clear_screen
            mark_dirty
          end

          if @queue.prune_completed
            @mutex.synchronize do
              @state.queue_selected_index = [[@state.queue_selected_index, @queue.items.size - 1].min, 0].max
            end
            mark_dirty
          end

          key = @terminal.read_key(timeout: 0.08)
          if key
            action = handle_key(key)
            break if action == :quit

            mark_dirty
          else
            now_min = Time.now.min
            if now_min != last_clock_min || @queue.active_count.positive?
              last_clock_min = now_min
              mark_dirty
            end
          end
          render_if_dirty
        end
      end

      def dispatch_mouse_region(region, button)
        case region[:action]
        when :search_box
          open_prompt(:search, @state.search_query)
        when :limit_box
          open_prompt(:set_limit, @state.search_limit.to_s)
        when :search_submit
          %i[search add_url set_limit].include?(@state.mode) ? submit_input_buffer : open_prompt(:search, @state.search_query)
        when :category
          @mutex.synchronize { @state.mode = :normal }
          activate_category(region[:value])
        when :card_select
          @mutex.synchronize do
            @state.mode = :normal
            @state.selected_index = region[:value]
            @state.toggle_pin_selection
          end
        when :card
          @mutex.synchronize do
            @state.mode = :normal
            @state.selected_index = region[:value]
            @state.toggle_pin_selection if button == :right
          end
        when :preview_prev
          @mutex.synchronize { @state.move_gallery(:left) }
        when :preview_next
          @mutex.synchronize { @state.move_gallery(:right) }
        when :quality_prev
          @mutex.synchronize { @state.cycle_quality!(-1) }
        when :quality_next
          @mutex.synchronize { @state.cycle_quality!(1) }
        when :download_current
          enqueue_selected_pin
        when :download_batch
          enqueue_batch_download
        when :queue_select
          @mutex.synchronize { @state.queue_selected_index = region[:value] }
        when :queue_pause
          toggle_queue_pause
        when :queue_remove
          remove_selected_download
        end
      end

      def handle_input_key(key)
        case key
        when :escape
          @mutex.synchronize { @state.mode = :normal }
        when :enter
          submit_input_buffer
        when :backspace
          @mutex.synchronize { @state.input_buffer = @state.input_buffer[0...-1].to_s }
        when String
          if key.valid_encoding? && key.length == 1 && key.ord >= 32
            @mutex.synchronize do
              next if @state.mode == :set_limit && !key.match?(/\A\d\z/)

              @state.input_buffer = "#{@state.input_buffer}#{key}"
            end
          end
        end
        :continue
      end

      def submit_input_buffer
        mode, value = @mutex.synchronize do
          m = @state.mode
          v = @state.input_buffer.strip
          @state.mode = :normal
          [m, v]
        end
        return if value.empty?

        case mode
        when :search then perform_search(value)
        when :add_url then perform_add_url(value)
        when :set_limit then apply_search_limit(value.to_i)
        end
      end

      def handle_help_key(key)
        return :quit if %w[q Q].include?(key)

        @mutex.synchronize { @state.mode = :normal } if %i[escape enter].include?(key) || key == '?'
        :continue
      end

      def handle_normal_key(key)
        case key
        when 'q', 'Q' then return :quit
        when '?'
          @mutex.synchronize { @state.mode = :help }
        when '/'
          open_prompt(:search, @state.search_query)
        when 'l', 'L'
          open_prompt(:set_limit, @state.search_limit.to_s)
        when 'a', 'A'
          open_prompt(:add_url, '')
        when '1', '2', '3', '4', '5', '6', '7', '8'
          activate_category(key.to_i - 1)
        when :tab
          activate_category((@state.category_index + 1) % State::CATEGORIES.size)
        when :shift_tab
          activate_category((@state.category_index - 1) % State::CATEGORIES.size)
        when :up, 'k' then @mutex.synchronize { @state.move_gallery(:up) }
        when :down, 'j' then @mutex.synchronize { @state.move_gallery(:down) }
        when :left, 'h' then @mutex.synchronize { @state.move_gallery(:left) }
        when :right then @mutex.synchronize { @state.move_gallery(:right) }
        when ' ' then @mutex.synchronize { @state.toggle_pin_selection }
        when 's', 'S', :ctrl_a then @mutex.synchronize { @state.toggle_select_all_visible! }
        when 'b', 'B' then enqueue_batch_download
        when 'v', 'V' then @mutex.synchronize { @state.cycle_quality!(1) }
        when 'd', 'D', :enter then enqueue_selected_pin
        when 'p', 'P' then pause_selected_download
        when 'r', 'R' then resume_selected_download
        when :delete, :backspace then remove_selected_download
        end
        :continue
      end

      def open_prompt(mode, initial)
        @mutex.synchronize do
          @state.mode = mode
          @state.input_buffer = initial.to_s.dup
        end
      end

      def activate_category(index)
        cat = @mutex.synchronize { @state.select_category(index) }
        if cat[:query]
          perform_search(cat[:query])
        elsif !@state.search_query.empty? && @state.pins.empty?
          perform_search(@state.search_query)
        end
      end

      def enqueue_selected_pin
        pin, img_q, vid_q, out_dir = @mutex.synchronize do
          [@state.selected_pin, @state.image_quality, @state.video_quality, @state.output_dir]
        end
        return unless pin

        @queue.enqueue(pin, quality: img_q, video_quality: vid_q, output_dir: out_dir)
        @mutex.synchronize do
          @state.queue_selected_index = [@queue.items.size - 1, 0].max
          @state.error_banner = nil
          @state.status_message = "Added to Download Queue (#{img_q}) -> #{out_dir}"
        end
      rescue StandardError => e
        @mutex.synchronize { @state.error_banner = e.message }
      end

      def toggle_queue_pause
        item = selected_queue_item
        return unless item

        if %i[paused failed].include?(item.status)
          @queue.resume(item.id)
        else
          @queue.pause(item.id)
        end
      end

      def pause_selected_download
        item = selected_queue_item
        @queue.pause(item.id) if item
      end

      def resume_selected_download
        item = selected_queue_item
        @queue.resume(item.id) if item
      end

      def remove_selected_download
        item = selected_queue_item
        return unless item

        removed = @queue.remove(item.id)
        @mutex.synchronize { @state.queue_selected_index = [(@state.queue_selected_index - 1), 0].max } if removed
      end

      def selected_queue_item
        items = @queue.items
        return nil if items.empty?

        idx = @mutex.synchronize { @state.queue_selected_index }
        items[idx] || items.last
      end

      def execute_search_query(query)
        search_type, limit = @mutex.synchronize { [@state.search_type_for_active_category, @state.search_limit] }
        pins = @session.search(query, limit: limit, type: search_type)
        apply_loaded_pins(pins)
      rescue RateLimitError => e
        record_network_error(:rate_limited, "Rate limited (HTTP 429): #{e.message}")
      rescue NetworkError => e
        record_network_error(:offline, "Network error: #{e.message}")
      rescue PinterestDL::Error, StandardError => e
        record_network_error(:online, e.message)
      end

      def execute_url_load(url)
        limit = @mutex.synchronize { @state.search_limit }
        pins = if url.match?(PinterestDL::PIN_URL_PATTERN)
                 media = @session.get_media(url, quality: @state.image_quality)
                 pin_id = url[%r{/pin/(?:[^/?#]*--)?(\d+)}, 1] || Time.now.to_i.to_s
                 [{
                   id: pin_id,
                   pin_url: url,
                   title: "Pin #{pin_id}",
                   description: url,
                   creator: '',
                   image_url: media[:image_url],
                   video_url: media[:video_url]
                 }]
               else
                 @session.board(url, limit: limit)
               end
        @mutex.synchronize { @state.search_query = url }
        apply_loaded_pins(pins)
      rescue RateLimitError => e
        record_network_error(:rate_limited, "Rate limited (HTTP 429): #{e.message}")
      rescue NetworkError => e
        record_network_error(:offline, "Network error: #{e.message}")
      rescue PinterestDL::Error, StandardError => e
        record_network_error(:online, e.message)
      end

      def apply_loaded_pins(pins)
        @mutex.synchronize do
          @state.replace_pins(pins)
          @state.loading = false
          @state.network_status = @session.config.proxy.to_s.empty? ? :online : :proxy
          @state.error_banner = nil
          @dirty = true
        end
      end

      def record_network_error(net_status, message)
        @mutex.synchronize do
          @state.loading = false
          @state.network_status = net_status
          @state.error_banner = message.to_s
          @dirty = true
        end
      end

      def spawn_background(&block)
        thread = Thread.new do
          Thread.current.report_on_exception = false
          block.call
        end
        @bg_threads << thread
        @bg_threads.select!(&:alive?)
        thread
      end

      def render_if_dirty
        should_render = @mutex.synchronize do
          val = @dirty
          @dirty = false
          val
        end
        return unless should_render

        frame = render_frame
        @terminal.render_frame(frame, overlays: @renderer.kitty_overlays)
        @preview.sync_ueberzug(@renderer.ueberzug_placements)
      end

      def mark_dirty
        @mutex.synchronize { @dirty = true }
      end

      def install_resize_handler
        return nil unless Signal.list.key?('WINCH')

        Signal.trap('WINCH') { @resized = true }
      rescue ArgumentError, NotImplementedError
        nil
      end

      def restore_resize_handler(previous)
        return unless previous && Signal.list.key?('WINCH')

        Signal.trap('WINCH', previous)
      rescue ArgumentError, NotImplementedError
        nil
      end
    end
  end
end
