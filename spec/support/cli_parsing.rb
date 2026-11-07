# typed: strict
# frozen_string_literal: true

# Copyright (c) 2026 Vitalii Lazebnyi

require 'http_loader/cli_args'
require 'optparse'

# Wires the CliArgs parsers into a fresh OptionParser, the way the CLI does, for the examples.
module CliParsing
  extend T::Sig

  # @param argv [Array<String>] client flags
  # @return [Hash{Symbol => Object}] the option values the client flags set (headers always present)
  sig { params(argv: T::Array[String]).returns(T::Hash[Symbol, Object]) }
  def self.client(argv)
    options = T.let({ headers: {} }, T::Hash[Symbol, Object])
    OptionParser.new { |opts| HttpLoader::CliArgs::ClientParser.parse(opts, options) }
      .parse!(argv)
    options
  end

  # @param argv [Array<String>] harness flags (client-only flags are accepted and ignored)
  # @return [Hash{Symbol => Object}] the option values the harness flags set
  sig { params(argv: T::Array[String]).returns(T::Hash[Symbol, Object]) }
  def self.harness(argv)
    options = T.let({}, T::Hash[Symbol, Object])
    OptionParser.new { |opts| HttpLoader::CliArgs::HarnessParser.parse(opts, options) }
      .parse!(argv)
    options
  end

  # @return [String] the generated --help text of the client flags
  sig { returns(String) }
  def self.client_help
    OptionParser.new { |opts| HttpLoader::CliArgs::ClientParser.parse(opts, { headers: {} }) }
      .to_s
  end

  # @return [String] the generated --help text of the harness flags
  sig { returns(String) }
  def self.harness_help
    OptionParser.new { |opts| HttpLoader::CliArgs::HarnessParser.parse(opts, {}) }
      .to_s
  end

  # @param value [String] one `--headers` value
  # @return [Object] the header map after parsing it into an empty one
  sig { params(value: String).returns(Object) }
  def self.headers_for(value)
    options = T.let({ headers: {} }, T::Hash[Symbol, Object])
    HttpLoader::CliArgs::ClientParser.parse_headers(value, options)
    options.fetch(:headers)
  end
end
