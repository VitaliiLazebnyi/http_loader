# typed: strong
# frozen_string_literal: true

# Copyright (c) 2026 Vitalii Lazebnyi

require 'sorbet-runtime'

# Primary namespace for the load testing framework.
module HttpLoader
  # Subsystem responsible for generating concurrent load.
  class Client
    # Configuration parameters strictly validated by Sorbet for Client connections.
    class Config < T::Struct
      extend T::Sig

      # The lower bound of a numeric setting, and the flag that sets it.
      class Bound < T::Struct
        extend T::Sig

        const :flag, String
        # Whether zero is valid: for these settings, zero disables the feature.
        const :zero_allowed, T::Boolean

        # Rejects a value below the bound.
        #
        # @param value [Numeric] the value of the setting
        # @raise [ArgumentError] if the value is below the bound
        # @return [void]
        sig { params(value: Numeric).void }
        def check(value)
          return if value.positive? || (zero_allowed && value.zero?)

          raise(ArgumentError, "--#{flag} #{requirement} (got #{value})")
        end

        # @return [String] what the bound requires of a value
        sig { returns(String) }
        def requirement
          zero_allowed ? 'must not be negative' : 'must be greater than 0'
        end
      end

      const :connections, Integer
      const :target_urls, T::Array[String], default: []
      const :use_https, T::Boolean, default: false
      const :verbose, T::Boolean, default: false
      const :ping, T::Boolean, default: true
      const :ping_period, Float, default: 5.0
      const :http_loader_timeout, Float, default: 0.0
      const :connections_per_second, Integer, default: 0
      const :max_concurrent_connections, Integer, default: 1000
      const :reopen_closed_connections, T::Boolean, default: false
      const :reopen_interval, Float, default: 5.0
      const :read_timeout, Float, default: 0.0
      const :user_agent, String, default: 'Keep-Alive Test'
      const :jitter, Float, default: 1.0
      const :track_status_codes, T::Boolean, default: false
      const :ramp_up, Float, default: 0.0
      const :bind_ips, T::Array[String], default: []
      const :proxy_pool, T::Array[String], default: []
      const :qps_per_connection, Integer, default: 0
      const :headers, T::Hash[String, String], default: {}
      const :slowloris_delay, Float, default: 0.0

      # The bound of every numeric setting, checked by #validate in this order.
      BOUNDS = T.let(
        {
          connections: Bound.new(flag: 'connections_count', zero_allowed: false),
          max_concurrent_connections: Bound.new(flag: 'max_concurrent_connections', zero_allowed: false),
          ping_period: Bound.new(flag: 'ping_period', zero_allowed: false),
          http_loader_timeout: Bound.new(flag: 'http_loader_timeout', zero_allowed: true),
          connections_per_second: Bound.new(flag: 'connections_per_second', zero_allowed: true),
          reopen_interval: Bound.new(flag: 'reopen_interval', zero_allowed: true),
          read_timeout: Bound.new(flag: 'read_timeout', zero_allowed: true),
          ramp_up: Bound.new(flag: 'ramp_up', zero_allowed: true),
          jitter: Bound.new(flag: 'jitter', zero_allowed: true),
          qps_per_connection: Bound.new(flag: 'qps_per_connection', zero_allowed: true),
          slowloris_delay: Bound.new(flag: 'slowloris_delay', zero_allowed: true)
        }.freeze,
        T::Hash[Symbol, Bound]
      )
      public_constant :BOUNDS

      # Enforces the REQ-CLI-023 numeric bounds beyond Sorbet's type checks, raising
      # ArgumentError so the CLI entrypoint can render a clean "Configuration Error"
      # fast-fail instead of hanging or crashing with an uncaught backtrace.
      #
      # @raise [ArgumentError] if any numeric parameter is out of bounds
      # @return [void]
      sig { void }
      def validate
        BOUNDS.each { |name, bound| bound.check(T.cast(public_send(name), Numeric)) }
        warn_on_oversubscription
      end

      # The headers of every request: keep-alive, the User-Agent, then the `--headers` ones, which
      # replace a default of the same name.
      #
      # @return [Hash{String => String}] the header names and values, in sending order
      sig { returns(T::Hash[String, String]) }
      def request_headers
        { 'Connection' => 'keep-alive', 'User-Agent' => user_agent }.merge(headers)
      end

      private

      # Warns when more connections are requested than the concurrency semaphore permits.
      # In keep-alive modes each permit is held for the connection's lifetime, so the
      # surplus connections would be parked indefinitely and never opened.
      #
      # @return [void]
      sig { void }
      def warn_on_oversubscription
        return if connections <= max_concurrent_connections

        warn(
          "[Client] Warning: --connections_count (#{connections}) exceeds " \
            "--max_concurrent_connections (#{max_concurrent_connections}); " \
            'surplus connections are queued and, in keep-alive modes, may never open.'
        )
      end
    end
  end
end
