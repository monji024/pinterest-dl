# frozen_string_literal: true

require_relative '../../test_helper'
require 'tmpdir'
require 'pinterest_dl/tui'

class TUIDownloadQueueTest < Minitest::Test
  class StubSession
    attr_reader :downloads

    def initialize(behavior: nil)
      @behavior = behavior
      @downloads = []
    end

    def config
      @config ||= PinterestDL::Configuration.new
    end

    def download(url, path:, **options, &progress)
      @downloads << { url: url, path: path, options: options }
      if @behavior
        @behavior.call(url, path, progress)
      else
        progress&.call({ received: 50, total: 100, speed: 50.0, url: url })
        File.binwrite(path, 'DATA' * 25)
        progress&.call({ received: 100, total: 100, speed: 100.0, url: url })
      end
      path
    end
  end

  def wait_until(timeout: 2.0)
    deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + timeout
    until yield
      raise 'Timed out waiting for queue state' if Process.clock_gettime(Process::CLOCK_MONOTONIC) > deadline

      sleep(0.01)
    end
  end

  def test_enqueues_and_completes_real_session_download
    Dir.mktmpdir do |dir|
      session = StubSession.new
      queue = PinterestDL::TUI::DownloadQueue.new(session: session, output_dir: dir)
      pin = { id: '101', title: 'Sakura Night', image_url: 'https://i.pinimg.com/736x/aa/bb/neon.jpg', video_url: nil }

      item = queue.enqueue(pin, quality: :originals)
      wait_until { queue.completed_count == 1 }

      finished = queue.items.find { |i| i.id == item.id }
      assert_equal :completed, finished.status
      assert_equal 'sakura_night_101.jpg', finished.filename
      assert_equal 100, finished.percent
      assert_equal 'https://i.pinimg.com/originals/aa/bb/neon.jpg', session.downloads.first[:url]
      assert File.exist?(finished.dest_path)
    ensure
      queue&.shutdown
    end
  end

  def test_records_errors_and_retries_on_resume
    Dir.mktmpdir do |dir|
      attempts = 0
      session = StubSession.new(behavior: lambda do |_url, path, _progress|
        attempts += 1
        raise PinterestDL::NetworkError, 'connection reset' if attempts == 1

        File.binwrite(path, 'RECOVERED')
      end)

      queue = PinterestDL::TUI::DownloadQueue.new(session: session, output_dir: dir)
      pin = { id: '202', title: 'Neon City', image_url: nil, video_url: 'https://v1.pinimg.com/videos/mc/720p/clip.mp4' }

      item = queue.enqueue(pin, video_quality: :'480p')
      wait_until { queue.failed_count == 1 }

      assert_equal :failed, queue.items.first.status
      assert_includes queue.items.first.error_message, 'connection reset'
      assert_equal 'https://v1.pinimg.com/videos/mc/480p/clip.mp4', session.downloads.first[:url]

      assert queue.resume(item.id)
      wait_until { queue.completed_count == 1 }
      assert_equal :completed, queue.items.first.status
    ensure
      queue&.shutdown
    end
  end

  def test_remove_cancels_active_transfer_and_cleans_part_file
    Dir.mktmpdir do |dir|
      gate = Queue.new
      started = Queue.new
      session = StubSession.new(behavior: lambda do |_url, path, progress|
        File.binwrite("#{path}.part", 'PARTIAL')
        started << true
        gate.pop
        progress&.call({ received: 7, total: 100, speed: 10.0 })
      end)

      queue = PinterestDL::TUI::DownloadQueue.new(session: session, output_dir: dir)
      pin = { id: '303', title: 'Slow Pin', image_url: 'https://i.pinimg.com/originals/slow.jpg', video_url: nil }

      item = queue.enqueue(pin)
      started.pop
      assert queue.remove(item.id)
      gate << true

      assert_empty queue.items
      refute File.exist?("#{item.dest_path}.part")
    ensure
      queue&.shutdown
    end
  end
end
