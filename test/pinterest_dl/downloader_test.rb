# frozen_string_literal: true

require_relative '../test_helper'
require 'tmpdir'
require 'socket'

class DownloaderTest < Minitest::Test
  JPEG_DATA = "\xFF\xD8\xFF\xE0\x00\x10JFIF\x00\x01\x01\x00\x00\x01\x00\x01\x00\x00payload".b.freeze

  def test_download_writes_body_to_path
    Dir.mktmpdir do |dir|
      client = FakeClient.new({ /pinimg/ => JPEG_DATA })
      downloader = PinterestDL::Downloader.new(client: client, config: PinterestDL::Configuration.new)

      path = File.join(dir, 'img.jpg')
      downloader.download('https://i.pinimg.com/originals/a.jpg', path: path)

      assert File.exist?(path)
      assert_equal JPEG_DATA, File.binread(path)
    end
  end

  def test_download_batch_reports_successes_and_failures
    Dir.mktmpdir do |dir|
      client = FakeClient.new(
        {
          'https://i.pinimg.com/originals/good.jpg' => JPEG_DATA,
          'https://i.pinimg.com/originals/bad.jpg' => proc { raise 'boom' }
        }
      )
      downloader = PinterestDL::Downloader.new(client: client, config: PinterestDL::Configuration.new)

      progress_calls = []
      result = downloader.download_batch(
        ['https://i.pinimg.com/originals/good.jpg', 'https://i.pinimg.com/originals/bad.jpg'],
        dir: dir
      ) { |done, total, _url| progress_calls << [done, total] }

      assert_kind_of PinterestDL::DownloadReport, result
      assert_equal 1, result[:succeeded].size
      assert_equal 1, result[:failed].size
      assert_equal [[1, 2], [2, 2]], progress_calls
    end
  end

  def test_download_rejects_empty_url_or_path
    downloader = PinterestDL::Downloader.new(client: FakeClient.new, config: PinterestDL::Configuration.new)
    assert_raises(ArgumentError) { downloader.download('', path: 'out.jpg') }
    assert_raises(ArgumentError) { downloader.download('https://i.pinimg.com/originals/a.jpg', path: '  ') }
  end

  def test_download_batch_supports_custom_filename_callable
    Dir.mktmpdir do |dir|
      client = FakeClient.new({ /pinimg/ => JPEG_DATA })
      downloader = PinterestDL::Downloader.new(client: client, config: PinterestDL::Configuration.new)
      res = downloader.download_batch(
        ['https://i.pinimg.com/originals/a.jpg'],
        dir: dir,
        filename: ->(_u, i) { "custom_#{i}.jpg" }
      )
      assert_equal [File.join(dir, 'custom_0.jpg')], res[:succeeded]
    end
  end

  def test_1_resumes_partial_download_when_server_returns_valid_206_content_range
    server = TCPServer.new('127.0.0.1', 0)
    port = server.addr[1]
    full_payload = JPEG_DATA + ('A' * 100).b
    total_len = full_payload.bytesize
    rest = full_payload.byteslice(10..-1)
    seen_range = nil

    thread = Thread.new do
      sock = server.accept
      _req = sock.gets
      while (line = sock.gets) && line != "\r\n"
        seen_range = line.strip if line.downcase.start_with?('range:')
      end
      headers = [
        'HTTP/1.1 206 Partial Content',
        'Content-Type: image/jpeg',
        "Content-Range: bytes 10-#{total_len - 1}/#{total_len}",
        "Content-Length: #{rest.bytesize}",
        'Connection: close'
      ].join("\r\n")
      sock.write "#{headers}\r\n\r\n#{rest}"
      sock.close
    end

    Dir.mktmpdir do |dir|
      config = PinterestDL::Configuration.new(allow_local_network: true, resume: true)
      client = PinterestDL::Client.new(config: config)
      downloader = PinterestDL::Downloader.new(client: client, config: config)

      path = File.join(dir, 'resumed.jpg')
      File.binwrite("#{path}.part", full_payload.byteslice(0, 10))

      downloader.download("http://127.0.0.1:#{port}/img.jpg", path: path, resume: true)
      assert_equal 'Range: bytes=10-', seen_range
      assert_equal full_payload, File.binread(path)
      refute File.exist?("#{path}.part")
    end
  ensure
    thread&.kill
    server&.close
  end

  def test_2_rejects_206_response_missing_content_range
    Dir.mktmpdir do |dir|
      full_payload = JPEG_DATA + ('B' * 50).b
      rest = full_payload.byteslice(10..-1)
      client = FakeClient.new(
        { /pinimg/ => rest },
        raw_headers: {
          /pinimg/ => {
            'status' => '206',
            'content-type' => 'image/jpeg',
            'content-length' => rest.bytesize.to_s
          }
        }
      )
      downloader = PinterestDL::Downloader.new(client: client, config: PinterestDL::Configuration.new(resume: true))

      path = File.join(dir, 'missing_cr.jpg')
      File.binwrite("#{path}.part", full_payload.byteslice(0, 10))

      assert_raises(PinterestDL::InvalidResponseError) do
        downloader.download('https://i.pinimg.com/originals/missing_cr.jpg', path: path, resume: true)
      end
      refute File.exist?(path)
    end
  end

  def test_3_rejects_206_response_with_wrong_start_offset
    Dir.mktmpdir do |dir|
      full_payload = JPEG_DATA + ('C' * 50).b
      total_len = full_payload.bytesize
      wrong_slice = full_payload.byteslice(20..-1)
      client = FakeClient.new(
        { /pinimg/ => wrong_slice },
        raw_headers: {
          /pinimg/ => {
            'status' => '206',
            'content-type' => 'image/jpeg',
            'content-range' => "bytes 20-#{total_len - 1}/#{total_len}",
            'content-length' => wrong_slice.bytesize.to_s
          }
        }
      )
      downloader = PinterestDL::Downloader.new(client: client, config: PinterestDL::Configuration.new(resume: true))

      path = File.join(dir, 'wrong_offset.jpg')
      File.binwrite("#{path}.part", full_payload.byteslice(0, 10))

      assert_raises(PinterestDL::InvalidResponseError) do
        downloader.download('https://i.pinimg.com/originals/wrong_offset.jpg', path: path, resume: true)
      end
      refute File.exist?(path)
    end
  end

  def test_4_rejects_206_response_with_inconsistent_range_length
    Dir.mktmpdir do |dir|
      full_payload = JPEG_DATA + ('D' * 50).b
      total_len = full_payload.bytesize
      short_body = full_payload.byteslice(10, 15)
      client = FakeClient.new(
        { /pinimg/ => short_body },
        raw_headers: {
          /pinimg/ => {
            'status' => '206',
            'content-type' => 'image/jpeg',
            'content-range' => "bytes 10-#{total_len - 1}/#{total_len}"
          }
        }
      )
      downloader = PinterestDL::Downloader.new(client: client, config: PinterestDL::Configuration.new(resume: true))

      path = File.join(dir, 'bad_range_len.jpg')
      File.binwrite("#{path}.part", full_payload.byteslice(0, 10))

      assert_raises(PinterestDL::IncompleteDownloadError) do
        downloader.download('https://i.pinimg.com/originals/bad_range_len.jpg', path: path, resume: true)
      end
      refute File.exist?(path)
    end
  end

  def test_5_restarts_from_beginning_when_server_returns_200_after_range_request
    Dir.mktmpdir do |dir|
      client = FakeClient.new(
        { /pinimg/ => JPEG_DATA },
        raw_headers: {
          /pinimg/ => {
            'status' => '200',
            'content-type' => 'image/jpeg',
            'content-length' => JPEG_DATA.bytesize.to_s
          }
        }
      )
      downloader = PinterestDL::Downloader.new(client: client, config: PinterestDL::Configuration.new(resume: true))

      path = File.join(dir, 'fallback200.jpg')
      File.binwrite("#{path}.part", 'STALE_BYTES_THAT_MUST_NOT_REMAIN'.b)

      downloader.download('https://i.pinimg.com/originals/fallback200.jpg', path: path, resume: true)
      assert_equal 'bytes=32-', client.last_headers['Range']
      assert_equal JPEG_DATA, File.binread(path)
    end
  end

  def test_6_finalizes_download_on_416_when_part_file_is_already_complete
    Dir.mktmpdir do |dir|
      client = FakeClient.new(
        { /pinimg/ => '' },
        raw_headers: {
          /pinimg/ => {
            'status' => '416',
            'content-range' => "bytes */#{JPEG_DATA.bytesize}"
          }
        }
      )
      downloader = PinterestDL::Downloader.new(client: client, config: PinterestDL::Configuration.new(resume: true))

      path = File.join(dir, 'already_done.jpg')
      File.binwrite("#{path}.part", JPEG_DATA)

      downloader.download('https://i.pinimg.com/originals/already_done.jpg', path: path, resume: true)
      assert_equal 1, client.calls.size
      assert File.exist?(path)
      assert_equal JPEG_DATA, File.binread(path)
      refute File.exist?("#{path}.part")
    end
  end

  def test_7_restarts_from_scratch_on_416_when_part_file_is_incomplete
    Dir.mktmpdir do |dir|
      client = FakeClient.new(
        { /pinimg/ => ['', JPEG_DATA] },
        raw_headers: {
          /pinimg/ => [
            { 'status' => '416', 'content-range' => "bytes */#{JPEG_DATA.bytesize}" },
            { 'status' => '200', 'content-type' => 'image/jpeg', 'content-length' => JPEG_DATA.bytesize.to_s }
          ]
        }
      )
      downloader = PinterestDL::Downloader.new(client: client, config: PinterestDL::Configuration.new(resume: true))

      path = File.join(dir, 'incomplete_416.jpg')
      File.binwrite("#{path}.part", JPEG_DATA.byteslice(0, 8))

      downloader.download('https://i.pinimg.com/originals/incomplete_416.jpg', path: path, resume: true)
      assert_equal 2, client.calls.size
      assert_equal 'bytes=8-', client.request_headers_history[0]['Range']
      assert_nil client.request_headers_history[1]['Range']
      assert_equal JPEG_DATA, File.binread(path)
    end
  end

  def test_8_resumes_via_direct_to_part_preserving_previous_part_content
    Dir.mktmpdir do |dir|
      full_payload = JPEG_DATA + ('Z' * 40).b
      total_len = full_payload.bytesize
      rest = full_payload.byteslice(12..-1)
      client = FakeClient.new(
        { /pinimg/ => rest },
        raw_headers: {
          /pinimg/ => {
            'status' => '206',
            'content-type' => 'image/jpeg',
            'content-range' => "bytes 12-#{total_len - 1}/#{total_len}",
            'content-length' => rest.bytesize.to_s
          }
        }
      )
      downloader = PinterestDL::Downloader.new(client: client, config: PinterestDL::Configuration.new(resume: true))

      path = File.join(dir, 'direct_resume.jpg')
      File.binwrite("#{path}.part", full_payload.byteslice(0, 12))

      downloader.download('https://i.pinimg.com/originals/direct_resume.jpg', path: path, resume: true)
      assert_equal 'bytes=12-', client.last_headers['Range']
      assert_equal full_payload, File.binread(path)
    end
  end

  def test_9_enforces_max_size_on_combined_final_size_during_resume
    Dir.mktmpdir do |dir|
      full_payload = JPEG_DATA + ('M' * 80).b
      total_len = full_payload.bytesize
      rest = full_payload.byteslice(60..-1)
      client = FakeClient.new(
        { /pinimg/ => rest },
        raw_headers: {
          /pinimg/ => {
            'status' => '206',
            'content-type' => 'image/jpeg',
            'content-range' => "bytes 60-#{total_len - 1}/#{total_len}",
            'content-length' => rest.bytesize.to_s
          }
        }
      )
      config = PinterestDL::Configuration.new(resume: true, max_file_size: 90)
      downloader = PinterestDL::Downloader.new(client: client, config: config)

      path = File.join(dir, 'max_resume.jpg')
      File.binwrite("#{path}.part", full_payload.byteslice(0, 60))

      err = assert_raises(PinterestDL::FileTooLargeError) do
        downloader.download('https://i.pinimg.com/originals/max_resume.jpg', path: path, resume: true)
      end
      assert_equal 90, err.max_size
      assert_equal total_len, err.actual_size
      refute File.exist?(path)
      refute File.exist?("#{path}.part")
    end
  end

  def test_10_executes_progress_callback_outside_internal_mutex
    server = TCPServer.new('127.0.0.1', 0)
    port = server.addr[1]
    thread = Thread.new do
      loop do
        sock = server.accept
        while (line = sock.gets) && line != "\r\n"; end
        sock.write "HTTP/1.1 200 OK\r\nContent-Type: image/jpeg\r\nContent-Length: #{JPEG_DATA.bytesize}\r\nConnection: close\r\n\r\n#{JPEG_DATA}"
        sock.close
      rescue StandardError
        break
      end
    end

    Dir.mktmpdir do |dir|
      config = PinterestDL::Configuration.new(allow_local_network: true, concurrency: 2)
      client = PinterestDL::Client.new(config: config)
      downloader = PinterestDL::Downloader.new(client: client, config: config)

      barrier = Queue.new
      entered = Queue.new
      callback_calls = 0
      cb_mutex = Mutex.new

      urls = ["http://127.0.0.1:#{port}/1.jpg", "http://127.0.0.1:#{port}/2.jpg"]
      report = downloader.download_batch(urls, dir: dir, concurrency: 2) do |done, _total, _url|
        cb_mutex.synchronize { callback_calls += 1 }
        if done == 1
          entered << true
          Timeout.timeout(2) { barrier.pop }
        else
          entered.pop
          barrier << true
        end
      end

      assert_equal 2, report.succeeded.size
      assert_equal 2, callback_calls
    end
  ensure
    thread&.kill
    server&.close
  end

  def test_11_callback_exception_does_not_corrupt_workers_or_batch_results
    server = TCPServer.new('127.0.0.1', 0)
    port = server.addr[1]
    thread = Thread.new do
      loop do
        sock = server.accept
        while (line = sock.gets) && line != "\r\n"; end
        sock.write "HTTP/1.1 200 OK\r\nContent-Type: image/jpeg\r\nContent-Length: #{JPEG_DATA.bytesize}\r\nConnection: close\r\n\r\n#{JPEG_DATA}"
        sock.close
      rescue StandardError
        break
      end
    end

    Dir.mktmpdir do |dir|
      config = PinterestDL::Configuration.new(allow_local_network: true, concurrency: 2)
      config.logger.level = Logger::FATAL
      client = PinterestDL::Client.new(config: config)
      downloader = PinterestDL::Downloader.new(client: client, config: config)

      urls = Array.new(4) { |i| "http://127.0.0.1:#{port}/item_#{i}.jpg" }
      report = downloader.download_batch(urls, dir: dir, concurrency: 2) do |_done, _total, _url|
        raise StandardError, 'progress UI crashed'
      end

      assert_equal 4, report.succeeded.size
      assert_empty report.failed
    end
  ensure
    thread&.kill
    server&.close
  end

  def test_12_concurrent_workers_avoid_race_conditions_and_rename_colliding_files
    server = TCPServer.new('127.0.0.1', 0)
    port = server.addr[1]
    thread = Thread.new do
      loop do
        sock = server.accept
        while (line = sock.gets) && line != "\r\n"; end
        sock.write "HTTP/1.1 200 OK\r\nContent-Type: image/jpeg\r\nContent-Length: #{JPEG_DATA.bytesize}\r\nConnection: close\r\n\r\n#{JPEG_DATA}"
        sock.close
      rescue StandardError
        break
      end
    end

    Dir.mktmpdir do |dir|
      config = PinterestDL::Configuration.new(allow_local_network: true, concurrency: 4, deduplicate: false, collision_strategy: :rename)
      client = PinterestDL::Client.new(config: config)
      downloader = PinterestDL::Downloader.new(client: client, config: config)

      urls = Array.new(8) { |i| "http://127.0.0.1:#{port}/img_#{i}.jpg" }
      report = downloader.download_batch(
        urls,
        dir: dir,
        concurrency: 4,
        collision_strategy: :rename,
        filename: ->(_u, _i) { 'same_name.jpg' }
      )

      assert_equal 8, report.succeeded.size
      assert_equal 8, report.succeeded.uniq.size
      assert(report.succeeded.all? { |f| File.exist?(f) })
    end
  ensure
    thread&.kill
    server&.close
  end

  def test_13_does_not_deduplicate_urls_with_distinct_meaningful_query_strings
    Dir.mktmpdir do |dir|
      client = FakeClient.new({ /pinimg/ => JPEG_DATA })
      downloader = PinterestDL::Downloader.new(client: client, config: PinterestDL::Configuration.new)

      urls = [
        'https://i.pinimg.com/originals/media.jpg?id=101&variant=a',
        'https://i.pinimg.com/originals/media.jpg?id=102&variant=b'
      ]
      report = downloader.download_batch(urls, dir: dir, deduplicate: true)

      assert_equal 2, report.succeeded.size
      assert_empty report.duplicates
    end
  end

  def test_14_deduplicates_genuinely_identical_urls_and_strips_only_tracking_params
    Dir.mktmpdir do |dir|
      client = FakeClient.new({ /pinimg/ => JPEG_DATA })
      downloader = PinterestDL::Downloader.new(client: client, config: PinterestDL::Configuration.new)

      urls = [
        'https://i.pinimg.com/originals/dup.jpg?id=5&utm_source=share',
        'https://I.PINIMG.COM:443/originals/dup.jpg?utm_medium=social&id=5#section',
        'https://i.pinimg.com/originals/unique.jpg'
      ]
      report = downloader.download_batch(urls, dir: dir, deduplicate: true)

      assert_equal 2, report.succeeded.size
      assert_equal 1, report.duplicates.size
    end
  end

  def test_15_rejects_invalid_collision_strategy_with_argument_error
    Dir.mktmpdir do |dir|
      downloader = PinterestDL::Downloader.new(client: FakeClient.new, config: PinterestDL::Configuration.new)
      assert_raises(ArgumentError) do
        downloader.download_batch(['https://i.pinimg.com/originals/a.jpg'], dir: dir, collision_strategy: :unknown_mode)
      end
      assert_raises(ArgumentError) do
        downloader.download('https://i.pinimg.com/originals/a.jpg', path: File.join(dir, 'a.jpg'), collision_strategy: :bad)
      end
    end
  end

  def test_16_existing_file_behavior_for_rename_skip_and_overwrite_strategies
    new_jpeg = JPEG_DATA + '_NEW_CONTENT'.b
    original_jpeg = JPEG_DATA + '_ORIGINAL'.b

    Dir.mktmpdir do |dir|
      existing = File.join(dir, '0001.jpg')
      File.binwrite(existing, original_jpeg)
      client = FakeClient.new({ /pinimg/ => new_jpeg })
      downloader = PinterestDL::Downloader.new(client: client, config: PinterestDL::Configuration.new)

      skip_report = downloader.download_batch(['https://i.pinimg.com/originals/a.jpg'], dir: dir, collision_strategy: :skip)
      assert_equal [existing], skip_report.skipped
      assert_equal original_jpeg, File.binread(existing)

      rename_report = downloader.download_batch(['https://i.pinimg.com/originals/a.jpg'], dir: dir, collision_strategy: :rename)
      renamed_path = File.join(dir, '0001_1.jpg')
      assert_equal [renamed_path], rename_report.succeeded
      assert_equal original_jpeg, File.binread(existing)
      assert_equal new_jpeg, File.binread(renamed_path)

      overwrite_report = downloader.download_batch(['https://i.pinimg.com/originals/a.jpg'], dir: dir, collision_strategy: :overwrite)
      assert_equal [existing], overwrite_report.succeeded
      assert_equal new_jpeg, File.binread(existing)
    end
  end

  def test_17_failed_download_does_not_corrupt_preexisting_destination_file
    Dir.mktmpdir do |dir|
      existing_path = File.join(dir, 'precious.jpg')
      original_bytes = JPEG_DATA + '_SAFE'.b
      File.binwrite(existing_path, original_bytes)

      client = FakeClient.new(
        { /pinimg/ => '<!DOCTYPE html><html>Error</html>' },
        raw_headers: { /pinimg/ => { 'content-type' => 'text/html' } }
      )
      downloader = PinterestDL::Downloader.new(client: client, config: PinterestDL::Configuration.new)

      assert_raises(PinterestDL::InvalidMediaError) do
        downloader.download('https://i.pinimg.com/originals/bad.jpg', path: existing_path, overwrite: true)
      end

      assert File.exist?(existing_path)
      assert_equal original_bytes, File.binread(existing_path)
    end
  end

  def test_18_cleans_up_temporary_part_files_on_error_conditions
    Dir.mktmpdir do |dir|
      client = FakeClient.new(
        {
          'https://i.pinimg.com/originals/too_big.jpg' => ('x' * 500),
          'https://i.pinimg.com/originals/truncated.jpg' => JPEG_DATA.byteslice(0, 5)
        },
        raw_headers: {
          'https://i.pinimg.com/originals/truncated.jpg' => {
            'content-type' => 'image/jpeg',
            'content-length' => '200'
          }
        }
      )
      small_max_config = PinterestDL::Configuration.new(max_file_size: 100, resume: false)
      small_max_downloader = PinterestDL::Downloader.new(client: client, config: small_max_config)

      assert_raises(PinterestDL::FileTooLargeError) do
        small_max_downloader.download('https://i.pinimg.com/originals/too_big.jpg', path: File.join(dir, 'big.jpg'))
      end

      trunc_config = PinterestDL::Configuration.new(max_file_size: 300, resume: false)
      trunc_downloader = PinterestDL::Downloader.new(client: client, config: trunc_config)

      assert_raises(PinterestDL::IncompleteDownloadError) do
        trunc_downloader.download('https://i.pinimg.com/originals/truncated.jpg', path: File.join(dir, 'trunc.jpg'), resume: false)
      end

      assert_empty Dir.glob(File.join(dir, '*.part*'))
    end
  end

  def test_parses_human_readable_speed_limits
    downloader = PinterestDL::Downloader.new(client: FakeClient.new, config: PinterestDL::Configuration.new)
    assert_equal 512 * 1024, downloader.parse_speed_limit('512K')
    assert_equal 2 * 1024 * 1024, downloader.parse_speed_limit('2MB')
    assert_raises(ArgumentError) { downloader.parse_speed_limit('invalid_speed') }
  end
end
