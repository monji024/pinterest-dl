# frozen_string_literal: true

require 'csv'
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

# step-0
