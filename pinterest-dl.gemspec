# frozen_string_literal: true

# Monji024
require_relative 'lib/pinterest_dl/version'

Gem::Specification.new do |s|
  s.name        = 'pinterest-dl'
  s.version     = PinterestDL::VERSION
  s.summary     = 'Extract direct image/video URLs, search, and download from Pinterest'
  s.description = 'A Ruby toolkit for getting direct image and video URLs from Pinterest pins, ' \
                  'searching pins, fetching board contents, and downloading media to disk — ' \
                  'as a library or a CLI.'
  s.authors     = ['Monji']
  s.email       = 'hoseinmonjiofficial@gmail.com'
  s.homepage    = 'https://github.com/monji024/pinterest-dl'
  s.license     = 'WTFPL'

  s.files       = Dir['lib/**/*.rb'] + Dir['bin/*'] + ['README.md', 'LICENSE', 'CHANGELOG.md']
  s.executables = ['pinterest-dl']
  s.require_paths = ['lib']

  s.required_ruby_version = '>= 2.7.0'

  s.metadata = {
    'source_code_uri' => 'https://github.com/monji024/pinterest-dl',
    'bug_tracker_uri' => 'https://github.com/monji024/pinterest-dl/issues',
    'changelog_uri' => 'https://github.com/monji024/pinterest-dl/blob/main/CHANGELOG.md',
    'rubygems_mfa_required' => 'true',
    'documentation_uri' => 'https://rubydoc.info/gems/pinterest-dl'
  }
end
