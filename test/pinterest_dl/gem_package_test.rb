# frozen_string_literal: true

require_relative '../test_helper'

class GemPackageTest < Minitest::Test
  def test_gemspec_is_valid_and_has_zero_runtime_dependencies
    gemspec_path = File.expand_path('../../pinterest-dl.gemspec', __dir__)
    spec = Gem::Specification.load(gemspec_path)

    refute_nil spec
    assert_equal 'pinterest-dl', spec.name
    assert_equal PinterestDL::VERSION, spec.version.to_s
    assert_empty spec.runtime_dependencies
    assert_includes spec.executables, 'pinterest-dl'
    assert(spec.files.all? { |f| File.exist?(File.expand_path("../../#{f}", __dir__)) })
  end
end
