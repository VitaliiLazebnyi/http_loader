# typed: true
# frozen_string_literal: true

# Copyright (c) 2026 Vitalii Lazebnyi

# Opt out of only the "experimental feature" warning category. The async fiber scheduler
# performs non-blocking file IO through Ruby's IO::Buffer, which Ruby 4.0 still flags as
# experimental; the notice is about a transitive dependency's use of a core API, not our code.
# This disables that one category only -- deprecation and performance warnings stay on and are
# enforced by the warning gate.
Warning[:experimental] = false

# Drops exactly one warning that `ruby -w` reports in a dependency and that cannot be fixed here:
# protocol-http 0.72.1 (the newest release; its main branch is unchanged) assigns `rescue => error`
# without using `error` in lib/protocol/http/body/streamable.rb. Only that message from that file is
# dropped, and only in the test process; every other warning still reaches stderr and the warning gate.
module UpstreamWarningFilter
  # The one dropped warning: the file and the message are both pinned.
  IGNORED = %r{/protocol-http-[\d.]+/lib/protocol/http/body/streamable\.rb:\d+: warning: assigned but unused variable - error\n\z}
  private_constant :IGNORED

  # @param message [String] the warning text
  # @param category [Symbol, nil] the warning category
  # @return [void]
  def warn(message, category: nil)
    return if message.match?(IGNORED)

    super
  end
end
Warning.singleton_class.prepend(UpstreamWarningFilter)

require 'simplecov'
SimpleCov.skip('/spec/')
SimpleCov.enable_coverage(:branch)
# The 100% gate is meaningful only for a full-suite run. Enforcing it on an ad-hoc subset (or on
# spec/integration, whose work happens in subprocesses SimpleCov can't see) fails spuriously, so it is
# gated behind CI/COVERAGE.
SimpleCov.minimum_coverage(line: 100, branch: 100) if ENV.fetch('CI', nil) || ENV.fetch('COVERAGE', nil)
SimpleCov.start

$LOAD_PATH.unshift(File.expand_path('../lib', __dir__))
require 'http_loader'
require 'sorbet-runtime'
require 'stringio'

Dir[File.join(__dir__, 'support', '**', '*.rb')].each { |f| require(f) }

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
    raise(RSpec::Expectations::ExpectationNotMetError, "Example wrote unasserted output: #{leaked.inspect}") if leaked.any?
  end
end

# Sorbet's runtime checks stay on in the suite: a wrong-typed value passed to or returned from any
# signature, or given to T.let / T.cast / T.must, raises and fails the example. The one exception is an
# RSpec test double: the suite substitutes doubles for real Net::HTTP and Async::Task collaborators, and
# a double is never an instance of the class a signature names. A real object of the wrong class still
# raises.
module DoubleTolerantTypeErrors
  # @param message [String] the type error message
  # @return [Boolean] whether the mismatch is only an RSpec test double standing in for a real object
  def self.double?(message)
    message.include?('RSpec::Mocks')
  end
end
T::Configuration.inline_type_error_handler =
  lambda do |error, _opts|
    raise(error) unless DoubleTolerantTypeErrors.double?(error.message)
  end
T::Configuration.call_validation_error_handler =
  lambda do |_signature, opts|
    message = opts.fetch(:pretty_message)
    raise(TypeError, message) unless DoubleTolerantTypeErrors.double?(message)
  end

# Forces every sorbet-runtime signature in the gem to evaluate now, while each method is still its
# original definition. RSpec's verifying partial doubles later redefine some of these methods; if a
# method's sig block were still unevaluated at that point, sorbet-runtime would emit "Dropping
# unevaluated signature ... because it was redefined". Resolving the signatures up front removes that
# race (and its warning) without weakening any type check.
module SigResolver
  extend T::Sig

  # Evaluates the signature of every method of every HttpLoader module.
  #
  # @return [void]
  sig { void }
  def self.resolve_all
    ObjectSpace
      .each_object(Module)
      .select { |mod| mod.name&.start_with?('HttpLoader') }
      .each { |mod| methods_of(mod).each { |meth| T::Utils.signature_for_method(meth) } }
  end

  # @param mod [Module] a module of the gem
  # @return [Array<UnboundMethod, Method>] its own instance and singleton methods, public and private
  sig { params(mod: Module).returns(T::Array[T.any(UnboundMethod, Method)]) }
  def self.methods_of(mod)
    instance =
      (mod.instance_methods(false) + mod.private_instance_methods(false)).map { |name| mod.instance_method(name) }
    singleton =
      (mod.methods(false) + mod.singleton_class.private_instance_methods(false)).map { |name| mod.method(name) }
    instance + singleton
  end
end
SigResolver.resolve_all
