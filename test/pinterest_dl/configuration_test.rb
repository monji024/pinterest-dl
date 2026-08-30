# frozen_string_literal: true

# Monji024
require_relative '../test_helper'

class ConfigurationTest < Minitest::Test
  def setup
    @config = PinterestDL::Configuration.new
  end

  def test_has_sane_defaults
    assert_equal :originals, @config.quality
    assert_equal 10, @config.open_timeout
    assert_equal 20, @config.read_timeout
    assert_equal 3, @config.max_retries
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
end
