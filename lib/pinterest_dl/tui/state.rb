# frozen_string_literal: true

require_relative '../configuration'

module PinterestDL
  module TUI
    class State
      CATEGORIES = [
        { key: :all, label: 'All', type: :all, query: nil },
        { key: :images, label: 'Images', type: :image, query: nil },
        { key: :videos, label: 'Videos', type: :video, query: nil },
        { key: :anime, label: 'Anime', type: :all, query: 'anime wallpaper' },
        { key: :gaming, label: 'Gaming', type: :all, query: 'gaming aesthetic art' },
        { key: :aesthetic, label: 'Aesthetic', type: :all, query: 'neon aesthetic' },
        { key: :nature, label: 'Nature', type: :all, query: 'nature landscape photography' },
        { key: :art, label: 'Art', type: :all, query: 'digital illustration art' }
      ].freeze

      IMAGE_QUALITIES = Configuration::VALID_QUALITIES
      VIDEO_QUALITIES = %i[best 1080p 720p 480p].freeze
      DEFAULT_SEARCH_LIMIT = 25
      MIN_SEARCH_LIMIT = 1
      MAX_SEARCH_LIMIT = 200

      attr_accessor :mode, :category_index, :search_query, :input_buffer,
                    :all_pins, :pins, :selected_index, :queue_selected_index,
                    :image_quality_index, :video_quality_index,
                    :output_dir, :network_status, :status_message,
                    :error_banner, :loading, :grid_columns, :search_limit

      def initialize(output_dir: './downloads', proxy_enabled: false, search_limit: DEFAULT_SEARCH_LIMIT)
        @mode = :normal
        @category_index = 0
        @search_query = ''
        @input_buffer = ''
        @all_pins = []
        @pins = []
        @selected_index = 0
        @queue_selected_index = 0
        @image_quality_index = 0
        @video_quality_index = 0
        @output_dir = output_dir
        @network_status = proxy_enabled ? :proxy : :online
        @status_message = nil
        @error_banner = nil
        @loading = false
        @grid_columns = 4
        @search_limit = clamp_search_limit(search_limit)
        @selected_pin_ids = {}
      end

      def update_search_limit(value)
        @search_limit = clamp_search_limit(value)
      end

      def active_category
        CATEGORIES[@category_index % CATEGORIES.size]
      end

      def select_category(index)
        @category_index = [[index.to_i, 0].max, CATEGORIES.size - 1].min
        apply_category_filter!
        active_category
      end

      def cycle_category(step = 1)
        @category_index = (@category_index + step) % CATEGORIES.size
        apply_category_filter!
        active_category
      end

      def selected_pin
        return nil if @pins.empty?

        @pins[@selected_index]
      end

      def toggle_pin_selection(pin = selected_pin)
        return false unless pin

        key = pin_key(pin)
        if @selected_pin_ids.key?(key)
          @selected_pin_ids.delete(key)
          false
        else
          @selected_pin_ids[key] = true
          true
        end
      end

      def pin_selected?(pin)
        return false unless pin

        @selected_pin_ids.key?(pin_key(pin))
      end

      def selected_batch_count
        @selected_pin_ids.size
      end

      def selected_batch_pins
        @all_pins.select { |pin| @selected_pin_ids.key?(pin_key(pin)) }
      end

      def toggle_select_all_visible!
        return if @pins.empty?

        all_marked = @pins.all? { |p| pin_selected?(p) }
        if all_marked
          @pins.each { |p| @selected_pin_ids.delete(pin_key(p)) }
        else
          @pins.each { |p| @selected_pin_ids[pin_key(p)] = true }
        end
      end

      def clear_selection!
        @selected_pin_ids.clear
      end

      def image_quality
        IMAGE_QUALITIES[@image_quality_index % IMAGE_QUALITIES.size]
      end

      def video_quality
        VIDEO_QUALITIES[@video_quality_index % VIDEO_QUALITIES.size]
      end

      def cycle_quality!(step = 1)
        pin = selected_pin
        if pin && !pin[:video_url].to_s.empty?
          @video_quality_index = (@video_quality_index + step) % VIDEO_QUALITIES.size
          @status_message = "Video quality: #{video_quality}"
        else
          @image_quality_index = (@image_quality_index + step) % IMAGE_QUALITIES.size
          @status_message = "Image quality: #{image_quality}"
        end
      end

      def move_gallery(direction)
        return if @pins.empty?

        cols = [@grid_columns, 1].max
        next_idx = case direction
                   when :left then @selected_index - 1
                   when :right then @selected_index + 1
                   when :up then @selected_index - cols
                   when :down then @selected_index + cols
                   else @selected_index
                   end
        @selected_index = [[next_idx, 0].max, @pins.size - 1].min
      end

      def replace_pins(new_pins)
        @all_pins = Array(new_pins)
        @selected_pin_ids.clear
        apply_category_filter!
      end

      def apply_category_filter!
        cat = active_category
        @pins = case cat[:type]
                when :image
                  @all_pins.select { |p| !p[:image_url].to_s.empty? && p[:video_url].to_s.empty? }
                when :video
                  @all_pins.reject { |p| p[:video_url].to_s.empty? }
                else
                  @all_pins.dup
                end
        @selected_index = 0
      end

      def search_type_for_active_category
        active_category[:type]
      end

      private

      def clamp_search_limit(value)
        num = value.to_i
        num = DEFAULT_SEARCH_LIMIT unless num.positive?
        [[num, MIN_SEARCH_LIMIT].max, MAX_SEARCH_LIMIT].min
      end

      def pin_key(pin)
        id = pin[:id].to_s
        id.empty? ? pin[:image_url].to_s : id
      end
    end
  end
end
