# frozen_string_literal: true

require_relative '../test_helper'
require 'time'

class TransportTest < Minitest::Test
  def setup
    @config = PinterestDL::Configuration.new(allow_local_network: true, retry_wait: 0.01, max_retry_wait: 1.0, max_retries: 2)
    @config.logger.level = Logger::FATAL
    @transport = PinterestDL::Transport.new(config: @config)
  end

  def test_exponential_backoff_with_jitter_scales_and_caps
    d1 = @transport.backoff_delay(1, base_wait: 1.0, max_wait: 10.0, jitter_ratio: 0.2)
    d2 = @transport.backoff_delay(2, base_wait: 1.0, max_wait: 10.0, jitter_ratio: 0.2)
    d3 = @transport.backoff_delay(3, base_wait: 1.0, max_wait: 10.0, jitter_ratio: 0.2)
    d6 = @transport.backoff_delay(6, base_wait: 1.0, max_wait: 10.0, jitter_ratio: 0.2)

    assert_operator d1, :>=, 1.0
    assert_operator d1, :<=, 1.2
    assert_operator d2, :>=, 2.0
    assert_operator d3, :>=, 4.0
    assert_operator d6, :<=, 10.0
  end

  def test_parses_numeric_and_http_date_retry_after
    now = Time.utc(2026, 11, 11, 12, 0, 0)
    assert_in_delta 15.0, @transport.parse_retry_after('15', now: now), 0.001
    assert_in_delta 2.5, @transport.parse_retry_after('2.5', now: now), 0.001

    future_date = (now + 25).httpdate
    assert_in_delta 25.0, @transport.parse_retry_after(future_date, now: now), 0.001

    past_date = (now - 10).httpdate
    assert_in_delta 0.0, @transport.parse_retry_after(past_date, now: now), 0.001
    assert_nil @transport.parse_retry_after('invalid-header', now: now)
  end

  def test_validates_resource_json_and_raises_specific_errors
    valid = '{"resource_response":{"status":"success","data":{"id":"1"}}}'
    parsed = @transport.parse_and_validate_resource_json!(valid, resource_name: 'PinResource')
    assert_equal '1', parsed.dig('resource_response', 'data', 'id')

    assert_raises(PinterestDL::InvalidResponseError) do
      @transport.parse_and_validate_resource_json!('not-json', resource_name: 'PinResource')
    end

    assert_raises(PinterestDL::InvalidResponseError) do
      @transport.parse_and_validate_resource_json!('[1,2,3]', resource_name: 'PinResource')
    end

    forbidden_payload = '{"resource_response":{"http_status":403,"error":{"message":"CSRF failed"}}}'
    assert_raises(PinterestDL::ForbiddenError) do
      @transport.parse_and_validate_resource_json!(forbidden_payload, resource_name: 'BoardResource')
    end

    rate_limit_payload = '{"resource_response":{"http_status":429,"error":{"message":"Too many requests"}}}'
    assert_raises(PinterestDL::RateLimitError) do
      @transport.parse_and_validate_resource_json!(rate_limit_payload, resource_name: 'BaseSearchResource')
    end
  end
end
