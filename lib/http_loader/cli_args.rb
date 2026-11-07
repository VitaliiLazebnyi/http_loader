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

    # Splits a comma-delimited CLI list, trimming whitespace and dropping empty
    # entries so that stray commas (e.g. `--url=,http://x` or `--url=`) can never
    # inject a blank token that later crashes URI/IP resolution.
    #
    # @param raw [String] the raw comma-separated flag value
    # @return [Array<String>] the cleaned list of non-empty tokens
    sig { params(raw: String).returns(T::Array[String]) }
    def self.split_list(raw)
      tokens = raw.split(',')
      tokens.map!(&:strip)
      tokens.reject!(&:empty?)
      tokens
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
    end

    # ClientParser configures OptionParser mapping specifically for Client configurations
    class ClientParser
      extend T::Sig

      # Orchestrator to parse all client-specific options in sequence.
      #
      # @param opts [OptionParser] the active parser instance
      # @param options [Hash] the configuration map to populate
      # @return [void]
      sig { params(opts: OptionParser, options: T::Hash[Symbol, Object]).void }
      def self.parse(opts, options)
        parse_core(opts, options)
        parse_ping(opts, options)
        parse_timeouts(opts, options)
      end

      # Parses core connectivity and URL parameters.
      #
      # @param opts [OptionParser] the active parser instance
      # @param options [Hash] the configuration map to populate
      # @return [void]
      sig { params(opts: OptionParser, options: T::Hash[Symbol, Object]).void }
      def self.parse_core(opts, options)
        opts.on('--connections_count=COUNT', Integer, 'Total connection count') do |value|
          options[:connections] = T.cast(value, Integer)
        end
        opts.on('--https', 'Use HTTPS natively') { options[:use_https] = true }
        opts.on('--url=URL', 'Comma-separated target URLs') do |value|
          options[:target_urls] = CliArgs.split_list(T.cast(value, String))
        end
        opts.on('--verbose', 'Verbose logging') { options[:verbose] = true }
      end

      # Parses ping enablement and intervals.
      #
      # @param opts [OptionParser] the active parser instance
      # @param options [Hash] the configuration map to populate
      # @return [void]
      sig { params(opts: OptionParser, options: T::Hash[Symbol, Object]).void }
      def self.parse_ping(opts, options)
        opts.on('--[no-]ping', 'Enable keep-alive pings') { |value| options[:ping] = T.cast(value, T::Boolean) }
        opts.on('--ping_period=SECONDS', Float, 'Seconds between pings') do |value|
          options[:ping_period] = T.cast(value, Float)
        end
      end

      # Parses timeout, rate-limiting, and concurrency thresholds.
      #
      # @param opts [OptionParser] the active parser instance
      # @param options [Hash] the configuration map to populate
      # @return [void]
      sig { params(opts: OptionParser, options: T::Hash[Symbol, Object]).void }
      def self.parse_timeouts(opts, options)
        opts.on('--http_loader_timeout=S', Float, 'Keep-alive budget in seconds') do |value|
          options[:http_loader_timeout] = T.cast(value, Float)
        end
        opts.on('--connections_per_second=R', Integer, 'Connection ramp rate') do |value|
          options[:connections_per_second] = T.cast(value, Integer)
        end
        opts.on('--max_concurrent_connections=C', Integer, 'Concurrency cap') do |value|
          options[:max_concurrent_connections] = T.cast(value, Integer)
        end
        parse_advanced(opts, options)
      end

      # Parses advanced connection lifecycle controls like reopen logic.
      #
      # @param opts [OptionParser] the active parser instance
      # @param options [Hash] the configuration map to populate
      # @return [void]
      sig { params(opts: OptionParser, options: T::Hash[Symbol, Object]).void }
      def self.parse_advanced(opts, options)
        opts.on('--reopen_closed_connections', 'Reopen closed connections') do
          options[:reopen_closed_connections] = true
        end
        opts.on('--reopen_interval=S', Float, 'Delay before reopening') do |value|
          options[:reopen_interval] = T.cast(value, Float)
        end
        opts.on('--read_timeout=S', Float, 'Socket read timeout') do |value|
          options[:read_timeout] = T.cast(value, Float)
        end
        parse_tracking(opts, options)
      end

      # Parses tracking and obfuscation parameters like jitter and user agents.
      #
      # @param opts [OptionParser] the active parser instance
      # @param options [Hash] the configuration map to populate
      # @return [void]
      sig { params(opts: OptionParser, options: T::Hash[Symbol, Object]).void }
      def self.parse_tracking(opts, options)
        opts.on('--user_agent=A', 'User-Agent header') { |value| options[:user_agent] = T.cast(value, String) }
        opts.on('--jitter=F', Float, 'Randomize sleep durations') { |value| options[:jitter] = T.cast(value, Float) }
        opts.on('--track_status_codes', 'Track HTTP status codes') { options[:track_status_codes] = true }
        parse_endpoints(opts, options)
      end

      # Parses IP binding, proxying, and ramp-up behavior.
      #
      # @param opts [OptionParser] the active parser instance
      # @param options [Hash] the configuration map to populate
      # @return [void]
      sig { params(opts: OptionParser, options: T::Hash[Symbol, Object]).void }
      def self.parse_endpoints(opts, options)
        opts.on('--ramp_up=S', Float, 'Ramp-up window in seconds') { |value| options[:ramp_up] = T.cast(value, Float) }
        opts.on('--bind_ips=IPS', 'Comma-separated source IPs') do |value|
          options[:bind_ips] = CliArgs.split_list(T.cast(value, String))
        end
        opts.on('--proxy_pool=U', 'Comma-separated proxy URIs') do |value|
          options[:proxy_pool] = CliArgs.split_list(T.cast(value, String))
        end
        parse_slowloris(opts, options)
      end

      # Parses parameters triggering the slowloris strategy.
      #
      # @param opts [OptionParser] the active parser instance
      # @param options [Hash] the configuration map to populate
      # @return [void]
      sig { params(opts: OptionParser, options: T::Hash[Symbol, Object]).void }
      def self.parse_slowloris(opts, options)
        opts.on('--qps_per_connection=R', Integer, 'Per-connection QPS cap') do |value|
          options[:qps_per_connection] = T.cast(value, Integer)
        end
        opts.on('--headers=L', 'Repeatable Key: Value header') { |value| parse_headers(T.cast(value, String), options) }
        parse_slowloris_delays(opts, options)
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
        # `String#split(':', 2)` always yields at least the key element, so `value` (the second
        # element) is the only one that can be nil -- it is absent exactly when there was no colon.
        key, value = val.split(':', 2)
        shown = val.inspect
        return warn("[Client] Ignoring malformed --headers entry (expected 'Key: Value'): #{shown}") unless value

        key = T.must(key).strip
        value = value.strip
        return warn("[Client] Ignoring --headers entry with empty key: #{shown}") if key.empty?
        return warn("[Client] Ignoring --headers entry with CR/LF: #{shown}") if "#{key}#{value}".match?(/[\r\n]/)

        T.cast(options[:headers], T::Hash[String, String])[key] = value
      end

      # Parses granular delay configs specifically for slowloris payloads. The harness forwards the
      # client its own `--export_json` / `--target_duration` flags verbatim, so the client registers
      # (and silently ignores) them here to keep OptionParser from rejecting the shared argv.
      #
      # @param opts [OptionParser] the active parser instance
      # @param options [Hash] the configuration map to populate
      # @return [void]
      sig { params(opts: OptionParser, options: T::Hash[Symbol, Object]).void }
      def self.parse_slowloris_delays(opts, options)
        opts.on('--slowloris_delay=S', Float, 'Slowloris byte gap in seconds') do |value|
          options[:slowloris_delay] = T.cast(value, Float)
        end
        opts.on('--export_json=FILE', 'Accepted but ignored by the client subprocess')
        opts.on('--target_duration=S', 'Accepted but ignored; honoured by the harness only')
      end
    end

    # HarnessParser strictly parses orchestrator arguments ignoring explicitly mapped client arguments dynamically.
    class HarnessParser
      extend T::Sig

      # Client-only flags the harness accepts but ignores: it forwards the original argv to the
      # client subprocess verbatim, and only needs OptionParser not to reject these while it
      # extracts its own structural flags. Listing them as data (rather than one no-op handler
      # per flag) keeps the harness flag surface in one place with no duplicated method bodies.
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

      # Orchestrator to parse harness structural args while ignoring client ones.
      #
      # @param opts [OptionParser] the active parser instance
      # @param options [Hash] the configuration map to populate
      # @return [void]
      sig { params(opts: OptionParser, options: T::Hash[Symbol, Object]).void }
      def self.parse(opts, options)
        parse_harness_core(opts, options)
        parse_harness_extras(opts, options)
        ignore_core_args(opts)
      end

      # Parses core connection args for harness.
      #
      # @param opts [OptionParser] option parser
      # @param options [Hash] map
      # @return [void]
      sig { params(opts: OptionParser, options: T::Hash[Symbol, Object]).void }
      def self.parse_harness_core(opts, options)
        opts.on('--connections_count=C', Integer, 'Total connection count') do |value|
          options[:connections] = T.cast(value, Integer)
        end
        opts.on('--https', 'Use HTTPS natively') { options[:use_https] = true }
        opts.on('--url=U', 'Comma-separated target URLs') do |value|
          options[:target_urls] = CliArgs.split_list(T.cast(value, String))
        end
      end

      # Parses extra settings for harness.
      #
      # @param opts [OptionParser] parser
      # @param options [Hash] map
      # @return [void]
      sig { params(opts: OptionParser, options: T::Hash[Symbol, Object]).void }
      def self.parse_harness_extras(opts, options)
        opts.on('--export_json=FILE', 'Write the JSON run report to FILE') do |value|
          options[:export_json] = T.cast(value, String)
        end
        opts.on('--target_duration=S', Float, 'Stop after S seconds') do |value|
          options[:target_duration] = T.cast(value, Float)
        end
      end

      # Registers a discarding handler for every client-only flag so OptionParser tolerates
      # them during the harness's own structural parse. A block-less `on` registers the flag
      # with no action, which is exactly the "accept and discard" behaviour required.
      #
      # @param opts [OptionParser] the active parser instance
      # @return [void]
      sig { params(opts: OptionParser).void }
      def self.ignore_core_args(opts)
        IGNORED_CLIENT_FLAGS.each { |flag| opts.on(flag) }
      end
    end
  end
end
