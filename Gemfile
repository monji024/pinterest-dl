# frozen_string_literal: true

source 'https://rubygems.org'

gemspec

group :development, :test do
  gem 'logger'
  gem 'minitest', (RUBY_VERSION < '3.1' ? '~> 5.25.0' : '~> 5.20')
  gem 'rake', '~> 13.0'
  gem 'rubocop', (RUBY_VERSION < '3.1' ? '~> 1.69.0' : '~> 1.60')
  gem 'simplecov', '~> 0.22', require: false
  gem 'yard', '~> 0.9', require: false
end
