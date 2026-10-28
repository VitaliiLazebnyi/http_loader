# typed: strong
# frozen_string_literal: true

require 'sorbet-runtime'
require 'optparse'

# Primary namespace for the load testing framework.
module HttpLoader
  # Extracted arguments parsers for strict metric compliance.
  module CliArgs
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
        nil
      end

      # Parses core connectivity and URL parameters.
      #
      # @param opts [OptionParser] the active parser instance
      # @param options [Hash] the configuration map to populate
      # @return [void]
      sig { params(opts: OptionParser, options: T::Hash[Symbol, Object]).void }
      def self.parse_core(opts, options)
        opts.on('--connections_count=COUNT', Integer, 'Total') { |v| options[:connections] = T.cast(v, Integer) }
        opts.on('--https', 'Use HTTPS natively') { options[:use_https] = true }
        opts.on('--url=URL', String, 'URLs') { |v| options[:target_urls] = split_list(T.cast(v, String)) }
        opts.on('--verbose', 'Verbose logging') { options[:verbose] = true }
        nil
      end

      # Parses ping enablement and intervals.
      #
      # @param opts [OptionParser] the active parser instance
      # @param options [Hash] the configuration map to populate
      # @return [void]
      sig { params(opts: OptionParser, options: T::Hash[Symbol, Object]).void }
      def self.parse_ping(opts, options)
        opts.on('--[no-]ping', 'Ping') { |v| options[:ping] = T.cast(v, T::Boolean) }
        opts.on('--ping_period=SECONDS', Integer, 'Ping period') { |v| options[:ping_period] = T.cast(v, Integer) }
        nil
      end

      # Parses timeout, rate-limiting, and concurrency thresholds.
      #
      # @param opts [OptionParser] the active parser instance
      # @param options [Hash] the configuration map to populate
      # @return [void]
      sig { params(opts: OptionParser, options: T::Hash[Symbol, Object]).void }
      def self.parse_timeouts(opts, options)
        opts.on('--http_loader_timeout=S', Float, 'Keep') { |v| options[:http_loader_timeout] = T.cast(v, Float) }
        opts.on('--connections_per_second=R', Integer, 'Rate') { |v| options[:connections_per_second] = T.cast(v, Integer) }
        opts.on('--max_concurrent_connections=C', Integer, 'Max') { |v| options[:max_concurrent_connections] = T.cast(v, Integer) }
        parse_advanced(opts, options)
        nil
      end

      # Parses advanced connection lifecycle controls like reopen logic.
      #
      # @param opts [OptionParser] the active parser instance
      # @param options [Hash] the configuration map to populate
      # @return [void]
      sig { params(opts: OptionParser, options: T::Hash[Symbol, Object]).void }
      def self.parse_advanced(opts, options)
        opts.on('--reopen_closed_connections', 'Reopen') { options[:reopen_closed_connections] = true }
        opts.on('--reopen_interval=S', Float, 'Reopen delay') { |v| options[:reopen_interval] = T.cast(v, Float) }
        opts.on('--read_timeout=S', Float, 'Read timeout') { |v| options[:read_timeout] = T.cast(v, Float) }
        parse_tracking(opts, options)
        nil
      end

      # Parses tracking and obfuscation parameters like jitter and user agents.
      #
      # @param opts [OptionParser] the active parser instance
      # @param options [Hash] the configuration map to populate
      # @return [void]
      sig { params(opts: OptionParser, options: T::Hash[Symbol, Object]).void }
      def self.parse_tracking(opts, options)
        opts.on('--user_agent=A', String, 'User Agent') { |v| options[:user_agent] = T.cast(v, String) }
        opts.on('--jitter=F', Float, 'Randomize sleep') { |v| options[:jitter] = T.cast(v, Float) }
        opts.on('--track_status_codes', 'Track HTTP codes') { options[:track_status_codes] = true }
        parse_endpoints(opts, options)
        nil
      end

      # Parses IP binding, proxying, and ramp-up behavior.
      #
      # @param opts [OptionParser] the active parser instance
      # @param options [Hash] the configuration map to populate
      # @return [void]
      sig { params(opts: OptionParser, options: T::Hash[Symbol, Object]).void }
      def self.parse_endpoints(opts, options)
        opts.on('--ramp_up=S', Float, 'Smoothly scale') { |v| options[:ramp_up] = T.cast(v, Float) }
        opts.on('--bind_ips=IPS', String, 'IPs') { |v| options[:bind_ips] = split_list(T.cast(v, String)) }
        opts.on('--proxy_pool=U', String, 'URI pool') { |v| options[:proxy_pool] = split_list(T.cast(v, String)) }
        parse_slowloris(opts, options)
        nil
      end

      # Splits a comma-delimited CLI list, trimming whitespace and dropping empty
      # entries so that stray commas (e.g. `--url=,http://x` or `--url=`) can never
      # inject a blank token that later crashes URI/IP resolution.
      #
      # @param raw [String] the raw comma-separated flag value
      # @return [Array<String>] the cleaned list of non-empty tokens
      sig { params(raw: String).returns(T::Array[String]) }
      def self.split_list(raw)
        raw.split(',').map(&:strip).reject(&:empty?)
      end

      # Parses parameters triggering the slowloris strategy.
      #
      # @param opts [OptionParser] the active parser instance
      # @param options [Hash] the configuration map to populate
      # @return [void]
      sig { params(opts: OptionParser, options: T::Hash[Symbol, Object]).void }
      def self.parse_slowloris(opts, options)
        opts.on('--qps_per_connection=R', Integer, 'QPS') { |v| options[:qps_per_connection] = T.cast(v, Integer) }
        opts.on('--headers=L', String, 'Headers') { |v| parse_headers(T.cast(v, String), options) }
        parse_slowloris_delays(opts, options)
        nil
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
        key, value = val.split(':', 2)
        return warn("[Client] Ignoring malformed --headers entry (expected 'Key: Value'): #{val.inspect}") unless key && value

        key = key.strip
        value = value.strip
        return warn("[Client] Ignoring --headers entry with empty key: #{val.inspect}") if key.empty?
        return warn("[Client] Ignoring --headers entry with CR/LF: #{val.inspect}") if "#{key}#{value}".match?(/[\r\n]/)

        T.cast(options[:headers], T::Hash[String, String])[key] = value
      end

      # Parses granular delay configs specifically for slowloris payloads.
      #
      # @param opts [OptionParser] the active parser instance
      # @param options [Hash] the configuration map to populate
      # @return [void]
      sig { params(opts: OptionParser, options: T::Hash[Symbol, Object]).void }
      def self.parse_slowloris_delays(opts, options)
        opts.on('--slowloris_delay=S', Float, 'Gap') do |v|
          options[:slowloris_delay] = T.cast(v, Float)
        end
        opts.on('--export_json=FILE', String) { nil }
        opts.on('--target_duration=S', Float) { nil }
        nil
      end
    end

    # HarnessParser strictly parses orchestrator arguments ignoring explicitly mapped client arguments dynamically.
    class HarnessParser
      extend T::Sig

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
        nil
      end

      # Parses core connection args for harness.
      #
      # @param opts [OptionParser] option parser
      # @param options [Hash] map
      # @return [void]
      sig { params(opts: OptionParser, options: T::Hash[Symbol, Object]).void }
      def self.parse_harness_core(opts, options)
        opts.on('--connections_count=C', Integer) { |v| options[:connections] = T.cast(v, Integer) }
        opts.on('--https') { options[:use_https] = true }
        opts.on('--url=U', String) { |v| options[:target_urls] = ClientParser.split_list(T.cast(v, String)) }
      end

      # Parses extra settings for harness.
      #
      # @param opts [OptionParser] parser
      # @param options [Hash] map
      # @return [void]
      sig { params(opts: OptionParser, options: T::Hash[Symbol, Object]).void }
      def self.parse_harness_extras(opts, options)
        opts.on('--export_json=FILE', String) { |v| options[:export_json] = T.cast(v, String) }
        opts.on('--target_duration=S', Float) { |v| options[:target_duration] = T.cast(v, Float) }
      end

      # Client-only flags the harness accepts but ignores: it forwards the original argv to the
      # client subprocess verbatim, and only needs OptionParser not to reject these while it
      # extracts its own structural flags. Listing them as data (rather than one no-op handler
      # per flag) keeps the harness flag surface in one place with no duplicated method bodies.
      IGNORED_CLIENT_FLAGS = %w[
        --verbose --[no-]ping --ping_period=S --http_loader_timeout=S --connections_per_second=R
        --max_concurrent_connections=C --reopen_closed_connections --reopen_interval=S --read_timeout=S
        --user_agent=A --jitter=F --track_status_codes --ramp_up=S --bind_ips=IPS --proxy_pool=U
        --qps_per_connection=R --headers=LIST --slowloris_delay=S
      ].freeze

      # Registers a discarding handler for every client-only flag so OptionParser tolerates
      # them during the harness's own structural parse.
      #
      # @param opts [OptionParser] the active parser instance
      # @return [void]
      sig { params(opts: OptionParser).void }
      def self.ignore_core_args(opts)
        IGNORED_CLIENT_FLAGS.each { |flag| opts.on(flag) { nil } }
        nil
      end
    end
  end
end
