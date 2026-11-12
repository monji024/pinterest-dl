# frozen_string_literal: true

require 'fileutils'
require 'json'
require 'optparse'
require 'uri'
require_relative 'version'
require_relative 'errors'
require_relative 'progress_bar'
require_relative 'session'
require_relative 'api'

module PinterestDL
  class CLI
    FORMATS = %i[text json csv quiet].freeze

    def self.run(argv = ARGV, out: $stdout, err: $stderr)
      new(argv, out: out, err: err).run
    end

    def initialize(argv, out: $stdout, err: $stderr)
      @argv = argv.dup
      @out = out
      @err = err
      @options = default_options
    end

    def run
      parse_options!
      return 0 if @early_exit

      command = @argv.shift
      target = @argv.shift

      if command.nil? || target.nil?
        @out.puts usage
        return command.nil? ? 0 : 1
      end

      session = build_session
      dispatch(command, target, session)
    rescue OptionParser::ParseError => e
      print_error("Invalid option: #{e.message}", hint: 'Run `pinterest-dl --help` for usage instructions.')
      1
    rescue Interrupt
      @err.puts "\npinterest-dl: interrupted"
      130
    rescue PinterestDL::Error, ArgumentError => e
      handle_domain_error(e)
      1
    end

    def usage
      <<~USAGE
        pinterest-dl v#{PinterestDL::VERSION}

        Usage:
          pinterest-dl image URL [-q QUALITY] [-o PATH] [options]
          pinterest-dl video URL [-o PATH] [options]
          pinterest-dl media URL [-q QUALITY] [options]
          pinterest-dl search QUERY [-n LIMIT] [-t TYPE] [-q QUALITY] [-j JOBS] [-o DIR] [options]
          pinterest-dl board URL [-n LIMIT] [-t TYPE] [-q QUALITY] [-j JOBS] [-o DIR] [options]

        Options:
          -o, --output PATH          File or directory to save downloaded media (omit to print direct URL)
          -n, --limit N              Max number of results or files to download (default 25)
          -t, --type TYPE            Filter media type: all, image, video, pin (default all)
              --images-only          Shortcut for --type image
              --videos-only          Shortcut for --type video
          -q, --quality Q            Image quality: originals, 1200x, 736x, 564x, 474x, 236x
          -c, --cookies STR|FILE     Cookie header string or Netscape cookies.txt file path
          -j, --jobs N               Parallel download workers for batch downloads (default 4)
          -s, --skip-existing        Skip files that already exist on disk
              --resume               Resume partially downloaded .part files (default true)
              --no-resume            Restart interrupted downloads from scratch
              --max-size BYTES       Maximum allowed file size (e.g. 100M, 500M)
              --max-speed RATE       Throttle download speed per worker (e.g. 500K, 2M)
              --format FMT           Output report format: text, json, csv, quiet (default text)
              --json                 Output results and summary in JSON format
              --no-progress          Disable live progress bar output
              --non-interactive      Run without interactive terminal animations or prompts
              --proxy URL            HTTP/HTTPS proxy URL
              --timeout SEC          Network read/open timeout in seconds
              --retries N            Max retries on transient failures (default 3)
          -v, --verbose              Enable debug logging
              --version              Print version and exit
          -h, --help                 Show this help
      USAGE
    end

    private

    def default_options
      {
        limit: 25,
        quality: :originals,
        type: :all,
        jobs: 4,
        skip_existing: false,
        resume: true,
        progress: true,
        non_interactive: false,
        format: :text,
        verbose: false
      }
    end

    def parse_options!
      parser = OptionParser.new do |opts|
        opts.on('-o PATH', '--output PATH') { |v| @options[:output] = v }
        opts.on('-n N', '--limit N', Integer) { |v| @options[:limit] = v }
        opts.on('-t T', '--type T') { |v| @options[:type] = v.to_sym }
        opts.on('--images-only') { @options[:type] = :image }
        opts.on('--videos-only') { @options[:type] = :video }
        opts.on('-q Q', '--quality Q') { |v| @options[:quality] = v.to_sym }
        opts.on('-c STR', '--cookies STR') { |v| @options[:cookies] = v }
        opts.on('-j N', '--jobs N', Integer) { |v| @options[:jobs] = v }
        opts.on('-s', '--skip-existing') { @options[:skip_existing] = true }
        opts.on('--[no-]resume') { |v| @options[:resume] = v }
        opts.on('--max-size SIZE') { |v| @options[:max_size] = parse_byte_size(v) }
        opts.on('--max-speed RATE') { |v| @options[:max_speed] = v }
        opts.on('--format FMT') { |v| @options[:format] = parse_format(v) }
        opts.on('--json') { @options[:format] = :json }
        opts.on('--quiet') { @options[:format] = :quiet }
        opts.on('--no-progress') { @options[:progress] = false }
        opts.on('--non-interactive') do
          @options[:non_interactive] = true
          @options[:progress] = false
        end
        opts.on('--proxy URL') { |v| @options[:proxy] = v }
        opts.on('--timeout SEC', Integer) { |v| @options[:timeout] = v }
        opts.on('--retries N', Integer) { |v| @options[:retries] = v }
        opts.on('-v', '--verbose') { @options[:verbose] = true }
        opts.on('--version') do
          @out.puts PinterestDL::VERSION
          @early_exit = true
        end
        opts.on('-h', '--help') do
          @out.puts usage
          @early_exit = true
        end
      end
      parser.parse!(@argv)
    end

    def parse_format(val)
      sym = val.to_s.strip.downcase.to_sym
      raise OptionParser::InvalidArgument, "format must be one of: #{FORMATS.join(', ')}" unless FORMATS.include?(sym)

      sym
    end

    def parse_byte_size(val)
      str = val.to_s.strip.downcase
      match = str.match(/\A(\d+(?:\.\d+)?)\s*(b|k|kb|m|mb|g|gb)?\z/)
      raise OptionParser::InvalidArgument, "invalid size #{val.inspect}" unless match

      mult = Downloader::SPEED_MULTIPLIERS.fetch(match[2].to_s, 1)
      (match[1].to_f * mult).to_i
    end

    def build_session
      Session.new do |c|
        c.cookies = @options[:cookies] if @options[:cookies]
        c.quality = @options[:quality] if @options[:quality]
        c.concurrency = @options[:jobs] if @options[:jobs]
        c.overwrite = !@options[:skip_existing]
        c.resume = @options[:resume]
        c.progress = show_progress?
        c.max_file_size = @options[:max_size] if @options[:max_size]
        c.max_speed = @options[:max_speed] if @options[:max_speed]
        c.proxy = @options[:proxy] if @options[:proxy]
        if @options[:timeout]
          c.open_timeout = @options[:timeout]
          c.read_timeout = @options[:timeout]
        end
        c.max_retries = @options[:retries] if @options[:retries]
        c.logger.level = Logger::DEBUG if @options[:verbose]
      end
    end

    def dispatch(command, target, session)
      case command
      when 'image'
        run_single_media(session, target, media_kind: :image)
      when 'video'
        run_single_media(session, target, media_kind: :video)
      when 'media'
        media = session.get_media(target, quality: @options[:quality])
        emit_media_info(media)
        0
      when 'search'
        pins = session.search(target, limit: @options[:limit], type: @options[:type])
        handle_pins(session, pins)
      when 'board'
        pins = session.board(target, limit: @options[:limit], type: @options[:type])
        handle_pins(session, pins)
      else
        print_error("Unknown command '#{command}'", hint: 'Valid commands are: image, video, media, search, board')
        1
      end
    end

    def run_single_media(session, target, media_kind:)
      url = media_kind == :image ? session.get_image_url(target, quality: @options[:quality]) : session.get_video_url(target)
      unless @options[:output]
        if @options[:format] == :json
          @out.puts JSON.pretty_generate({ type: media_kind, url: url })
        elsif @options[:format] != :quiet
          @out.puts url
        end
        return 0
      end

      dest_path = resolve_single_output_path(url, @options[:output], media_kind: media_kind)
      label = File.basename(dest_path)
      bar = build_byte_progress_bar(label: label, media_type: media_kind)
      started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      session.download(
        url,
        path: dest_path,
        overwrite: !@options[:skip_existing],
        resume: @options[:resume],
        progress_bar: bar
      )
      elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started
      emit_single_download_result(url, dest_path, media_kind, elapsed: elapsed)
      0
    end

    def resolve_single_output_path(url, explicit_output, media_kind:)
      default_ext = media_kind == :video ? '.mp4' : '.jpg'
      basename = extract_url_basename(url)
      basename = "pinterest_#{media_kind}#{default_ext}" if basename.empty? || !basename.include?('.')

      out_str = explicit_output.to_s.strip
      if File.directory?(out_str) || out_str.end_with?('/', '\\') || out_str == '.'
        File.join(out_str, basename)
      else
        out_str
      end
    end

    def handle_pins(session, pins)
      if pins.empty?
        if @options[:format] == :json
          @out.puts JSON.pretty_generate({ pins: [], count: 0 })
        else
          @err.puts 'No matching pins found' unless @options[:format] == :quiet
        end
        return 0
      end

      if @options[:type] == :pin
        handle_pin_links(pins)
      elsif @options[:output]
        handle_batch_download(session, pins)
      else
        emit_pins_output(pins)
      end
    end

    def handle_pin_links(pins)
      links = pins.map { |p| p[:pin_url] }
      if @options[:output]
        FileUtils.mkdir_p(@options[:output])
        out_file = File.join(@options[:output], 'pins.txt')
        File.write(out_file, "#{links.join("\n")}\n")
        if @options[:format] == :json
          @out.puts JSON.pretty_generate({ saved: links.size, path: out_file, links: links })
        elsif @options[:format] != :quiet
          @out.puts "Saved #{links.size} pin links to #{out_file}"
        end
      elsif @options[:format] == :json
        @out.puts JSON.pretty_generate(links)
      elsif @options[:format] != :quiet
        @out.puts links
      end
      0
    end

    def handle_batch_download(session, pins)
      selected = pins.first(@options[:limit])
      items = selected.select do |p|
        @options[:type] == :image ? p[:image_url] : (p[:video_url] || p[:image_url])
      end

      bar = ProgressBar.new(total: items.size, out: @err, enabled: show_progress?)
      report = session.download_batch(
        items,
        dir: @options[:output],
        concurrency: @options[:jobs],
        overwrite: !@options[:skip_existing],
        resume: @options[:resume]
      ) do |done, _total, url|
        kind = url.to_s.include?('.mp4') ? :video : :image
        name = extract_url_basename(url)
        bar.update(done, label: name, media_type: kind)
      end

      emit_batch_summary(report, items.size)
      report[:succeeded].empty? && report[:failed].any? ? 1 : 0
    end

    def emit_single_download_result(url, path, media_kind, elapsed: 0.0)
      size = File.exist?(path) ? File.size(path) : 0
      case @options[:format]
      when :json
        @out.puts JSON.pretty_generate({
                                         status: 'saved',
                                         type: media_kind,
                                         url: url,
                                         path: path,
                                         bytes: size,
                                         elapsed_seconds: elapsed.round(2)
                                       })
      when :csv
        @out.puts csv_line([media_kind, url, path, size])
      when :text
        badge = "[#{media_kind.to_s.upcase}]"
        @out.puts "#{badge} Saved to #{path} (#{ProgressBar.format_bytes(size)} in #{elapsed.round(2)}s)"
      end
    end

    def emit_media_info(media)
      case @options[:format]
      when :csv
        @out.puts csv_line(%w[image_url video_url])
        @out.puts csv_line([media[:image_url], media[:video_url]])
      when :quiet
        nil
      else
        @out.puts JSON.pretty_generate(media)
      end
    end

    def emit_pins_output(pins)
      case @options[:format]
      when :csv
        @out.puts csv_line(%w[id pin_url title creator image_url video_url])
        pins.each do |p|
          @out.puts csv_line([p[:id], p[:pin_url], p[:title], p[:creator], p[:image_url], p[:video_url]])
        end
      when :quiet
        nil
      else
        @out.puts JSON.pretty_generate(pins)
      end
      0
    end

    def emit_batch_summary(report, total_requested)
      case @options[:format]
      when :json
        @out.puts report.to_json
      when :csv
        @out.puts csv_line(%w[succeeded skipped failed bytes_downloaded elapsed_seconds])
        row = [
          report[:succeeded].size,
          report[:skipped].size,
          report[:failed].size,
          report.bytes_downloaded,
          report.elapsed_seconds.round(2)
        ]
        @out.puts csv_line(row)
      when :text
        skipped_msg = report[:skipped]&.any? ? " (#{report[:skipped].size} skipped)" : ''
        failed_msg = report[:failed]&.any? ? ", #{report[:failed].size} failed" : ''
        bytes_str = ProgressBar.format_bytes(report.bytes_downloaded)
        size_msg = report.bytes_downloaded.positive? ? " [#{bytes_str} in #{report.elapsed_seconds.round(1)}s]" : ''
        summary = "Downloaded #{report[:succeeded].size}/#{total_requested} files to #{@options[:output]}"
        @out.puts "#{summary}#{skipped_msg}#{failed_msg}#{size_msg}"
      end
    end

    def build_byte_progress_bar(label:, media_type:)
      ProgressBar.new(
        total: 0,
        width: 20,
        out: @err,
        enabled: show_progress?,
        label: label,
        media_type: media_type,
        byte_mode: true
      )
    end

    def show_progress?
      @options[:progress] && !@options[:non_interactive] && @options[:format] != :json && @options[:format] != :quiet
    end

    def csv_line(fields)
      row = fields.map do |field|
        str = field.to_s
        str.match?(/[,"\r\n]/) ? "\"#{str.gsub('"', '""')}\"" : str
      end.join(',')
      "#{row}\n"
    end

    def extract_url_basename(url)
      File.basename(URI(url.to_s).path.to_s)
    rescue URI::InvalidURIError
      ''
    end

    def handle_domain_error(err)
      hint = case err
             when AuthenticationError
               'Pass a logged-in session cookie with `-c cookies.txt` or `-c "sessionid=..."`.'
             when ForbiddenError
               'Pinterest rejected the request (HTTP 403). Check your cookies or try a different IP/proxy.'
             when RateLimitError
               wait_hint = err.retry_after ? " Wait #{err.retry_after}s or" : ''
               "Rate limit reached (HTTP 429).#{wait_hint} reduce `-j/--jobs`."
             when TimeoutError
               'Increase timeout with `--timeout 30` or configure a proxy with `--proxy`.'
             when SSRFError, InvalidURLError
               'Provide a valid public Pinterest URL (e.g. https://www.pinterest.com/pin/...).'
             when FileTooLargeError
               'Increase the maximum allowed file size with `--max-size 1G`.'
             when DiskSpaceError
               'Check available disk space and write permissions on the output path.'
             end
      print_error(err.message, hint: hint)
    end

    def print_error(message, hint: nil)
      if @options[:format] == :json
        @err.puts JSON.generate({ error: message, hint: hint }.compact)
      else
        @err.puts "pinterest-dl: #{message}"
        @err.puts "  Hint: #{hint}" if hint
      end
    end
  end
end
