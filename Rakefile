# frozen_string_literal: true

ENV['LANG'] = ENV.fetch('LANG', 'en_US.UTF-8')

require 'bundler/gem_tasks'
require 'rspec/core/rake_task'
require 'rubocop/rake_task'

RSpec::Core::RakeTask.new(:spec)

RuboCop::RakeTask.new(:rubocop) do |task|
  task.options = ['--display-cop-names']
  task.formatters = ['progress']
  task.fail_on_error = true
end

require 'yard'
YARD::Rake::YardocTask.new do |t|
  t.files   = ['lib/**/*.rb', 'bin/**/*']
  t.options = ['--any', '--extra', '--opts'] # optional
  t.stats_options = ['--list-undoc']
end

namespace :sorbet do
  desc 'Run Sorbet type checking exactly as CI does (--typed strong)'
  task :check do
    sh 'srb tc --typed strong'
  end
end

desc 'Run the full CI gate locally: tests, lint, strong type checks, docs, and gem build'
task ci: %i[spec rubocop sorbet:check yard] do
  sh 'yard stats --list-undoc'
  sh 'gem build http_loader.gemspec'
end

desc 'Run tests, linters, and type checking'
task default: %i[spec rubocop sorbet:check]
