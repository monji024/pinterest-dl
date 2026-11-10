# frozen_string_literal: true

require_relative '../test_helper'

class SessionTest < Minitest::Test
  def test_sessions_are_isolated_from_global_config_and_each_other
    s1 = PinterestDL.session(quality: :'736x', cookies: 'sessionid=user_one')
    s2 = PinterestDL.session(quality: :'236x', cookies: 'sessionid=user_two')

    assert_equal :'736x', s1.config.quality
    assert_equal :'236x', s2.config.quality
    assert_equal :originals, PinterestDL.config.quality

    assert_equal 'user_one', s1.client.cookie('sessionid', 'https://www.pinterest.com')
    assert_equal 'user_two', s2.client.cookie('sessionid', 'https://www.pinterest.com')
    assert_nil PinterestDL.config.cookies
  end

  def test_mutating_global_config_after_session_creation_does_not_affect_session
    session = PinterestDL.session(open_timeout: 15)
    PinterestDL.configure { |c| c.open_timeout = 99 }

    assert_equal 15, session.config.open_timeout
  ensure
    PinterestDL.reset_config!
  end
end
