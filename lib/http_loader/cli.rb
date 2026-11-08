# typed: strong
# frozen_string_literal: true

# Copyright (c) 2026 Vitalii Lazebnyi

require 'optparse'
require 'sorbet-runtime'
require 'uri'
require_relative 'cli_args'
require_relative 'client'
require_relative 'harness'
require_relative 'server'

# Primary namespace for the load testing framework.
module HttpLoader
  # Command-line entry point behind `bin/http_loader`: dispatches the `client`, `server` and `harness`
  # subcommands and turns an invalid invocation into a one-line "Configuration Error" and exit status 1.
  #
  # @example Invocation
  #   $ bin/http_loader client --connections_count=1000
  class CLI
    extend T::Sig

    # Printed when the subcommand is missing or unknown.
    USAGE = 'Usage: http_loader <client|server|harness> [options]'
    private_constant :USAGE

    # Runs the subcommand named by the first argument.
    #
    # @param argv [Array<String>] the command-line arguments, subcommand first (not modified)
    # @return [Integer] the process exit status
    sig { params(argv: T::Array[String]).returns(Integer) }
    def self.run(argv)
      new(argv).run
    end

    # @param argv [Array<String>] the command-line arguments, subcommand first (#run never modifies them)
    # @return [void]
    sig { params(argv: T::Array[String]).void }
    def initialize(argv)
      @argv = argv
    end

    # Runs the subcommand named by the first argument.
    #
    # @return [Integer] the process exit status
    sig { returns(Integer) }
    def run
      argv = @argv.dup
      case argv.shift
      when 'client' then run_client(argv)
      when 'server' then run_server(argv)
      when 'harness' then run_harness(argv)
      else usage_error
      end
    end

    private

    # Parses the client flags and runs the load-generating client.
    #
    # @param argv [Array<String>] the client flags
    # @return [Integer] the process exit status
    sig { params(argv: T::Array[String]).returns(Integer) }
    def run_client(argv)
      configured { Client.new(CliArgs::ClientOptions.parse(argv)).start }
    end

    # Parses the harness flags and runs the harness. The client subprocess receives the same flags.
    #
    # @param argv [Array<String>] the harness flags
    # @return [Integer] the process exit status
    sig { params(argv: T::Array[String]).returns(Integer) }
    def run_harness(argv)
      configured { Harness.new(CliArgs::HarnessOptions.parse(argv)).start }
    end

    # Runs a parsed subcommand, turning an invalid flag or configuration into a Configuration Error.
    #
    # @yield parses the flags and runs the subcommand
    # @return [Integer] the process exit status
    sig { params(block: T.proc.void).returns(Integer) }
    def configured(&block)
      yield
      0
    rescue ArgumentError, OptionParser::ParseError, URI::Error, TypeError => error
      configuration_error(error)
    end

    # Parses the server flags and runs the local test server on 8080 (HTTP) or 8443 (HTTPS).
    #
    # @param argv [Array<String>] the server flags
    # @return [Integer] the process exit status
    sig { params(argv: T::Array[String]).returns(Integer) }
    def run_server(argv)
      Server.new(https: CliArgs.server_https?(argv)).start
      0
    rescue OptionParser::ParseError => error
      configuration_error(error)
    end

    # Reports an invalid invocation.
    #
    # @param error [StandardError] the error describing what is wrong
    # @return [Integer] the exit status 1
    sig { params(error: StandardError).returns(Integer) }
    def configuration_error(error)
      warn("Configuration Error: #{error}")
      1
    end

    # Reports a missing or unknown subcommand.
    #
    # @return [Integer] the exit status 1
    sig { returns(Integer) }
    def usage_error
      warn(USAGE)
      1
    end
  end
end
