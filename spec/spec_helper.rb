# typed: true
# frozen_string_literal: true

# Copyright (c) 2026 Vitalii Lazebnyi

# Opt out of only the "experimental feature" warning category. The async fiber scheduler
# performs non-blocking file IO through Ruby's IO::Buffer, which Ruby 4.0 still flags as
# experimental; the notice is about a transitive dependency's use of a core API, not our code.
# This disables that one category only -- deprecation and performance warnings stay on and are
# enforced by the warning gate.
Warning[:experimental] = false

require 'simplecov'
SimpleCov.start do
  skip '/spec/'
  enable_coverage :branch
  # The 100% gate is meaningful only for a full-suite run. Enforcing it on an ad-hoc
  # subset (or on spec/integration, whose work happens in subprocesses SimpleCov can't
  # see) fails spuriously, so gate it behind CI/COVERAGE.
  minimum_coverage(line: 100, branch: 100) if ENV['CI'] || ENV['COVERAGE']
end

$LOAD_PATH.unshift(File.expand_path('../lib', __dir__))
require 'http_loader/client'
require 'http_loader/harness'
require 'http_loader/server'

Dir[File.join(__dir__, 'support', '**', '*.rb')].each { |f| require f }

RSpec.configure do |config|
  config.expect_with(:rspec) do |expectations|
    expectations.include_chain_clauses_in_custom_matcher_descriptions = true
  end

  config.mock_with(:rspec) do |mocks|
    mocks.verify_partial_doubles = true
  end

  config.shared_context_metadata_behavior = :apply_to_host_groups

  # Every example runs with $stdout and $stderr captured, and fails if it wrote anything there
  # that it did not assert itself (with the `output` matcher or a stubbed puts/warn). A stray
  # line would otherwise land in the CI log, where the warning gate cannot tell a test's
  # expected message from a real warning.
  config.around do |example|
    streams = [$stdout, $stderr]
    $stdout = StringIO.new
    $stderr = StringIO.new
    begin
      example.run
    ensure
      leaked = { stdout: $stdout.string, stderr: $stderr.string }.reject { |_, text| text.empty? }
      $stdout, $stderr = streams
    end
    raise "Example wrote unasserted output: #{leaked.inspect}" unless leaked.empty?
  end
end
require 'sorbet-runtime'
# Keep inline type checks (T.let / T.cast / T.must) live so a genuinely wrong-typed
# value still fails a test — restoring the runtime type net that a blanket no-op removed.
# The one concession is RSpec verifying doubles: the suite deliberately substitutes them
# for real Net::HTTP*/Async::Task collaborators, and those are a test-only construct, so a
# cast that only "fails" because it received a double is allowed through. Any other type
# mismatch (a real object of the wrong class) still raises and fails the example.
T::Configuration.inline_type_error_handler =
  lambda do |error, _opts|
    raise(error) unless error.message.include?('RSpec::Mocks')
  end
# The method-signature validator stays relaxed for the same double-substitution reason.
T::Configuration.call_validation_error_handler = ->(_signature, _opts) {}

# Force every sorbet-runtime signature in the gem to evaluate now, while each method is
# still its original definition. RSpec's verifying partial doubles later redefine some of
# these methods; if a method's sig block were still unevaluated at that point, sorbet-runtime
# would emit "Dropping unevaluated signature ... because it was redefined". Resolving the
# signatures up front removes that race (and its warning) without weakening any type check.
module SigResolver
  def self.resolve_all
    ObjectSpace.each_object(Module)
               .select { |mod| mod.name&.start_with?('HttpLoader') }
               .each { |mod| methods_of(mod).each { |meth| T::Utils.signature_for_method(meth) } }
  end

  def self.methods_of(mod)
    instance =
      (mod.instance_methods(false) + mod.private_instance_methods(false))
      .map { |name| mod.instance_method(name) }
    singleton =
      (mod.methods(false) + mod.singleton_class.private_instance_methods(false))
      .map { |name| mod.method(name) }
    instance + singleton
  end
end
SigResolver.resolve_all
