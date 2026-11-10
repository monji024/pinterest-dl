# frozen_string_literal: true

require_relative '../test_helper'
require 'stringio'

class ConfigurationTest < Minitest::Test
  def setup
    @config = PinterestDL::Configuration.new
  end

  def test_has_sane_defaults
    assert_equal :originals, @config.quality
    assert_equal 10, @config.open_timeout
    assert_equal 20, @config.read_timeout
    assert_equal 3, @config.max_retries
    assert_equal 500 * 1024 * 1024, @config.max_file_size
    assert @config.verify_content_type
    assert @config.progress
    assert @config.resume
    refute @config.authenticated?
  end

  def test_authenticated_is_true_once_cookies_are_set
    @config.cookies = 'sessionid=abc123'
    assert @config.authenticated?
  end

  def test_rejects_invalid_quality
    assert_raises(ArgumentError) { @config.quality = :huge }
  end

  def test_accepts_valid_quality_as_string_or_symbol
    @config.quality = '736x'
    assert_equal :'736x', @config.quality
  end

  def test_pinterestdl_configure_yields_the_shared_config
    PinterestDL.configure { |c| c.cookies = 'test_cookie=1' }
    assert PinterestDL.config.authenticated?
  ensure
    PinterestDL.config.cookies = nil
  end

  def test_reset_restores_defaults_and_ignores_blank_cookies
    @config.cookies = '   '
    refute @config.authenticated?
    @config.quality = :'736x'
    @config.reset!
    assert_equal :originals, @config.quality
  end

  def test_logger_redacts_sensitive_cookies_and_tokens
    io = StringIO.new
    @config.logger = Logger.new(io)
    @config.logger.level = Logger::INFO
    @config.logger.info('Sending Cookie: sessionid=mysecret999; csrftoken=csrf777')

    refute_includes io.string, 'mysecret999'
    refute_includes io.string, 'csrf777'
    assert_includes io.string, '[REDACTED]'
  end
end
