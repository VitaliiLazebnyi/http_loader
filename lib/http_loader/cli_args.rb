# typed: strong
# frozen_string_literal: true

require "sorbet-runtime"
require "optparse"

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
        opts.on('--connections_count=COUNT', Integer, 'Total') do |v|
          options[:connections] = T.cast(v, Integer)
        end
        opts.on('--https', 'Use HTTPS natively') do
          options[:use_https] = true
        end
        opts.on('--url=URL', String, 'URLs') do |v|
          options[:target_urls] = T.cast(v, String).split(',')
        end
        opts.on('--verbose', 'Verbose logging') do
          options[:verbose] = true
        end
        nil
      end

      # Parses ping enablement and intervals.
      #
      # @param opts [OptionParser] the active parser instance
      # @param options [Hash] the configuration map to populate
      # @return [void]
      sig { params(opts: OptionParser, options: T::Hash[Symbol, Object]).void }
      def self.parse_ping(opts, options)
        opts.on('--[no-]ping', 'Ping') do |v|
          options[:ping] = T.cast(v, T::Boolean)
        end
        opts.on('--ping_period=SECONDS', Integer, 'Ping period') do |v|
          options[:ping_period] = T.cast(v, Integer)
        end
        nil
      end

      # Parses timeout, rate-limiting, and concurrency thresholds.
      #
      # @param opts [OptionParser] the active parser instance
      # @param options [Hash] the configuration map to populate
      # @return [void]
      sig { params(opts: OptionParser, options: T::Hash[Symbol, Object]).void }
      def self.parse_timeouts(opts, options)
        opts.on('--http_loader_timeout=S', Float, 'Keep') do |v|
          options[:http_loader_timeout] = T.cast(v, Float)
        end
        opts.on('--connections_per_second=R', Integer, 'Rate') do |v|
          options[:connections_per_second] = T.cast(v, Integer)
        end
        opts.on('--max_concurrent_connections=C', Integer, 'Max') do |v|
          options[:max_concurrent_connections] = T.cast(v, Integer)
        end
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
        opts.on('--reopen_closed_connections', 'Reopen') do
          options[:reopen_closed_connections] = true
        end
        opts.on('--reopen_interval=S', Float, 'Reopen delay') do |v|
          options[:reopen_interval] = T.cast(v, Float)
        end
        opts.on('--read_timeout=S', Float, 'Read timeout') do |v|
          options[:read_timeout] = T.cast(v, Float)
        end
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
        opts.on('--user_agent=A', String, 'User Agent') do |v|
          options[:user_agent] = T.cast(v, String)
        end
        opts.on('--jitter=F', Float, 'Randomize sleep') do |v|
          options[:jitter] = T.cast(v, Float)
        end
        opts.on('--track_status_codes', 'Track HTTP codes') do
          options[:track_status_codes] = true
        end
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
        opts.on('--ramp_up=S', Float, 'Smoothly scale') do |val|
          options[:ramp_up] = T.cast(val, Float)
        end
        opts.on('--bind_ips=IPS', String, 'IPs') do |val|
          options[:bind_ips] = T.cast(val, String).split(',')
        end
        opts.on('--proxy_pool=U', String, 'URI pool') do |val|
          options[:proxy_pool] = T.cast(val, String).split(',')
        end
        parse_slowloris(opts, options)
        nil
      end

      # Parses parameters triggering the slowloris strategy.
      #
      # @param opts [OptionParser] the active parser instance
      # @param options [Hash] the configuration map to populate
      # @return [void]
      sig { params(opts: OptionParser, options: T::Hash[Symbol, Object]).void }
      def self.parse_slowloris(opts, options)
        opts.on('--qps_per_connection=R', Integer, 'Active QPS') do |val|
          options[:qps_per_connection] = T.cast(val, Integer)
        end
        opts.on('--headers=LIST', String, 'Headers') do |val|
          T.cast(val, String).split(',').each do |pair|
            key, value = pair.split(':', 2)
            headers = T.cast(options[:headers], T::Hash[String, String])
            headers[key.strip] = value.strip if key && value
          end
        end
        parse_slowloris_delays(opts, options)
        nil
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
        opts.on('--connections_count=C', Integer) do |v|
          options[:connections] = T.cast(v, Integer)
        end
        opts.on('--https') do
          options[:use_https] = true
        end
        opts.on('--url=URL', String) do |v|
          options[:target_urls] = T.cast(v, String).split(',')
        end
        opts.on('--export_json=FILE', String) do |v|
          options[:export_json] = T.cast(v, String)
        end
        opts.on('--target_duration=S', Float) do |v|
          options[:target_duration] = T.cast(v, Float)
        end
        ignore_core_args(opts)
        nil
      end

      # Binds OptionParser NO-OP lambdas for core args.
      #
      # @param opts [OptionParser] the active parser instance
      # @return [void]
      sig { params(opts: OptionParser).void }
      def self.ignore_core_args(opts)
        opts.on('--verbose') { nil }
        opts.on('--[no-]ping') { nil }
        opts.on('--ping_period=S', Integer) { nil }
        opts.on('--http_loader_timeout=S', Float) { nil }
        opts.on('--connections_per_second=R', Integer) { nil }
        ignore_time_args(opts)
        nil
      end

      # Binds OptionParser NO-OP lambdas for timing variables.
      #
      # @param opts [OptionParser] the active parser instance
      # @return [void]
      sig { params(opts: OptionParser).void }
      def self.ignore_time_args(opts)
        opts.on('--max_concurrent_connections=C', Integer) { nil }
        opts.on('--reopen_closed_connections') { nil }
        opts.on('--reopen_interval=S', Float) { nil }
        opts.on('--read_timeout=S', Float) { nil }
        opts.on('--user_agent=A', String) { nil }
        ignore_advanced_args(opts)
        nil
      end

      # Binds OptionParser NO-OP lambdas for advanced connection variables.
      #
      # @param opts [OptionParser] the active parser instance
      # @return [void]
      sig { params(opts: OptionParser).void }
      def self.ignore_advanced_args(opts)
        opts.on('--jitter=F', Float) { nil }
        opts.on('--track_status_codes') { nil }
        opts.on('--ramp_up=S', Float) { nil }
        opts.on('--bind_ips=IPS', String) { nil }
        opts.on('--proxy_pool=U', String) { nil }
        ignore_payload_args(opts)
        nil
      end

      # Binds OptionParser NO-OP lambdas for slowloris and HTTP headers variables.
      #
      # @param opts [OptionParser] the active parser instance
      # @return [void]
      sig { params(opts: OptionParser).void }
      def self.ignore_payload_args(opts)
        opts.on('--qps_per_connection=R', Integer) { nil }
        opts.on('--headers=LIST', String) { nil }
        opts.on('--slowloris_delay=S', Float) { nil }
        nil
      end
    end
  end
end
