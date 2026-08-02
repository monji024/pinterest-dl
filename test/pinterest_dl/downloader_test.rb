# frozen_string_literal: true


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

# step-0
