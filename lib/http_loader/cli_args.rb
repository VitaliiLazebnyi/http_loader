# typed: strong
# frozen_string_literal: true

# Copyright (c) 2026 Vitalii Lazebnyi

require 'optparse'
require 'sorbet-runtime'
require_relative 'client/config'
require_relative 'harness/config'

# Primary namespace for the load testing framework.
module HttpLoader
  # Extracted arguments parsers for strict metric compliance.
  module CliArgs
    extend T::Sig

    # Parses the flags of one subcommand; parsed flags are removed from argv.
    #
    # @param argv [Array<String>] the flags
    # @param command [String] the subcommand, for the usage banner
    # @yieldparam opts [OptionParser] the parser to declare the flags on
    # @return [void]
    sig { params(argv: T::Array[String], command: String, block: T.proc.params(opts: OptionParser).void).void }
    def self.parse(argv, command, &block)
      OptionParser.new("Usage: http_loader #{command} [options]", &block).parse!(argv)
    end

    # Parses the server flags.
    #
    # @param argv [Array<String>] the server flags
    # @return [Boolean] whether `--https` was given
    sig { params(argv: T::Array[String]).returns(T::Boolean) }
    def self.server_https?(argv)
      https = T.let(false, T::Boolean)
      parse(argv, 'server') do |opts|
        opts.on('--https', 'Serve over HTTPS with an ephemeral self-signed certificate') { https = true }
      end
      https
    end

    # The type of a comma-separated list flag (`--url`, `--bind_ips`, `--proxy_pool`), and its conversion.
    module List
      extend T::Sig

      # Splits a comma-delimited CLI list, trimming whitespace and dropping empty
      # entries so that stray commas (e.g. `--url=,http://x` or `--url=`) can never
      # inject a blank token that later crashes URI/IP resolution.
      #
      # @param raw [String] the raw comma-separated flag value
      # @return [Array<String>] the cleaned list of non-empty tokens
      sig { params(raw: String).returns(T::Array[String]) }
      def self.parse(raw)
        tokens = raw.split(',')
        tokens.map!(&:strip)
        tokens.reject!(&:empty?)
        tokens
      end
    end

    # The client options: their values before parsing, and the Client::Config built from the parsed values.
    class ClientOptions
      extend T::Sig

      # The value of every client option before any flag is parsed. A nil concurrency cap means "one slot per
      # connection" (see ClientOptions.config).
      DEFAULTS = T.let(
        {
          connections: 1000,
          use_https: false,
          target_urls: [].freeze,
          verbose: false,
          ping: true,
          ping_period: 5.0,
          http_loader_timeout: 0.0,
          connections_per_second: 0,
          max_concurrent_connections: nil,
          reopen_closed_connections: false,
          reopen_interval: 5.0,
          read_timeout: 0.0,
          user_agent: 'Keep-Alive Test',
          jitter: 1.0,
          track_status_codes: false,
          ramp_up: 0.0,
          bind_ips: [].freeze,
          proxy_pool: [].freeze,
          qps_per_connection: 0,
          headers: {}.freeze,
          slowloris_delay: 0.0
        }.freeze,
        T::Hash[Symbol, Object]
      )
      public_constant :DEFAULTS

      # The parsed option values, as Client::Config takes them. `T.cast` to this shape checks every value.
      Values =
        T.type_alias do
          {
            connections: Integer,
            use_https: T::Boolean,
            target_urls: T::Array[String],
            verbose: T::Boolean,
            ping: T::Boolean,
            ping_period: Float,
            http_loader_timeout: Float,
            connections_per_second: Integer,
            max_concurrent_connections: Integer,
            reopen_closed_connections: T::Boolean,
            reopen_interval: Float,
            read_timeout: Float,
            user_agent: String,
            jitter: Float,
            track_status_codes: T::Boolean,
            ramp_up: Float,
            bind_ips: T::Array[String],
            proxy_pool: T::Array[String],
            qps_per_connection: Integer,
            headers: T::Hash[String, String],
            slowloris_delay: Float
          }
        end
      private_constant :Values

      # A fresh, mutable copy of DEFAULTS for one parse; `--headers` adds to its own header map.
      #
      # @return [Hash{Symbol => Object}] the option values to parse into
      sig { returns(T::Hash[Symbol, Object]) }
      def self.defaults
        DEFAULTS.merge(headers: {})
      end

      # Parses the client flags into the client configuration.
      #
      # @param argv [Array<String>] the client flags; parsed flags are removed
      # @return [Client::Config] the configuration
      # @raise [OptionParser::ParseError, TypeError] if a flag is invalid
      sig { params(argv: T::Array[String]).returns(Client::Config) }
      def self.parse(argv)
        values = defaults
        CliArgs.parse(argv, 'client') { |opts| ClientParser.parse(opts, values) }
        config(values)
      end

      # Builds the client configuration from parsed option values.
      #
      # @param options [Hash{Symbol => Object}] the option values, starting from .defaults
      # @return [Client::Config] the configuration; the concurrency cap defaults to the connection count
      # @raise [TypeError] if an option value has the wrong type or an unknown option is present
      sig { params(options: T::Hash[Symbol, Object]).returns(Client::Config) }
      def self.config(options)
        cap = options.fetch(:max_concurrent_connections) || options.fetch(:connections)
        Client::Config.new(**T.cast(options.merge(max_concurrent_connections: cap), Values))
      end
    end

    # The harness options: their values before parsing, and the Harness::Config built from the parsed values.
    class HarnessOptions
      extend T::Sig

      # The value of every harness option before any flag is parsed.
      DEFAULTS = T.let(
        { connections: 1000, use_https: false, target_urls: [].freeze, export_json: nil, target_duration: 0.0 }.freeze,
        T::Hash[Symbol, Object]
      )
      public_constant :DEFAULTS

      # The parsed option values plus the forwarded client flags, as Harness::Config takes them.
      Values =
        T.type_alias do
          {
            connections: Integer,
            use_https: T::Boolean,
            target_urls: T::Array[String],
            client_args: T::Array[String],
            export_json: T.nilable(String),
            target_duration: Float
          }
        end
      private_constant :Values

      # Builds the harness configuration from parsed option values.
      #
      # @param options [Hash{Symbol => Object}] the option values, starting from DEFAULTS
      # @param client_args [Array<String>] the flags forwarded to the client subprocess
      # @return [Harness::Config] the configuration
      # @raise [TypeError] if an option value has the wrong type or an unknown option is present
      sig { params(options: T::Hash[Symbol, Object], client_args: T::Array[String]).returns(Harness::Config) }
      def self.config(options, client_args)
        Harness::Config.new(**T.cast(options.merge(client_args: client_args), Values))
      end

      # Parses the harness flags into the harness configuration. The client subprocess receives the same flags.
      #
      # @param argv [Array<String>] the harness flags; parsed flags are removed
      # @return [Harness::Config] the configuration
      # @raise [OptionParser::ParseError, TypeError] if a flag is invalid
      sig { params(argv: T::Array[String]).returns(Harness::Config) }
      def self.parse(argv)
        client_args = argv.dup
        values = DEFAULTS.dup
        CliArgs.parse(argv, 'harness') { |opts| HarnessParser.parse(opts, values) }
        config(values, client_args)
      end
    end

    # A flag that stores its value: the option it sets, its OptionParser switch, the type its argument is
    # converted to (nil for a switch without one, or a String argument), and its description.
    Flag = T.type_alias { [Symbol, String, T.nilable(T::Module[T.anything]), String] }
    private_constant :Flag

    # The flags both the client and the harness parse: the option each one sets, then its OptionParser switch.
    CORE_FLAGS = T.let(
      [
        [:connections, '--connections_count=COUNT', Integer, 'Total connection count'],
        [:use_https, '--https', nil, 'Use HTTPS natively'],
        [:target_urls, '--url=URL', List, 'Comma-separated target URLs']
      ].freeze,
      T::Array[Flag]
    )
    private_constant :CORE_FLAGS

    # Declares flags on a parser: each one stores its (converted) value as the option it names.
    #
    # @param opts [OptionParser] the parser
    # @param options [Hash{Symbol => Object}] the option values the flags write to
    # @param flags [Array<Array(Symbol, String, Module, String)>] the flags
    # @return [void]
    sig { params(opts: OptionParser, options: T::Hash[Symbol, Object], flags: T::Array[Flag]).void }
    def self.declare(opts, options, flags)
      opts.accept(List) { |raw| List.parse(T.cast(raw, String)) }
      flags.each { |flag| on(opts, options, flag) }
    end

    # Declares one flag that stores its value as the option it names.
    #
    # @param opts [OptionParser] the parser
    # @param options [Hash{Symbol => Object}] the option values the flag writes to
    # @param flag [Array(Symbol, String, Module, String)] the option, switch, type and description of the flag
    # @return [void]
    sig { params(opts: OptionParser, options: T::Hash[Symbol, Object], flag: Flag).void }
    def self.on(opts, options, flag)
      name, switch, type, description = flag
      handler = setter(options, name)
      type ? opts.on(switch, type, description, &handler) : opts.on(switch, description, &handler)
    end

    # The handler of a flag that stores its value as an option.
    #
    # @param options [Hash{Symbol => Object}] the option values
    # @param name [Symbol] the option the flag sets
    # @return [Proc] the handler OptionParser calls with the flag's value
    sig { params(options: T::Hash[Symbol, Object], name: Symbol).returns(T.proc.params(value: Object).void) }
    def self.setter(options, name)
      ->(value) { options[name] = T.cast(value, Object) }
    end
    private_class_method :on, :setter

    # ClientParser configures OptionParser mapping specifically for Client configurations
    class ClientParser
      extend T::Sig

      # Every client flag that stores its value, in help order, after CORE_FLAGS: the option it sets, then its
      # OptionParser switch.
      FLAGS = T.let(
        [
          [:verbose, '--verbose', nil, 'Verbose logging'],
          [:ping, '--[no-]ping', nil, 'Enable keep-alive pings'],
          [:ping_period, '--ping_period=SECONDS', Float, 'Seconds between pings'],
          [:http_loader_timeout, '--http_loader_timeout=S', Float, 'Keep-alive budget in seconds'],
          [:connections_per_second, '--connections_per_second=R', Integer, 'Connection ramp rate'],
          [:max_concurrent_connections, '--max_concurrent_connections=C', Integer, 'Concurrency cap'],
          [:reopen_closed_connections, '--reopen_closed_connections', nil, 'Reopen closed connections'],
          [:reopen_interval, '--reopen_interval=S', Float, 'Delay before reopening'],
          [:read_timeout, '--read_timeout=S', Float, 'Socket read timeout'],
          [:user_agent, '--user_agent=A', nil, 'User-Agent header'],
          [:jitter, '--jitter=F', Float, 'Randomize sleep durations'],
          [:track_status_codes, '--track_status_codes', nil, 'Track HTTP status codes'],
          [:ramp_up, '--ramp_up=S', Float, 'Ramp-up window in seconds'],
          [:bind_ips, '--bind_ips=IPS', List, 'Comma-separated source IPs'],
          [:proxy_pool, '--proxy_pool=U', List, 'Comma-separated proxy URIs'],
          [:qps_per_connection, '--qps_per_connection=R', Integer, 'Per-connection QPS cap'],
          [:slowloris_delay, '--slowloris_delay=S', Float, 'Slowloris byte gap in seconds']
        ].freeze,
        T::Array[Flag]
      )
      private_constant :FLAGS

      # Declares every client flag on the parser. The harness forwards the client its own `--export_json` and
      # `--target_duration` flags verbatim, so the client accepts (and ignores) them as well.
      #
      # @param opts [OptionParser] the active parser instance
      # @param options [Hash] the configuration map to populate
      # @return [void]
      sig { params(opts: OptionParser, options: T::Hash[Symbol, Object]).void }
      def self.parse(opts, options)
        CliArgs.declare(opts, options, CORE_FLAGS + FLAGS)
        opts.on('--headers=L', 'Repeatable Key: Value header') { |value| parse_headers(T.cast(value, String), options) }
        opts.on('--export_json=FILE', 'Accepted but ignored by the client subprocess')
        opts.on('--target_duration=S', 'Accepted but ignored; honoured by the harness only')
      end

      # Parses a single `Key: Value` header from one `--headers` occurrence. Supplying
      # the flag multiple times accumulates headers, which avoids the comma-delimiter
      # collision that previously corrupted values like `Accept: text/html,application/json`.
      # Malformed entries (no colon, empty key) are warned about and skipped; CR/LF is
      # rejected here at the single chokepoint so both the Net::HTTP and raw-socket
      # (slowloris) engines only ever see header-injection-safe values.
      #
      # @param val [String] a single `Key: Value` header string
      # @param options [Hash] the configuration map to populate
      # @return [void]
      sig { params(val: String, options: T::Hash[Symbol, Object]).void }
      def self.parse_headers(val, options)
        pair = header(val)
        T.cast(options[:headers], T::Hash[String, String]).store(*pair) if pair
      end

      # The name and value of one `--headers` entry, or nothing (after a warning) when it is malformed.
      #
      # @param val [String] a single `Key: Value` header string
      # @return [Array(String, String), nil] the trimmed name and value
      sig { params(val: String).returns(T.nilable([String, String])) }
      def self.header(val)
        problem = header_problem(val)
        return warn("[Client] Ignoring #{problem}: #{val.inspect}") if problem

        name, value = val.split(':', 2)
        [T.must(name).strip, T.must(value).strip]
      end

      # What makes a `--headers` entry unusable: no colon, an empty name, or a CR/LF (a header injection).
      #
      # @param val [String] a single `Key: Value` header string
      # @return [String, nil] the problem, or nil when the entry is valid
      sig { params(val: String).returns(T.nilable(String)) }
      def self.header_problem(val)
        # `String#split(':', 2)` always yields at least the name, so `value` (the second element)
        # is the only one that can be nil -- it is absent exactly when there was no colon.
        name, value = val.split(':', 2)
        return "malformed --headers entry (expected 'Key: Value')" unless value

        name = T.must(name).strip
        return '--headers entry with empty key' if name.empty?

        '--headers entry with CR/LF' if "#{name}#{value.strip}".match?(/[\r\n]/)
      end
      private_class_method :header, :header_problem
    end

    # HarnessParser strictly parses orchestrator arguments ignoring explicitly mapped client arguments dynamically.
    class HarnessParser
      extend T::Sig

      # The harness flags beyond CORE_FLAGS: the option each one sets, then its OptionParser switch.
      FLAGS = T.let(
        [
          [:export_json, '--export_json=FILE', nil, 'Write the JSON run report to FILE'],
          [:target_duration, '--target_duration=S', Float, 'Stop after S seconds']
        ].freeze,
        T::Array[Flag]
      )
      private_constant :FLAGS

      # Client-only flags the harness accepts but ignores: it forwards the original argv to the
      # client subprocess verbatim, and only needs OptionParser not to reject these while it
      # extracts its own structural flags. A block-less `on` registers a flag with no action,
      # which is exactly the "accept and discard" behaviour required.
      IGNORED_CLIENT_FLAGS = %w[
        --verbose
        --[no-]ping
        --ping_period=S
        --http_loader_timeout=S
        --connections_per_second=R
        --max_concurrent_connections=C
        --reopen_closed_connections
        --reopen_interval=S
        --read_timeout=S
        --user_agent=A
        --jitter=F
        --track_status_codes
        --ramp_up=S
        --bind_ips=IPS
        --proxy_pool=U
        --qps_per_connection=R
        --headers=LIST
        --slowloris_delay=S
      ].freeze
      public_constant :IGNORED_CLIENT_FLAGS

      # Declares the harness flags, and the client-only ones it ignores.
      #
      # @param opts [OptionParser] the active parser instance
      # @param options [Hash] the configuration map to populate
      # @return [void]
      sig { params(opts: OptionParser, options: T::Hash[Symbol, Object]).void }
      def self.parse(opts, options)
        CliArgs.declare(opts, options, CORE_FLAGS + FLAGS)
        IGNORED_CLIENT_FLAGS.each { |flag| opts.on(flag) }
      end
    end
  end
end
