# frozen_string_literal: true

require 'rake/testtask'

Rake::TestTask.new(:test) do |t|
  t.libs << 'test' << 'lib'
  t.pattern = 'test/**/*_test.rb'
  t.verbose = true
end

desc 'Run test suite with SimpleCov coverage measurement'
task :coverage do
  ENV['COVERAGE'] = '1'
  Rake::Task['test'].invoke
end

begin
  require 'rubocop/rake_task'
  RuboCop::RakeTask.new(:rubocop)
rescue LoadError
  task(:rubocop) { warn 'rubocop not installed, skipping' }
end

begin
  require 'yard'
  YARD::Rake::YardocTask.new(:yard)
rescue LoadError
  task(:yard) { warn 'yard not installed, skipping' }
end

task default: %i[test rubocop]
