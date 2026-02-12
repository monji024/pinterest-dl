Gem::Specification.new do |s|
  s.name        = 'pinterest-dl'
  s.version     = '1.0.0'
  s.summary     = 'Extract direct image/video URLs from Pinterest!!!'
  s.description = 'Simple Pinterest Downloader Tool:)'
  s.authors     = ['Monji']
  s.email       = 'hoseinmonjiofficial@gmail.com'
  s.homepage    = 'https://github.com/monji024/pinterest-dl'
  s.license     = 'MIT'

  s.files       = Dir['lib/**/*.rb'] + ['README.md']
  s.require_paths = ['lib']

  s.required_ruby_version = '>= 2.5.0'
  s.metadata = {
    'source_code_uri' => 'https://github.com/monji024/pinterest-dl',
    'bug_tracker_uri' => 'https://github.com/monji024/pinterest-dl/issues'
  }
end