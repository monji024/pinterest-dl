# frozen_string_literal: true


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


# step-0
