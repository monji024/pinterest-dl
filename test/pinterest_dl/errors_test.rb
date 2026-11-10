# frozen_string_literal: true

require_relative '../test_helper'

class ErrorsTest < Minitest::Test
  def test_all_errors_inherit_from_base_error
    [
      PinterestDL::ConfigurationError,
      PinterestDL::NetworkError,
      PinterestDL::TimeoutError,
      PinterestDL::ConnectionError,
      PinterestDL::SSLError,
      PinterestDL::RedirectError,
      PinterestDL::HTTPError,
      PinterestDL::NotFoundError,
      PinterestDL::RateLimitError,
      PinterestDL::RangeNotSatisfiableError,
      PinterestDL::AuthenticationError,
      PinterestDL::ForbiddenError,
      PinterestDL::ServerError,
      PinterestDL::ValidationError,
      PinterestDL::InvalidURLError,
      PinterestDL::SSRFError,
      PinterestDL::InvalidResponseError,
      PinterestDL::DownloadError,
      PinterestDL::FileTooLargeError,
      PinterestDL::IncompleteDownloadError,
      PinterestDL::InvalidMediaError,
      PinterestDL::DiskSpaceError
    ].each do |klass|
      assert klass <= PinterestDL::Error, "#{klass} should inherit from PinterestDL::Error"
      assert klass <= StandardError
    end
  end

  def test_rate_limit_error_carries_retry_after_and_status_code
    error = PinterestDL::RateLimitError.new('slow down', retry_after: '30')
    assert_equal '30', error.retry_after
    assert_equal 429, error.status_code
  end

  def test_range_not_satisfiable_error_carries_content_range_and_status_416
    error = PinterestDL::RangeNotSatisfiableError.new('bad range', content_range: 'bytes */1024')
    assert_equal 'bytes */1024', error.content_range
    assert_equal 416, error.status_code
  end

  def test_forbidden_error_is_distinct_from_rate_limit_error
    error = PinterestDL::ForbiddenError.new('blocked')
    assert_equal 403, error.status_code
    refute_kind_of PinterestDL::RateLimitError, error
  end

  def test_network_error_carries_the_original_cause
    original = Timeout::Error.new('boom')
    error = PinterestDL::NetworkError.new('failed', cause_error: original)
    assert_same original, error.cause_error
  end
end
