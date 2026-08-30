# frozen_string_literal: true

# Monji024
require_relative '../test_helper'

class VersionTest < Minitest::Test
  def test_version_is_a_semver_string
    assert_match(/\A\d+\.\d+\.\d+\z/, PinterestDL::VERSION)
  end
end
