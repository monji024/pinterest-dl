# frozen_string_literal: true

# Monji024
require_relative '../test_helper'

class ErrorsTest < Minitest::Test
  def test_all_errors_inherit_from_base_error
    [
      PinterestDL::NetworkError,
      PinterestDL::NotFoundError,
      PinterestDL::RateLimitError,
      PinterestDL::AuthenticationError,
      PinterestDL::InvalidURLError,
      PinterestDL::DownloadError
    ].each do |klass|
      assert klass <= PinterestDL::Error, "#{klass} should inherit from PinterestDL::Error"
      assert klass <= StandardError
    end
  end

  def test_rate_limit_error_carries_retry_after
    error = PinterestDL::RateLimitError.new('slow down', retry_after: '30')
    assert_equal '30', error.retry_after
  end

  def test_network_error_carries_the_original_cause
    original = Timeout::Error.new('boom')
    error = PinterestDL::NetworkError.new('failed', cause_error: original)
    assert_same original, error.cause_error
  end
end
