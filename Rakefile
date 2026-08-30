# frozen_string_literal: true

# Monji024
require 'rake/testtask'

Rake::TestTask.new(:test) do |t|
  t.libs << 'test' << 'lib'
  t.pattern = 'test/**/*_test.rb'
  t.verbose = true
end

begin
  require 'rubocop/rake_task'
  RuboCop::RakeTask.new(:rubocop)
rescue LoadError
  task(:rubocop) { warn 'rubocop not installed, skipping' }
end

task default: %i[test rubocop]
