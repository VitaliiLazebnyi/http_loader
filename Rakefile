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

namespace :sorbet do
  desc 'Run Sorbet type checking'
  task :check do
    sh 'srb tc'
  end
end

desc 'Run tests, linters, and type checking'
task default: %i[spec rubocop sorbet:check]
