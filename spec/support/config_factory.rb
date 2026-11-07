# typed: strict
# frozen_string_literal: true

# Copyright (c) 2026 Vitalii Lazebnyi

require 'http_loader/cli_args'

# Builds the configurations the examples use, through the same option builders the CLI uses, so every
# value is type-checked at runtime exactly as for a real invocation.
module ConfigFactory
  extend T::Sig

  # @param overrides [Hash{Symbol => Object}] client option values that differ from the CLI defaults
  # @return [HttpLoader::Client::Config] the client configuration
  sig { params(overrides: T::Hash[Symbol, Object]).returns(HttpLoader::Client::Config) }
  def self.client(overrides = {})
    HttpLoader::CliArgs::ClientOptions.config(HttpLoader::CliArgs::ClientOptions.defaults.merge(overrides))
  end

  # @param overrides [Hash{Symbol => Object}] harness option values that differ from the CLI defaults
  # @param client_args [Array<String>] the flags forwarded to the client subprocess
  # @return [HttpLoader::Harness::Config] the harness configuration
  sig do
    params(overrides: T::Hash[Symbol, Object], client_args: T::Array[String]).returns(HttpLoader::Harness::Config)
  end
  def self.harness(overrides = {}, client_args = [])
    HttpLoader::CliArgs::HarnessOptions.config(
      HttpLoader::CliArgs::HarnessOptions::DEFAULTS.merge(overrides),
      client_args
    )
  end
end
