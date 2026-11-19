# frozen_string_literal: true

require 'uri'
require_relative '../progress_bar'

module PinterestDL
  module TUI
    class Renderer
      MIN_RENDER_WIDTH = 40
      MIN_RENDER_HEIGHT = 12
      CARD_TITLE_CHARS = 7

      attr_reader :hit_regions, :kitty_overlays, :ueberzug_placements

      def initialize(theme:, icons:, preview:, clock: -> { Time.now })
        @theme = theme
        @icons = icons
        @preview = preview
        @clock = clock
        @hit_regions = []
        @kitty_overlays = []
        @ueberzug_placements = []
      end

      def render(state, queue_items:, width:, height:, active_speed: 0.0)
        w = [width.to_i, 20].max
        h = [height.to_i, 8].max
        @hit_regions = []
        @kitty_overlays = []
        @ueberzug_placements = []

        return render_too_small(w, h) if w < MIN_RENDER_WIDTH || h < MIN_RENDER_HEIGHT

        lines = []
        lines << render_header(state, w, active_speed)
        lines.concat(render_search_row(state, w, start_y: lines.size + 1))
        lines << render_category_row(state, w, row_y: lines.size + 1)

        queue_h = compute_queue_height(h)
        footer_h = 1
        body_y = lines.size + 1
        body_h = [h - lines.size - queue_h - footer_h, 6].max

        right_w = compute_right_width(w)
        left_w = [w - right_w - 1, 16].max
        state.grid_columns = compute_grid_columns(left_w)

        gallery_rows = render_gallery(state, left_w, body_h, start_y: body_y)
        preview_rows = render_preview_panel(state, right_w, body_h, start_x: left_w + 2, start_y: body_y)

        body_h.times do |idx|
          lines << "#{gallery_rows[idx]} #{preview_rows[idx]}"
        end

        queue_y = lines.size + 1
        lines.concat(render_download_queue(state, queue_items, w, queue_h, start_y: queue_y))
        lines << render_footer(state, w)

        lines = overlay_help_modal(lines, w, h) if state.mode == :help
        lines << '' while lines.size < h
        lines.first(h).map { |line| @theme.apply_canvas_bg(@theme.fit(line, w)) }.join("\n")
      end

      def region_at(col, row)
        @hit_regions.reverse_each do |reg|
          return reg if col >= reg[:x1] && col <= reg[:x2] && row >= reg[:y1] && row <= reg[:y2]
        end
        nil
      end

      private

      def compute_queue_height(height)
        return 6 if height >= 28
        return 5 if height >= 20

        3
      end

      def compute_right_width(width)
        return [[(width * 0.42).to_i, 20].max, width - 17].min if width < 72

        [[(width * 0.36).to_i, 28].max, [46, width - 24].min].min
      end

      def register_region(x1:, y1:, x2:, y2:, action:, value: nil)
        @hit_regions << { x1: x1, y1: y1, x2: x2, y2: y2, action: action, value: value }
      end

      def render_too_small(width, height)
        msg = "Resize terminal (min #{MIN_RENDER_WIDTH}x#{MIN_RENDER_HEIGHT})"
        mid = height / 2
        Array.new(height) do |idx|
          line = if idx == mid
                   txt = @theme.truncate(msg, [width - 2, 1].max)
                   pad = [(width - @theme.visible_length(txt)) / 2, 0].max
                   (' ' * pad) + @theme.paint(txt, color: :pink, bold: true)
                 else
                   ''
                 end
          @theme.apply_canvas_bg(@theme.fit(line, width))
        end.join("\n")
      end

      def compute_grid_columns(gallery_width)
        return 4 if gallery_width >= 82
        return 3 if gallery_width >= 58
        return 2 if gallery_width >= 34

        1
      end

      def render_header(state, width, active_speed)
        title = @theme.paint('Pinterest-DL', color: :pink, bold: true)
        sep = @theme.paint('│', color: :border_dim)
        left = if width >= 72
                 subtitle = @theme.paint('Browse • Preview • Download', color: :purple)
                 " #{title}  #{sep}  #{subtitle}"
               else
                 " #{title}"
               end

        net = @icons.wifi(state.network_status)
        speed_txt = "#{ProgressBar.format_bytes(active_speed)}/s"
        bars = "#{@icons.signal_bars(active: active_speed.positive?)} #{@theme.paint(speed_txt, color: :white)}"
        clock_txt = @theme.paint(@clock.call.strftime('%H:%M'), color: :soft_text)
        right = if width >= 56
                  "#{net}  #{sep}  #{bars}  #{sep}  #{clock_txt} "
                else
                  "#{net} #{sep} #{clock_txt} "
                end

        gap = [width - @theme.visible_length(left) - @theme.visible_length(right), 1].max
        @theme.fit("#{left}#{' ' * gap}#{right}", width)
      end

      def render_search_row(state, width, start_y:)
        compact = width < 64
        btn_w = compact ? 8 : 10
        lim_w = compact ? 8 : 13
        box_w = [width - btn_w - lim_w - 2, 12].max
        editing = %i[search add_url set_limit].include?(state.mode)
        bc = editing ? :pink : :border_dim
        b = @theme.border(selected: false)

        lim_x = box_w + 2
        btn_x = lim_x + lim_w + 1
        register_region(x1: 1, y1: start_y, x2: box_w, y2: start_y + 2, action: :search_box)
        register_region(x1: lim_x, y1: start_y, x2: lim_x + lim_w - 1, y2: start_y + 2, action: :limit_box)
        register_region(x1: btn_x, y1: start_y, x2: width, y2: start_y + 2, action: :search_submit)

        inner_w = box_w - 2
        prompt_text = search_box_content(state, inner_w)

        lim_inner = lim_w - 2
        lim_label = compact ? "L:#{state.search_limit}" : "Limit: #{state.search_limit}"
        lim_pad = [(lim_inner - lim_label.length) / 2, 0].max
        lim_bc = state.mode == :set_limit ? :pink : :border_dim
        lim_text = (' ' * lim_pad) + @theme.paint(lim_label, color: :soft_text, bold: state.mode == :set_limit)

        btn_inner = btn_w - 2
        btn_label = case state.mode
                    when :add_url then 'Add'
                    when :set_limit then 'OK'
                    else compact ? 'Go' : 'Search'
                    end
        btn_pad = [(btn_inner - btn_label.length) / 2, 0].max
        btn_bc = editing ? :pink : :purple
        btn_text = (' ' * btn_pad) + @theme.paint(btn_label, color: :white, bold: true)

        top = "#{@theme.paint("#{b[:tl]}#{b[:h] * inner_w}#{b[:tr]}", color: bc)} " \
              "#{@theme.paint("#{b[:tl]}#{b[:h] * lim_inner}#{b[:tr]}", color: lim_bc)} " \
              "#{@theme.paint("#{b[:tl]}#{b[:h] * btn_inner}#{b[:tr]}", color: btn_bc)}"
        mid = "#{@theme.paint(b[:v], color: bc)}#{@theme.fit(prompt_text, inner_w)}#{@theme.paint(b[:v], color: bc)} " \
              "#{@theme.paint(b[:v], color: lim_bc)}#{@theme.fit(lim_text, lim_inner)}#{@theme.paint(b[:v], color: lim_bc)} " \
              "#{@theme.paint(b[:v], color: btn_bc)}#{@theme.fit(btn_text, btn_inner)}#{@theme.paint(b[:v], color: btn_bc)}"
        bot = "#{@theme.paint("#{b[:bl]}#{b[:h] * inner_w}#{b[:br]}", color: bc)} " \
              "#{@theme.paint("#{b[:bl]}#{b[:h] * lim_inner}#{b[:br]}", color: lim_bc)} " \
              "#{@theme.paint("#{b[:bl]}#{b[:h] * btn_inner}#{b[:br]}", color: btn_bc)}"

        [top, mid, bot]
      end

      def search_box_content(state, max_w)
        case state.mode
        when :search
          val = @theme.truncate(state.input_buffer, [max_w - 6, 4].max)
          " #{@icons.search}  #{@theme.paint("#{val}_", color: :white, bold: true)}"
        when :add_url
          val = @theme.truncate(state.input_buffer, [max_w - 8, 4].max)
          " #{@theme.paint('URL:', color: :pink, bold: true)} #{@theme.paint("#{val}_", color: :white)}"
        when :set_limit
          val = @theme.truncate(state.input_buffer, [max_w - 16, 4].max)
          " #{@theme.paint('Limit:', color: :pink, bold: true)} #{@theme.paint("#{val}_", color: :white, bold: true)}"
        else
          if state.search_query.empty?
            hint_txt = @theme.truncate('Press / to search (L for limit, A for URL)...', [max_w - 5, 4].max)
            " #{@icons.search}  #{@theme.paint(hint_txt, color: :dim_text)}"
          else
            " #{@icons.search}  #{@theme.paint(@theme.truncate(state.search_query, [max_w - 5, 4].max), color: :white)}"
          end
        end
      end

      def render_category_row(state, width, row_y:)
        out = +' '
        cursor_x = 2
        State::CATEGORIES.each_with_index do |cat, idx|
          label = " #{cat[:label]} "
          vis_w = @theme.visible_length(label)
          break if cursor_x + vis_w > width

          styled = if idx == state.category_index
                     @theme.paint(label, color: :white, background: :pink, bold: true)
                   else
                     @theme.paint(label, color: :soft_text, background: :bg_pill)
                   end
          register_region(x1: cursor_x, y1: row_y, x2: cursor_x + vis_w - 1, y2: row_y, action: :category, value: idx)
          out << styled << ' '
          cursor_x += vis_w + 1
        end
        @theme.fit(out, width)
      end

      def render_gallery(state, width, height, start_y:)
        return render_empty_gallery(state, width, height) if state.pins.empty?

        cols = [state.grid_columns, 1].max
        gutter = 1
        card_w = [(width - ((cols - 1) * gutter)) / cols, 12].max
        visible_rows = height >= 14 ? 2 : 1
        card_h = [height / visible_rows, 5].max

        selected_row = state.selected_index / cols
        start_row = [selected_row - visible_rows + 1, 0].max

        lines = []
        visible_rows.times do |r_off|
          row_idx = start_row + r_off
          card_top_y = start_y + (r_off * card_h)
          cards = Array.new(cols) do |col_idx|
            pin_idx = (row_idx * cols) + col_idx
            card_left_x = 1 + (col_idx * (card_w + gutter))
            if pin_idx < state.pins.size
              pin = state.pins[pin_idx]
              register_card_regions(pin_idx, card_left_x, card_top_y, card_w, card_h)
              render_card(
                pin, card_w, card_h,
                selected: pin_idx == state.selected_index,
                marked: state.pin_selected?(pin),
                slot_id: "card_#{r_off}_#{col_idx}",
                screen_x: card_left_x + 1,
                screen_y: card_top_y + 1
              )
            else
              Array.new(card_h, ' ' * card_w)
            end
          end

          card_h.times do |l_idx|
            row_line = cards.map { |c| c[l_idx] }.join(' ' * gutter)
            lines << @theme.fit(row_line, width)
          end
        end

        lines << @theme.fit('', width) while lines.size < height
        lines.first(height)
      end

      def register_card_regions(pin_idx, x1, y1, card_w, card_h)
        register_region(x1: x1, y1: y1, x2: x1 + card_w - 1, y2: y1 + card_h - 1, action: :card, value: pin_idx)
        cb_x1 = [x1 + card_w - 5, x1].max
        register_region(x1: cb_x1, y1: y1, x2: x1 + card_w - 1, y2: y1, action: :card_select, value: pin_idx)
      end

      def render_empty_gallery(state, width, height)
        msg = if state.loading
                "Searching Pinterest (limit #{state.search_limit})..."
              elsif state.error_banner
                state.error_banner
              elsif !state.search_query.empty?
                "No #{state.active_category[:label].downcase} pins found"
              else
                'Press [/] to search Pinterest, [L] for limit, [A] for URL'
              end
        color = if state.error_banner
                  :red
                elsif state.loading
                  :yellow
                else
                  :soft_text
                end
        b = @theme.border(selected: false)
        inner_w = [width - 2, 4].max
        inner_h = [height - 2, 1].max
        mid = inner_h / 2

        rows = Array.new(inner_h) do |idx|
          if idx == mid
            txt = @theme.truncate(msg, [inner_w - 2, 4].max)
            pad = [(inner_w - @theme.visible_length(txt)) / 2, 0].max
            (' ' * pad) + @theme.paint(txt, color: color, bold: true)
          else
            ''
          end
        end
        wrap_box(rows, width: width, height: height, border: b, border_color: :border_muted)
      end

      def render_card(pin, width, height, selected:, marked:, slot_id:, screen_x:, screen_y:)
        b = @theme.border(selected: selected)
        bc = if marked
               :green
             elsif selected
               :pink
             else
               :border_dim
             end
        inner_w = [width - 2, 6].max
        is_video = !pin[:video_url].to_s.empty?
        art_h = [height - 3, 2].max
        art = @preview.render_pin(pin, width: inner_w, height: art_h, large: false)
        maybe_add_overlays(pin, id: slot_id, x: screen_x, y: screen_y, width: inner_w, height: art_h, large: false)

        glyph = is_video ? @icons.video : @icons.image
        raw_title = pin_display_title(pin)
        short_title = @theme.truncate_chars(raw_title, CARD_TITLE_CHARS)
        cap_txt = @theme.truncate(short_title, [inner_w - 4, 4].max)
        cap_line = " #{glyph} #{@theme.paint(cap_txt, color: selected ? :white : :soft_text, bold: selected)}"

        top = render_card_top_border(b, bc, inner_w, marked: marked)
        bot = @theme.paint("#{b[:bl]}#{b[:h] * inner_w}#{b[:br]}", color: bc)
        body = (art + [cap_line]).first(height - 2)
        mid_row = body.size / 2

        middle = body.each_with_index.map do |row, idx|
          left_edge = if selected && idx == mid_row
                        @theme.paint('▸', color: :white, bold: true)
                      else
                        @theme.paint(b[:v], color: bc)
                      end
          "#{left_edge}#{@theme.fit(row, inner_w)}#{@theme.paint(b[:v], color: bc)}"
        end

        [top] + middle + [bot]
      end

      def maybe_add_overlays(pin, id:, x:, y:, width:, height:, large:)
        if @preview.respond_to?(:overlay_for)
          ov = @preview.overlay_for(pin, x: x, y: y, width: width, height: height, large: large)
          @kitty_overlays << ov if ov
        end
        return unless @preview.respond_to?(:ueberzug_placement_for)

        pl = @preview.ueberzug_placement_for(pin, id: id, x: x, y: y, width: width, height: height, large: large)
        @ueberzug_placements << pl if pl
      end

      def render_card_top_border(border, color, inner_w, marked:)
        badge = marked ? "[#{@icons.check}]" : @theme.paint('[ ]', color: :border_muted)
        badge_w = 3
        rem = [inner_w - badge_w - 1, 0].max
        left_part = @theme.paint("#{border[:tl]}#{border[:h] * rem}", color: color)
        right_part = @theme.paint("#{border[:h]}#{border[:tr]}", color: color)
        "#{left_part}#{badge}#{right_part}"
      end

      def render_preview_panel(state, width, height, start_x:, start_y:)
        b = @theme.border(selected: false)
        inner_w = [width - 2, 10].max
        inner_h = [height - 2, 4].max
        pin = state.selected_pin

        counter_line = render_preview_counter(state, inner_w, start_x: start_x + 1, row_y: start_y + 1)

        compact_meta = inner_h < 13
        btn_h = inner_h >= 10 ? 3 : 1
        meta_placeholder = render_preview_metadata(
          pin, state, inner_w,
          start_x: start_x + 1, start_y: start_y + 2, register: false, compact: compact_meta
        )
        meta_h = meta_placeholder.size
        art_h = [inner_h - 1 - meta_h - btn_h, 2].max
        art_lines = @preview.render_pin(pin, width: inner_w, height: art_h, large: true)
        maybe_add_overlays(pin, id: 'preview_main', x: start_x + 1, y: start_y + 2, width: inner_w, height: art_h, large: true)

        meta_y = start_y + 2 + art_lines.size
        meta_lines = render_preview_metadata(
          pin, state, inner_w,
          start_x: start_x + 1, start_y: meta_y, register: true, compact: compact_meta
        )
        btn_y = meta_y + meta_lines.size
        btn_lines = render_download_button(pin, inner_w, start_x: start_x + 1, start_y: btn_y, compact: btn_h == 1)

        content = [counter_line] + art_lines + meta_lines + btn_lines
        wrap_box(content.first(inner_h), width: width, height: height, border: b, border_color: :purple)
      end

      def render_preview_counter(state, inner_w, start_x:, row_y:)
        counter = if state.pins.empty?
                    '◂ 0 / 0 ▸'
                  else
                    "◂ #{state.selected_index + 1} / #{state.pins.size} ▸"
                  end
        vis_w = @theme.visible_length(counter)
        header_pad = [inner_w - vis_w - 1, 0].max
        c_x = start_x + header_pad
        register_region(x1: c_x, y1: row_y, x2: c_x + 2, y2: row_y, action: :preview_prev)
        register_region(x1: c_x + vis_w - 3, y1: row_y, x2: c_x + vis_w, y2: row_y, action: :preview_next)

        "#{' ' * header_pad}#{@theme.paint(counter, color: :soft_text, bold: true)}"
      end

      def render_preview_metadata(pin, state, width, start_x:, start_y:, register:, compact: false)
        unless pin
          empty_count = compact ? 2 : 6
          return [@theme.paint(' No pin selected', color: :dim_text)] + Array.new(empty_count, '')
        end

        is_video = !pin[:video_url].to_s.empty?
        title = pin_display_title(pin)
        raw_desc = @theme.sanitize_display(pin[:description].to_s)
        desc = if raw_desc.empty? || raw_desc.casecmp?(title) || raw_desc.casecmp?('pin')
                 pin[:id].to_s.empty? ? 'Pinterest media' : "ID: #{pin[:id]}"
               else
                 raw_desc
               end
        creator = @theme.sanitize_display(pin[:creator].to_s)
        creator = 'pinterest' if creator.empty?
        qual = is_video ? state.video_quality : state.image_quality
        fmt = is_video ? 'Video • MP4' : "Image • #{extract_format(pin[:image_url])}"
        size_txt = format_pin_dimensions(pin)

        rows = [" #{@theme.paint(@theme.truncate(title, width - 2), color: :white, bold: true)}"]
        unless compact
          rows << " #{@theme.paint(@theme.truncate(desc, width - 2), color: :soft_text)}"
          rows << @theme.paint(" #{'─' * [width - 2, 2].max}", color: :border_muted)
        end

        qual_row_y = start_y + rows.size
        qual_selector = "#{@theme.paint('◂', color: :pink, bold: true)} " \
                        "#{@theme.paint(qual.to_s, color: :white, background: :bg_pill, bold: true)} " \
                        "#{@theme.paint('▸', color: :pink, bold: true)}"
        if register
          qx = start_x + 12
          register_region(x1: qx - 1, y1: qual_row_y, x2: qx + 2, y2: qual_row_y, action: :quality_prev)
          register_region(x1: qx + 3, y1: qual_row_y, x2: start_x + width - 1, y2: qual_row_y, action: :quality_next)
        end
        rows << " #{@icons.quality_glyph} #{@theme.paint('Quality:', color: :soft_text)} #{qual_selector}"
        return rows if compact

        rows << " #{@icons.size_glyph} #{@theme.paint('Size:   ', color: :soft_text)} #{@theme.paint(size_txt, color: :purple, bold: true)}"
        rows << " #{@icons.format_glyph} #{@theme.paint('Format: ', color: :soft_text)} #{@theme.paint(fmt, color: :purple, bold: true)}"
        handle = "@#{@theme.truncate(creator, [width - 14, 6].max)}"
        rows << " #{@icons.creator_glyph} #{@theme.paint('Creator:', color: :soft_text)} #{@theme.paint(handle, color: :purple)}"
        rows
      end

      def format_pin_dimensions(pin)
        meta = @preview.respond_to?(:metadata_for) ? @preview.metadata_for(pin) : nil
        if meta && meta[:width] && meta[:height]
          size_str = meta[:bytes] ? " (#{ProgressBar.format_bytes(meta[:bytes])})" : ''
          "#{meta[:width]}x#{meta[:height]}#{size_str}"
        elsif meta && meta[:bytes]
          ProgressBar.format_bytes(meta[:bytes])
        else
          'Auto'
        end
      end

      def render_download_button(pin, width, start_x:, start_y:, compact: false)
        is_video = pin && !pin[:video_url].to_s.empty?
        label = is_video ? '↓ Download Video' : '↓ Download Image'
        if compact
          register_region(x1: start_x, y1: start_y, x2: start_x + width - 1, y2: start_y, action: :download_current)
          pad_l = [(width - @theme.visible_length(label)) / 2, 0].max
          return [(' ' * pad_l) + @theme.paint(@theme.truncate(label, width), color: :white, background: :purple, bold: true)]
        end

        b = @theme.border(selected: false)
        bw = [width - 2, 8].max
        register_region(x1: start_x, y1: start_y, x2: start_x + width - 1, y2: start_y + 2, action: :download_current)

        pad_l = [(bw - @theme.visible_length(label)) / 2, 0].max
        text = (' ' * pad_l) + @theme.paint(@theme.truncate(label, bw), color: :white, bold: true)
        [
          @theme.paint("#{b[:tl]}#{b[:h] * bw}#{b[:tr]}", color: :purple),
          "#{@theme.paint(b[:v], color: :purple)}#{@theme.fit(text, bw)}#{@theme.paint(b[:v], color: :purple)}",
          @theme.paint("#{b[:bl]}#{b[:h] * bw}#{b[:br]}", color: :purple)
        ]
      end

      def render_download_queue(state, queue_items, width, height, start_y:)
        b = @theme.border(selected: false)
        inner_w = [width - 2, 16].max
        title_text = " #{@icons.download} #{@theme.paint("Download Queue (#{queue_items.size})", color: :pink, bold: true)} "
        batch_btn = render_batch_badge(state)
        title_vis = @theme.visible_length(title_text)
        batch_vis = @theme.visible_length(batch_btn)

        if batch_vis.positive? && title_vis + batch_vis + 2 <= inner_w
          rem = inner_w - title_vis - batch_vis - 1
          bx1 = 2 + title_vis + rem
          register_region(x1: bx1, y1: start_y, x2: bx1 + batch_vis - 1, y2: start_y, action: :download_batch)
          top = "#{@theme.paint(b[:tl], color: :purple)}#{title_text}" \
                "#{@theme.paint(b[:h] * rem, color: :purple)}#{batch_btn}" \
                "#{@theme.paint("#{b[:h]}#{b[:tr]}", color: :purple)}"
        else
          rem = [inner_w - title_vis, 0].max
          top = "#{@theme.paint(b[:tl], color: :purple)}#{title_text}#{@theme.paint("#{b[:h] * rem}#{b[:tr]}", color: :purple)}"
        end
        bot = @theme.paint("#{b[:bl]}#{b[:h] * inner_w}#{b[:br]}", color: :purple)

        body_h = [height - 2, 1].max
        body_rows = if queue_items.empty?
                      render_empty_queue_rows(state, inner_w)
                    elsif body_h == 1 || width < 68
                      render_compact_queue_row(state, queue_items, inner_w, start_y: start_y + 1)
                    else
                      render_queue_split_rows(state, queue_items, inner_w, body_h, start_y: start_y + 1)
                    end

        middle = Array.new(body_h) do |idx|
          "#{@theme.paint(b[:v], color: :purple)}#{@theme.fit(body_rows[idx].to_s, inner_w)}#{@theme.paint(b[:v], color: :purple)}"
        end
        [top] + middle + [bot]
      end

      def render_compact_queue_row(state, queue_items, width, start_y:)
        sel_idx = [[state.queue_selected_index, queue_items.size - 1].min, 0].max
        item = queue_items[sel_idx]
        bar_w = [[width / 3, 14].min, 6].max
        bar = @theme.gradient_bar(item.progress_ratio, width: bar_w)
        pct = format('%<p>3d%%', p: item.percent)
        name = @theme.truncate(item.filename, [width - bar_w - 10, 6].max)
        register_region(x1: 2, y1: start_y, x2: width + 1, y2: start_y, action: :queue_select, value: sel_idx)
        [@theme.fit(" #{@theme.paint(name, color: :white, bold: true)} #{bar} #{@theme.paint(pct, color: :pink)}", width)]
      end

      def render_batch_badge(state)
        count = state.selected_batch_count
        return '' unless count.positive?

        @theme.paint(" ↓ Download Selected (#{count}) ", color: :white, background: :pink, bold: true)
      end

      def render_empty_queue_rows(state, width)
        hint1 = if state.selected_batch_count.positive?
                  "#{state.selected_batch_count} pins marked — press [B] or click Download Selected."
                else
                  'Queue empty — press [D] to download, [Space] to mark, [L] to change limit.'
                end
        [
          @theme.fit(" #{@theme.paint(hint1, color: :dim_text)}", width),
          @theme.fit(" #{@theme.paint('[Space] Mark  [S] All  [B] Batch  [L] Limit  [V] Quality', color: :border_dim)}", width),
          @theme.fit('', width)
        ]
      end

      def render_queue_split_rows(state, queue_items, width, body_h, start_y:)
        sel_idx = [[state.queue_selected_index, queue_items.size - 1].min, 0].max
        selected_item = queue_items[sel_idx]

        list_w = [[(width * 0.34).to_i, 20].max, 36].min
        detail_w = [width - list_w - 3, 22].max
        sep = @theme.paint('│', color: :border_muted)

        start_idx = [sel_idx - body_h + 1, 0].max
        list_rows = Array.new(body_h) do |r|
          idx = start_idx + r
          item = queue_items[idx]
          if item
            register_region(x1: 2, y1: start_y + r, x2: 1 + list_w, y2: start_y + r, action: :queue_select, value: idx)
            render_queue_list_row(item, list_w, selected: idx == sel_idx)
          else
            @theme.fit('', list_w)
          end
        end

        detail_x = 2 + list_w + 3
        detail_rows = render_queue_detail_rows(selected_item, detail_w, start_x: detail_x, start_y: start_y)

        Array.new(body_h) do |idx|
          "#{@theme.fit(list_rows[idx], list_w)} #{sep} #{@theme.fit(detail_rows[idx].to_s, detail_w)}"
        end
      end

      def render_queue_list_row(item, width, selected:)
        glyph = case item.status
                when :completed then @icons.check
                when :downloading then @icons.download
                when :paused then @icons.pause
                when :failed then @icons.trash
                else @theme.paint('•', color: :dim_text)
                end
        pct = format('%<p>3d%%', p: item.percent)
        name_max = [width - 9, 6].max
        name = @theme.truncate(item.filename, name_max)
        prefix = selected ? @theme.paint('▸', color: :pink, bold: true) : ' '
        text_color = selected ? :white : :soft_text
        row = "#{prefix}#{glyph} #{@theme.paint(name, color: text_color, bold: selected)}"
        pad = [width - @theme.visible_length(row) - pct.length - 1, 1].max
        @theme.fit("#{row}#{' ' * pad}#{@theme.paint(pct, color: selected ? :pink : :dim_text)}", width)
      end

      def render_queue_detail_rows(item, width, start_x:, start_y:)
        btn_w = 12
        stats_w = [[(width * 0.34).to_i, 18].max, 28].min
        left_w = [width - stats_w - btn_w - 2, 14].max

        btn_x = start_x + left_w + 1 + stats_w + 1
        register_region(x1: btn_x, y1: start_y, x2: btn_x + 4, y2: start_y + 2, action: :queue_pause)
        register_region(x1: btn_x + 6, y1: start_y, x2: btn_x + 10, y2: start_y + 2, action: :queue_remove)

        bar_w = [left_w - 8, 6].max
        bar = @theme.gradient_bar(item.progress_ratio, width: bar_w)
        pct = @theme.paint(format('%<p>3d%%', p: item.percent), color: :white, bold: true)

        status_detail = if item.status == :failed
                          @theme.paint(@theme.truncate("Error: #{item.error_message}", left_w - 1), color: :red)
                        else
                          @theme.paint("Status: #{item.status.to_s.upcase} (#{item.quality})", color: :soft_text)
                        end

        l_rows = [
          @theme.paint(@theme.truncate(item.filename, left_w - 1), color: :white, bold: true),
          "#{bar} #{pct}",
          status_detail
        ]

        rec_str = ProgressBar.format_bytes(item.bytes_received)
        tot_str = item.total_bytes&.positive? ? ProgressBar.format_bytes(item.total_bytes) : '---'
        spd_str = "#{ProgressBar.format_bytes(item.speed)}/s"
        eta_str = item.status == :downloading ? ProgressBar.format_eta(item.eta) : '--:--'

        s_rows = [
          "#{@theme.paint('Speed:', color: :soft_text)} #{@theme.paint(spd_str, color: :white)}",
          "#{@theme.paint('Size:', color: :soft_text)}  #{@theme.paint("#{rec_str}/#{tot_str}", color: :white)}",
          "#{@theme.paint('ETA:', color: :soft_text)}   #{@theme.paint(eta_str, color: :white)}"
        ]

        pause_icon = item.status == :paused ? @icons.resume : @icons.pause
        b_rows = [
          "#{@theme.paint('╭───╮', color: :purple)} #{@theme.paint('╭───╮', color: :red)}",
          "#{@theme.paint('│', color: :purple)} #{pause_icon} #{@theme.paint('│', color: :purple)} " \
          "#{@theme.paint('│', color: :red)} #{@icons.trash} #{@theme.paint('│', color: :red)}",
          "#{@theme.paint('╰───╯', color: :purple)} #{@theme.paint('╰───╯', color: :red)}"
        ]

        Array.new(3) do |idx|
          "#{@theme.fit(l_rows[idx], left_w)} #{@theme.fit(s_rows[idx], stats_w)} #{@theme.fit(b_rows[idx], btn_w)}"
        end
      end

      def render_footer(state, width)
        if state.error_banner
          return @theme.fit(" #{@theme.paint("Error: #{state.error_banner}", color: :red, bold: true)}", width)
        end
        if state.status_message
          return @theme.fit(" #{@theme.paint(state.status_message, color: :cyan)}", width)
        end

        hints = [
          hint('[↑↓←→/Click]', 'Nav'),
          hint('[Space]', 'Mark'),
          hint('[B]', 'Batch'),
          hint('[L]', 'Limit'),
          hint('[V]', 'Qual'),
          hint('[/]', 'Search'),
          hint('[D]', 'DL'),
          hint('[Q]', 'Quit')
        ].join('  ')
        @theme.fit(" #{hints}", width)
      end

      def hint(key, label)
        "#{@theme.paint(key, color: :soft_text, bold: true)} #{@theme.paint(label, color: :dim_text)}"
      end

      def wrap_box(content_lines, width:, height:, border:, border_color:)
        inner_w = [width - 2, 2].max
        inner_h = [height - 2, 1].max
        top = @theme.paint("#{border[:tl]}#{border[:h] * inner_w}#{border[:tr]}", color: border_color)
        bot = @theme.paint("#{border[:bl]}#{border[:h] * inner_w}#{border[:br]}", color: border_color)
        rows = Array.new(inner_h) do |idx|
          "#{@theme.paint(border[:v], color: border_color)}#{@theme.fit(content_lines[idx].to_s, inner_w)}" \
          "#{@theme.paint(border[:v], color: border_color)}"
        end
        [top] + rows + [bot]
      end

      def pin_display_title(pin)
        raw = @theme.sanitize_display(pin[:title].to_s)
        raw = @theme.sanitize_display(pin[:description].to_s) if raw.empty?
        raw.empty? ? "Pin #{pin[:id]}" : raw
      end

      def extract_format(url)
        ext = File.extname(URI.parse(url.to_s).path.to_s).delete('.').upcase
        ext.empty? ? 'JPG' : ext
      rescue URI::InvalidURIError
        'JPG'
      end

      def overlay_help_modal(lines, width, height)
        modal_w = [60, width - 4].min
        help_rows = [
          @theme.paint('  Pinterest-DL Shortcuts & Mouse Controls', color: :pink, bold: true),
          '',
          '  / or Click Search    Search Pinterest pins',
          '  L or Click Limit     Set search result limit (default 25, max 200)',
          '  A                    Add a Pinterest Pin or Board URL',
          '  1 - 8 / Tab / Click  Switch category (All, Images, Videos, ...)',
          '  Arrows / Wheel       Navigate thumbnail gallery',
          '  Space / Right-Click  Toggle pin for batch download',
          '  S / Ctrl-A           Select or deselect all visible pins',
          '  B / Click Batch      Download all selected (or visible) pins',
          '  V / Click ◂ Qual ▸   Select download quality in right panel',
          '  D / Enter            Download current pin into queue list',
          '  P / R / Del          Pause / Resume / Remove queue item',
          '  ? / Esc / Q          Toggle help / Close / Quit'
        ]
        modal = wrap_box(help_rows, width: modal_w, height: help_rows.size + 2, border: @theme.border(selected: false), border_color: :pink)
        top_row = [(height - modal.size) / 2, 1].max
        left_col = [(width - modal_w) / 2, 1].max

        result = lines.dup
        modal.each_with_index do |m_line, offset|
          target = top_row + offset
          next if target >= result.size

          result[target] = "#{' ' * left_col}#{m_line}"
        end
        result
      end
    end
  end
end
