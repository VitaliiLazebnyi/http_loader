# frozen_string_literal: true

require 'bundler/gem_tasks'
require 'rspec/core/rake_task'

# Flay mass threshold. At the default (16) Flay also reports 2-3 line structural echoes
# (identical one-line `sleep(...)` pacing calls, the sibling numeric validators, the paired
# File.open log/err blocks) that are clearer left inline than extracted. From 24 up it reports
# every genuinely duplicated piece of logic; the suite must score 0 at that threshold.
FLAY_MASS = 24

# Output of `yard stats` when every public API object is documented.
FULLY_DOCUMENTED = '100.00% documented'

RSpec::Core::RakeTask.new(:spec)

desc 'Run RuboCop with every plugin'
task :rubocop do
  sh 'bundle exec rubocop'
end

desc 'Fail on inline suppressions of any linter, scanner, type checker, warning or test'
task :suppressions do
  sh 'script/forbidden_suppressions.sh'
end

desc 'Generate the gem RBIs with Tapioca, then run the Sorbet type checker'
task :typecheck do
  # Tapioca runs from its own bundle. Under `bundle exec rake` the environment belongs to the
  # main bundle, so the nested commands run in an unbundled environment.
  # BUNDLE_DEPLOYMENT/FROZEN are forced off: the typecheck bundle has no committed lockfile
  # (it is generated here), which deployment mode refuses. CI's cached main bundle sets them on.
  nested = 'env BUNDLE_GEMFILE=typecheck.gemfile BUNDLE_DEPLOYMENT=false BUNDLE_FROZEN=false'
  Bundler.with_unbundled_env do
    sh "#{nested} bundle install --quiet"
    sh "#{nested} bundle exec tapioca gem"
  end
  # Tapioca already merges the RBIs that gems ship themselves into the generated ones; srb must
  # not load them a second time.
  sh 'env SRB_SKIP_GEM_RBIS=1 bundle exec srb tc'
end

desc 'Fail unless every public API object is documented'
task :yard do
  output = IO.popen(%w[bundle exec yard stats --list-undoc], err: %i[child out], &:read)
  puts output
  abort 'YARD: undocumented API objects found' unless output.include?(FULLY_DOCUMENTED)
end

desc 'Fail on any code smell (configured Reek detectors, see .reek.yml)'
task :reek do
  sh 'bundle exec reek lib'
end

desc 'Fail on any structural duplication'
task :flay do
  output = IO.popen(['bundle', 'exec', 'flay', '--mass', FLAY_MASS.to_s, 'lib'], &:read)
  puts output
  abort 'Flay: duplicated code found' unless output.start_with?('Total score (lower is better) = 0')
end

desc 'Audit gem dependencies for known vulnerabilities'
task :audit do
  sh 'bundle exec bundler-audit check --update'
end

desc 'Fail on outdated gems that are not on the documented hold list'
task :outdated do
  ruby 'script/outdated.rb'
end

desc 'Run mutation testing (see .mutant.yml)'
task :mutant do
  sh 'bundle exec mutant run'
end

desc 'Run the full local verification gate'
task default: %i[spec rubocop suppressions typecheck yard reek flay audit]
