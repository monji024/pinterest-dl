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

# step-0
