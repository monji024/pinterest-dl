# frozen_string_literal: true

require 'fileutils'
require 'json'
require 'open3'
require 'tmpdir'

module PinterestDL
  module TUI
    class Preview
      MAX_CACHE_ENTRIES = 96
      MAX_DOWNLOAD_BYTES = 6 * 1024 * 1024
      WORKER_COUNT = 3
      BG_RGB = [13, 9, 26].freeze

      attr_reader :backend, :graphics_protocol

      def initialize(theme:, icons:, session: nil, external_tools: true,
                     graphics_protocol: nil, kitty_graphics: false, on_ready: nil)
        @theme = theme
        @icons = icons
        @session = session
        @external_tools = external_tools
        @graphics_protocol = graphics_protocol || (kitty_graphics ? :kitty : :none)
        @on_ready = on_ready
        @cache = {}
        @files = {}
        @png_files = {}
        @sixel_cache = {}
        @metadata = {}
        @pending = {}
        @failed = {}
        @mutex = Mutex.new
        @job_queue = Queue.new
        @running = true
        @cache_dir = external_tools ? Dir.mktmpdir('pinterest_dl_tui_') : nil
        @backend, @backend_bin = external_tools ? detect_backend : [nil, nil]
        @chafa_bin = external_tools ? find_executable('chafa') : nil
        @sixel_bin = external_tools ? find_executable('img2sixel') : nil
        @ueberzug_bin = external_tools && @graphics_protocol == :none ? detect_ueberzug : nil
        @ueberzug_io = nil
        @ueberzug_ids = []
        @workers = external_tools && @session && decoder_available? ? start_workers : []
      end

      def decoder_available?
        !@backend.nil? || !@ueberzug_bin.nil? || sixel_ready? || @graphics_protocol == :iterm2
      end

      def kitty_graphics?
        @graphics_protocol == :kitty && !@backend.nil?
      end

      def iterm2_graphics?
        @graphics_protocol == :iterm2
      end

      def sixel_ready?
        @graphics_protocol == :sixel && (!@chafa_bin.nil? || !@sixel_bin.nil?)
      end

      def ueberzug_available?
        !@ueberzug_bin.nil?
      end

      def metadata_for(pin)
        return nil unless pin

        @mutex.synchronize { @metadata[pin[:id].to_s]&.dup }
      end

      def local_file_for(pin, large: true)
        return nil unless pin

        key = "#{pin[:id]}_#{large ? 'lg' : 'sm'}"
        path = @mutex.synchronize { @files[key] || @files["#{pin[:id]}_sm"] }
        path && File.exist?(path) ? path : nil
      end

      def overlay_for(pin, x:, y:, width:, height:, large: false)
        return nil unless pin

        case @graphics_protocol
        when :kitty then kitty_overlay_for(pin, x: x, y: y, width: width, height: height, large: large)
        when :iterm2 then iterm2_overlay_for(pin, x: x, y: y, width: width, height: height, large: large)
        when :sixel then sixel_overlay_for(pin, x: x, y: y, width: width, height: height, large: large)
        end
      end

      def kitty_overlay_for(pin, x:, y:, width:, height:, large: false)
        return nil unless kitty_graphics? && pin

        png_path = @mutex.synchronize { @png_files["#{pin[:id]}_#{large ? 'lg' : 'sm'}"] }
        return nil unless png_path && File.exist?(png_path)

        draw_w, draw_h, off_x, off_y = fit_cell_box(width, height, metadata_for(pin))
        encoded = [png_path].pack('m0')
        "\e[#{y + off_y};#{x + off_x}H\e_Ga=T,f=100,t=f,c=#{draw_w},r=#{draw_h},q=2;#{encoded}\e\\"
      end

      def iterm2_overlay_for(pin, x:, y:, width:, height:, large: false)
        return nil unless iterm2_graphics? && pin

        path = local_file_for(pin, large: large)
        return nil unless path

        draw_w, draw_h, off_x, off_y = fit_cell_box(width, height, metadata_for(pin))
        data = [File.binread(path)].pack('m0')
        "\e[#{y + off_y};#{x + off_x}H\e]1337;File=inline=1;width=#{draw_w};height=#{draw_h};" \
          "preserveAspectRatio=1:#{data}\a"
      rescue StandardError
        nil
      end

      def sixel_overlay_for(pin, x:, y:, width:, height:, large: false)
        return nil unless sixel_ready? && pin

        key = [pin[:id], width, height, large].hash
        sixel = @mutex.synchronize { @sixel_cache[key] }
        return nil unless sixel

        "\e[#{y};#{x}H#{sixel}"
      end

      def ueberzug_placement_for(pin, id:, x:, y:, width:, height:, large: false)
        return nil unless ueberzug_available? && pin

        path = local_file_for(pin, large: large)
        return nil unless path

        draw_w, draw_h, off_x, off_y = fit_cell_box(width, height, metadata_for(pin))
        {
          action: 'add',
          identifier: id,
          x: [x - 1 + off_x, 0].max,
          y: [y - 1 + off_y, 0].max,
          width: draw_w,
          height: draw_h,
          max_width: draw_w,
          max_height: draw_h,
          scaler: 'fit_contain',
          path: path
        }
      end

      def sync_ueberzug(placements)
        return unless ueberzug_available?

        io = ensure_ueberzug_process
        return unless io

        new_ids = placements.map { |p| p[:identifier] }
        (@ueberzug_ids - new_ids).each do |old_id|
          io.puts({ action: 'remove', identifier: old_id }.to_json)
        end
        placements.each { |pl| io.puts(pl.to_json) }
        io.flush
        @ueberzug_ids = new_ids
      rescue StandardError
        close_ueberzug
      end

      def clear_ueberzug
        return unless @ueberzug_io && !@ueberzug_ids.empty?

        @ueberzug_ids.each do |old_id|
          @ueberzug_io.puts({ action: 'remove', identifier: old_id }.to_json)
        end
        @ueberzug_io.flush
        @ueberzug_ids = []
      rescue StandardError
        close_ueberzug
      end

      def render_pin(pin, width:, height:, large: false)
        w = [width.to_i, 4].max
        h = [height.to_i, 2].max
        return @icons.placeholder_canvas(width: w, height: h, label: 'No pin selected') unless pin

        is_video = !pin[:video_url].to_s.empty?
        image_url = pin[:image_url].to_s
        if image_url.empty?
          return @icons.placeholder_canvas(width: w, height: h, label: is_video ? 'Video pin' : 'No preview', video: is_video)
        end

        unless decoder_available? && @session
          label = if @external_tools
                    'Install ueberzugpp/ffmpeg'
                  elsif is_video
                    'Video'
                  else
                    'Image'
                  end
          return @icons.placeholder_canvas(width: w, height: h, label: label, video: is_video)
        end

        return Array.new(h) { @theme.fit('', w) } if native_overlay_ready?(pin, w, h, large: large)

        key = [pin[:id], w, h, large].hash
        cached = @mutex.synchronize { @cache[key] }
        return cached if cached

        failed = @mutex.synchronize { @failed[key] }
        return @icons.placeholder_canvas(width: w, height: h, label: 'Preview error', video: is_video) if failed

        schedule_render(key, pin, w, h, large: large, video: is_video)
        @icons.placeholder_canvas(width: w, height: h, label: 'Loading...', video: is_video)
      end

      def clear_cache
        @mutex.synchronize do
          @cache.clear
          @sixel_cache.clear
          @failed.clear
        end
      end

      def shutdown
        @mutex.synchronize { @running = false }
        @workers.size.times { @job_queue << nil }
        @workers.each { |t| t.join(1.0) }
        close_ueberzug
        FileUtils.rm_rf(@cache_dir) if @cache_dir && Dir.exist?(@cache_dir)
      rescue StandardError
        nil
      end

      private

      def native_overlay_ready?(pin, width, height, large:)
        case @graphics_protocol
        when :kitty
          @mutex.synchronize { !@png_files["#{pin[:id]}_#{large ? 'lg' : 'sm'}"].nil? }
        when :iterm2
          !local_file_for(pin, large: large).nil?
        when :sixel
          sixel_ready? && @mutex.synchronize { @sixel_cache.key?([pin[:id], width, height, large].hash) }
        else
          ueberzug_available? && !local_file_for(pin, large: large).nil?
        end
      end

      def fit_cell_box(box_w, box_h, meta)
        return [box_w, box_h, 0, 0] unless meta && meta[:width].to_i.positive? && meta[:height].to_i.positive?

        cell_ratio = 2.0
        img_ratio = meta[:width].to_f / meta[:height]
        box_pixel_ratio = box_w.to_f / (box_h * cell_ratio)
        if img_ratio > box_pixel_ratio
          draw_w = box_w
          draw_h = [[(box_w / (img_ratio * cell_ratio)).round, 1].max, box_h].min
        else
          draw_h = box_h
          draw_w = [[(box_h * cell_ratio * img_ratio).round, 1].max, box_w].min
        end
        [draw_w, draw_h, (box_w - draw_w) / 2, (box_h - draw_h) / 2]
      end

      def ensure_ueberzug_process
        return @ueberzug_io if @ueberzug_io && !@ueberzug_io.closed?

        args = [@ueberzug_bin, 'layer']
        if File.basename(@ueberzug_bin) == 'ueberzugpp'
          args.concat(['-o', 'x11']) if !ENV['DISPLAY'].to_s.empty? && ENV['WAYLAND_DISPLAY'].to_s.empty?
        else
          args << '--silent'
        end
        @ueberzug_io = IO.popen(args, 'w', err: File::NULL)
      rescue StandardError
        @ueberzug_io = nil
      end

      def close_ueberzug
        return unless @ueberzug_io

        clear_ueberzug
        @ueberzug_io.close unless @ueberzug_io.closed?
      rescue StandardError
        nil
      ensure
        @ueberzug_io = nil
        @ueberzug_ids = []
      end

      def detect_ueberzug
        return nil if ENV['DISPLAY'].to_s.empty? && ENV['WAYLAND_DISPLAY'].to_s.empty?

        find_executable('ueberzugpp') || find_executable('ueberzug')
      end

      def start_workers
        Array.new(WORKER_COUNT) do
          Thread.new do
            Thread.current.report_on_exception = false
            while (job = @job_queue.pop)
              break unless running?

              process_job(job)
            end
          end
        end
      end

      def running?
        @mutex.synchronize { @running }
      end

      def schedule_render(key, pin, width, height, large:, video:)
        enqueue = @mutex.synchronize do
          next false if @pending[key] || @cache.key?(key)

          @pending[key] = true
          true
        end
        return unless enqueue

        @job_queue << { key: key, pin: pin, width: width, height: height, large: large, video: video }
      end

      def process_job(job)
        file_path = fetch_image_file(job[:pin], large: job[:large])
        if file_path
          record_metadata(job[:pin], file_path)
          prepare_native_asset(job, file_path)
        end
        lines = build_job_lines(job, file_path)

        @mutex.synchronize do
          @pending.delete(job[:key])
          if lines
            @cache.shift while @cache.size >= MAX_CACHE_ENTRIES
            @cache[job[:key]] = lines
            @failed.delete(job[:key])
          else
            @failed[job[:key]] = true
          end
        end
        @on_ready&.call
      rescue StandardError
        @mutex.synchronize do
          @pending.delete(job[:key])
          @failed[job[:key]] = true
        end
        @on_ready&.call
      end

      def prepare_native_asset(job, file_path)
        case @graphics_protocol
        when :kitty then prepare_kitty_png(job[:pin], file_path, large: job[:large])
        when :sixel then prepare_sixel(job, file_path)
        end
      end

      def build_job_lines(job, file_path)
        return nil unless file_path
        return Array.new(job[:height]) { @theme.fit('', job[:width]) } if ueberzug_available? || @graphics_protocol != :none

        @backend ? decode_to_lines(file_path, width: job[:width], height: job[:height], video: job[:video]) : nil
      end

      def prepare_sixel(job, file_path)
        return unless sixel_ready?

        out = encode_sixel(file_path, width: job[:width], height: job[:height])
        return unless out

        @mutex.synchronize do
          @sixel_cache.shift while @sixel_cache.size >= MAX_CACHE_ENTRIES
          @sixel_cache[job[:key]] = out
        end
      end

      def encode_sixel(path, width:, height:)
        if @chafa_bin
          out, status = Open3.capture2(
            @chafa_bin, '--format=sixel', '--bg=#0d091a', "--size=#{width}x#{height}", path
          )
          return out if status.success? && !out.empty?
        end
        if @sixel_bin
          out, status = Open3.capture2(@sixel_bin, '-w', (width * 8).to_s, '-h', (height * 16).to_s, path)
          return out if status.success? && !out.empty?
        end
        nil
      rescue StandardError
        nil
      end

      def fetch_image_file(pin, large:)
        cache_key = "#{pin[:id]}_#{large ? 'lg' : 'sm'}"
        existing = @mutex.synchronize { @files[cache_key] }
        return existing if existing && File.exist?(existing) && File.size(existing).positive?

        return nil unless @cache_dir && Dir.exist?(@cache_dir)

        safe_id = pin[:id].to_s.gsub(/[^A-Za-z0-9_-]/, '')
        safe_id = pin[:image_url].to_s.hash.abs.to_s if safe_id.empty?
        ext = File.extname(pin[:image_url].to_s.split('?').first.to_s)
        ext = '.jpg' unless ext.match?(/\A\.(?:jpg|jpeg|png|webp|gif)\z/i)
        dest = File.join(@cache_dir, "#{safe_id}_#{large ? 'lg' : 'sm'}#{ext.downcase}")

        candidate_urls(pin[:image_url].to_s, large: large).each do |url|
          next if url.empty?

          begin
            @session.download(url, path: dest, overwrite: true, resume: false, max_size: MAX_DOWNLOAD_BYTES)
            if File.exist?(dest) && File.size(dest).positive?
              @mutex.synchronize { @files[cache_key] = dest }
              return dest
            end
          rescue StandardError
            next
          end
        end
        nil
      end

      def prepare_kitty_png(pin, src_path, large:)
        key = "#{pin[:id]}_#{large ? 'lg' : 'sm'}"
        return if @mutex.synchronize { @png_files.key?(key) }

        png_dest = "#{src_path}.png"
        if convert_to_png(src_path, png_dest)
          @mutex.synchronize { @png_files[key] = png_dest }
        end
      rescue StandardError
        nil
      end

      def convert_to_png(src_path, dst_path)
        head = File.binread(src_path, 8)
        if head&.start_with?("\x89PNG\r\n\x1A\n".b)
          FileUtils.cp(src_path, dst_path)
          return true
        end

        case @backend
        when :ffmpeg
          _out, status = Open3.capture2e(@backend_bin, '-v', 'error', '-y', '-i', src_path, '-frames:v', '1', dst_path)
          status.success? && File.exist?(dst_path)
        when :magick
          _out, status = Open3.capture2e(@backend_bin, "#{src_path}[0]", dst_path)
          status.success? && File.exist?(dst_path)
        when :python_pil
          script = 'import sys; from PIL import Image; Image.open(sys.argv[1]).convert("RGBA").save(sys.argv[2], "PNG")'
          _out, status = Open3.capture2e(@backend_bin, '-c', script, src_path, dst_path)
          status.success? && File.exist?(dst_path)
        else
          false
        end
      end

      def record_metadata(pin, file_path)
        dims = extract_image_dimensions(file_path)
        bytes = File.size(file_path)
        @mutex.synchronize do
          prev = @metadata[pin[:id].to_s] || {}
          w = dims ? dims[0] : prev[:width]
          h = dims ? dims[1] : prev[:height]
          @metadata[pin[:id].to_s] = { width: w, height: h, bytes: bytes }
        end
      rescue StandardError
        nil
      end

      def extract_image_dimensions(path)
        data = File.binread(path, 65_536)
        return nil if data.nil? || data.bytesize < 24

        return data.byteslice(16, 8).unpack('NN') if data.start_with?("\x89PNG\r\n\x1A\n".b)
        return extract_jpeg_dimensions(data) if data.getbyte(0) == 0xFF && data.getbyte(1) == 0xD8

        nil
      rescue StandardError
        nil
      end

      def extract_jpeg_dimensions(data)
        pos = 2
        while pos + 9 < data.bytesize
          pos += 1 while pos < data.bytesize && data.getbyte(pos) != 0xFF
          pos += 1 while pos < data.bytesize && data.getbyte(pos) == 0xFF
          break if pos + 7 >= data.bytesize

          marker = data.getbyte(pos)
          pos += 1
          len = data.byteslice(pos, 2).unpack1('n')
          break if len < 2

          if [0xC0, 0xC1, 0xC2].include?(marker)
            h, w = data.byteslice(pos + 3, 4).unpack('nn')
            return [w, h] if w.positive? && h.positive?
          end
          pos += len
        end
        nil
      end

      def candidate_urls(url, large:)
        sized = if url.include?('i.pinimg.com/')
                  target = large ? '736x' : '474x'
                  url.sub(%r{/(?:originals|\d+x)/}, "/#{target}/")
                else
                  url
                end
        [sized, url].uniq
      end

      def decode_to_lines(path, width:, height:, video:)
        case @backend
        when :ffmpeg then render_from_rgb(decode_ffmpeg(path, width, height * 2), width, height, video: video)
        when :magick then render_from_rgb(decode_magick(path, width, height * 2), width, height, video: video)
        when :chafa then decode_chafa(path, width, height)
        when :python_pil then render_from_rgb(decode_python_pil(path, width, height * 2), width, height, video: video)
        when :djpeg then render_from_rgb(decode_djpeg(path, width, height * 2), width, height, video: video)
        end
      rescue StandardError
        nil
      end

      def decode_ffmpeg(path, px_w, px_h)
        vf = "scale=#{px_w}:#{px_h}:force_original_aspect_ratio=decrease:flags=lanczos," \
             "pad=#{px_w}:#{px_h}:(ow-iw)/2:(oh-ih)/2:color=#0d091a"
        out, status = Open3.capture2(
          @backend_bin, '-v', 'error', '-i', path,
          '-vf', vf, '-frames:v', '1', '-f', 'rawvideo', '-pix_fmt', 'rgb24', '-',
          binmode: true
        )
        return nil unless status.success? && out.bytesize >= px_w * px_h * 3

        out
      end

      def decode_magick(path, px_w, px_h)
        out, status = Open3.capture2(
          @backend_bin, "#{path}[0]", '-resize', "#{px_w}x#{px_h}",
          '-background', '#0d091a', '-gravity', 'center', '-extent', "#{px_w}x#{px_h}",
          '-colorspace', 'sRGB', '-depth', '8', 'rgb:-',
          binmode: true
        )
        return nil unless status.success? && out.bytesize >= px_w * px_h * 3

        out
      end

      def decode_chafa(path, width, height)
        out, status = Open3.capture2(
          @backend_bin, '--format=symbols', '--symbols=half', '--colors=full',
          '--bg=#0d091a', "--size=#{width}x#{height}", path
        )
        return nil unless status.success? && !out.empty?

        lines = out.lines.map { |l| @theme.fit(l.chomp, width) }.first(height)
        lines << @theme.fit('', width) while lines.size < height
        lines
      end

      def decode_python_pil(path, px_w, px_h)
        script = 'import sys; from PIL import Image, ImageOps; ' \
                 'im = ImageOps.pad(Image.open(sys.argv[1]).convert("RGB"), ' \
                 '(int(sys.argv[2]), int(sys.argv[3])), color=(13, 9, 26)); ' \
                 'sys.stdout.buffer.write(im.tobytes())'
        out, status = Open3.capture2(@backend_bin, '-c', script, path, px_w.to_s, px_h.to_s, binmode: true)
        return nil unless status.success? && out.bytesize >= px_w * px_h * 3

        out
      end

      def decode_djpeg(path, px_w, px_h)
        out, status = Open3.capture2(@backend_bin, '-rgb', path, binmode: true)
        return nil unless status.success? && out.start_with?("P6\n")

        header_match = out.match(/\AP6\s+(?:#[^\n]*\n\s*)*(\d+)\s+(\d+)\s+(\d+)\s/m)
        return nil unless header_match

        src_w = header_match[1].to_i
        src_h = header_match[2].to_i
        offset = header_match.end(0)
        return nil if src_w <= 0 || src_h <= 0 || out.bytesize < offset + (src_w * src_h * 3)

        downsample_rgb_aspect(out, offset, src_w, src_h, px_w, px_h)
      end

      def downsample_rgb_aspect(buf, offset, src_w, src_h, dst_w, dst_h)
        scale = [dst_w.to_f / src_w, dst_h.to_f / src_h].min
        fit_w = [(src_w * scale).round, 1].max
        fit_h = [(src_h * scale).round, 1].max
        pad_x = (dst_w - fit_w) / 2
        pad_y = (dst_h - fit_h) / 2
        bg_pixel = BG_RGB.pack('CCC')

        result = String.new(encoding: Encoding::BINARY, capacity: dst_w * dst_h * 3)
        dst_h.times do |y|
          dst_w.times do |x|
            if x < pad_x || x >= pad_x + fit_w || y < pad_y || y >= pad_y + fit_h
              result << bg_pixel
            else
              sx = ((x - pad_x) * src_w) / fit_w
              sy = ((y - pad_y) * src_h) / fit_h
              pos = offset + (((sy * src_w) + sx) * 3)
              result << buf.byteslice(pos, 3)
            end
          end
        end
        result
      end

      def render_from_rgb(rgb, width, height, video:)
        return nil unless rgb && rgb.bytesize >= width * height * 2 * 3

        stride = width * 3
        Array.new(height) do |row|
          top_off = (row * 2) * stride
          bot_off = ((row * 2) + 1) * stride
          line = +''

          width.times do |x|
            if video && row.zero? && width >= 6 && x >= width - 3
              ch = x == width - 2 ? '▸' : ' '
              line << @theme.paint(ch, color: :white, background: :pink, bold: true)
              next
            end

            t_idx = top_off + (x * 3)
            b_idx = bot_off + (x * 3)
            tr = rgb.getbyte(t_idx)
            tg = rgb.getbyte(t_idx + 1)
            tb = rgb.getbyte(t_idx + 2)
            br = rgb.getbyte(b_idx)
            bg = rgb.getbyte(b_idx + 1)
            bb = rgb.getbyte(b_idx + 2)
            line << "\e[38;2;#{tr};#{tg};#{tb};48;2;#{br};#{bg};#{bb}m▀"
          end
          "#{line}\e[0m"
        end
      end

      def detect_backend
        if (bin = find_executable('ffmpeg'))
          return [:ffmpeg, bin]
        end
        if (bin = find_executable('magick') || find_executable('convert'))
          return [:magick, bin]
        end
        if (bin = find_executable('chafa'))
          return [:chafa, bin]
        end
        if (bin = find_executable('python3')) && python_pil_available?(bin)
          return [:python_pil, bin]
        end
        if (bin = find_executable('djpeg'))
          return [:djpeg, bin]
        end

        [nil, nil]
      end

      def python_pil_available?(python_bin)
        _out, status = Open3.capture2e(python_bin, '-c', 'from PIL import Image')
        status.success?
      rescue StandardError
        false
      end

      def find_executable(name)
        ENV['PATH'].to_s.split(File::PATH_SEPARATOR).each do |dir|
          candidate = File.join(dir, name)
          return candidate if File.executable?(candidate) && !File.directory?(candidate)
        end
        nil
      end
    end
  end
end
