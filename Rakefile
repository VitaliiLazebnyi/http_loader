# frozen_string_literal: true

# Copyright (c) 2026 Vitalii Lazebnyi

require 'bundler/gem_tasks'
require 'open3'
require 'rspec/core/rake_task'
require 'sorbet-runtime'
require 'tmpdir'

# Output of `yard stats` when every API object, public or private, is documented.
FULLY_DOCUMENTED = '100.00% documented'
# The Ruby code that the smell, duplication, complexity and dead-code checks analyze: the gem and its tooling.
ANALYZED = %w[lib bin/http_loader script script/scorecard_check Rakefile].freeze
# Flay mass threshold. Below 24, Flay reports the identical Sorbet signatures of the three heartbeat methods of
# HttpSession (same four typed parameters) and the two sibling numeric validators of Client::Config; from 24 up it
# reports every duplicated piece of logic, and the code must score 0.
FLAY_MASS = 24
# Flog score above which a single method counts as too complex and must be split up (the most complex method of
# lib/ scores just below it).
FLOG_METHOD_THRESHOLD = 25
# Methods debride cannot see a caller for, each with the caller it cannot see.
DEBRIDE_ALLOWED = { VERSION: 'read by http_loader.gemspec' }.freeze

# Helpers of the tasks below.
module Tasks
  extend T::Sig

  # Runs a report command, prints its output (standard output and error), and returns it; fails when the command
  # fails.
  #
  # @param command [Array<String>] the command and its arguments
  # @return [String] the output
  sig { params(command: String).returns(String) }
  def self.report(*command)
    output, status = Open3.capture2e(*command)
    puts(output)
    abort("#{command.join(' ')} failed (#{status})") unless status.success?
    output
  end
end

RSpec::Core::RakeTask.new(:spec)

desc 'Run RuboCop with every cop of every plugin'
task :rubocop do
  sh 'bundle exec rubocop'
end

desc 'Fail on inline suppressions of any linter, scanner, type checker, warning or test'
task :suppressions do
  sh 'script/forbidden_suppressions.sh'
end

desc 'Generate the gem RBIs with Tapioca, then run the Sorbet type checker over lib/, spec/ and script/'
task :typecheck do
  # Tapioca runs from its own bundle. Under `bundle exec rake` the environment belongs to the main bundle, so the
  # nested commands run in an unbundled environment. BUNDLE_DEPLOYMENT/FROZEN are forced off: the typecheck bundle
  # has no committed lockfile (it is generated here), which deployment mode refuses.
  nested = 'env BUNDLE_GEMFILE=typecheck.gemfile BUNDLE_DEPLOYMENT=false BUNDLE_FROZEN=false'
  Bundler.with_unbundled_env do
    sh "#{nested} bundle install --quiet"
    sh "#{nested} bundle exec tapioca gem"
  end
  # Tapioca already merges the RBIs that gems ship themselves into the generated ones; srb must not load them again.
  sh 'env SRB_SKIP_GEM_RBIS=1 bundle exec srb tc'
end

desc 'Fail unless every API object, public or private, is documented, with no YARD warning'
task :yard do
  output = Tasks.report('bundle', 'exec', 'yard', 'stats', '--list-undoc')
  abort 'YARD: undocumented API objects found' unless output.include?(FULLY_DOCUMENTED)
  abort 'YARD: warnings found' if output.match?(/\[warn\]|warning/i)
end

desc 'Fail on any code smell (configured Reek detectors, see .reek.yml)'
task :reek do
  sh('bundle', 'exec', 'reek', *ANALYZED)
end

desc 'Fail on any structural duplication'
task :flay do
  output = Tasks.report('bundle', 'exec', 'flay', '--mass', FLAY_MASS.to_s, *ANALYZED)
  abort 'Flay: duplicated code found' unless output.start_with?('Total score (lower is better) = 0')
end

desc "Fail on any method with a Flog score above #{FLOG_METHOD_THRESHOLD}"
task :flog do
  scores = Tasks.report('bundle', 'exec', 'flog', '--all', '--methods-only', *ANALYZED)
    .scan(/^ *(\d+\.\d+): (\S+) +\S+:\d+/)
  complex = scores.filter_map { |score, name| name if Float(score) > FLOG_METHOD_THRESHOLD }
  abort "Flog: methods scoring above #{FLOG_METHOD_THRESHOLD}: #{complex.join(', ')}" unless complex.empty?
end

desc 'Fail on any method nothing calls (Debride; see DEBRIDE_ALLOWED)'
task :debride do
  Dir.mktmpdir('debride') do |directory|
    allowed = File.join(directory, 'allowed.txt')
    File.write(allowed, DEBRIDE_ALLOWED.keys.join("\n"))
    output = Tasks.report('bundle', 'exec', 'debride', '--whitelist', allowed, *ANALYZED, 'http_loader.gemspec')
    abort 'Debride: methods without a caller found' unless output.include?('Total suspect LOC: 0')
  end
end

desc 'Audit gem dependencies for known vulnerabilities'
task :audit do
  sh 'bundle exec bundler-audit check --update'
end

desc 'Fail on outdated gems that are not on the documented hold list'
task :outdated do
  ruby 'script/outdated.rb'
end

desc 'Run mutation testing; every mutation must be killed (see .mutant.yml)'
task :mutant do
  sh 'bundle exec mutant run'
end

task default: %i[spec rubocop suppressions typecheck yard reek flay flog debride audit]
