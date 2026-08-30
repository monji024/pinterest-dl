# frozen_string_literal: true

# Monji024
require_relative '../test_helper'
require 'tmpdir'

class DownloaderTest < Minitest::Test
  def test_download_writes_body_to_path
    Dir.mktmpdir do |dir|
      client = FakeClient.new({ /pinimg/ => 'binarydata' })
      downloader = PinterestDL::Downloader.new(client: client, config: PinterestDL::Configuration.new)

      path = File.join(dir, 'img.jpg')
      downloader.download('https://i.pinimg.com/originals/a.jpg', path: path)

      assert File.exist?(path)
      assert_equal 'binarydata', File.read(path)
    end
  end

  def test_download_batch_reports_successes_and_failures
    Dir.mktmpdir do |dir|
      client = FakeClient.new(
        {
          'https://i.pinimg.com/originals/good.jpg' => 'ok',
          'https://i.pinimg.com/originals/bad.jpg' => proc { raise 'boom' }
        }
      )
      downloader = PinterestDL::Downloader.new(client: client, config: PinterestDL::Configuration.new)

      progress_calls = []
      result = downloader.download_batch(
        ['https://i.pinimg.com/originals/good.jpg', 'https://i.pinimg.com/originals/bad.jpg'],
        dir: dir
      ) { |done, total, _url| progress_calls << [done, total] }

      assert_equal 1, result[:succeeded].size
      assert_equal 1, result[:failed].size
      assert_equal [[1, 2], [2, 2]], progress_calls
    end
  end
end
