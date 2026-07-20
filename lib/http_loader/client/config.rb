# typed: strong
# frozen_string_literal: true

require 'sorbet-runtime'

# Primary namespace for the load testing framework.
module HttpLoader
  # Subsystem responsible for generating concurrent load.
  class Client
    # Configuration parameters strictly validated by Sorbet for Client connections.
    class Config < T::Struct
      extend T::Sig

      const :connections, Integer
      const :target_urls, T::Array[String], default: []
      const :use_https, T::Boolean, default: false
      const :verbose, T::Boolean, default: false
      const :ping, T::Boolean, default: true
      const :ping_period, Integer, default: 5
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

      # Enforces the REQ-CLI-023 numeric bounds beyond Sorbet's type checks, raising
      # ArgumentError so the CLI entrypoint can render a clean "Configuration Error"
      # fast-fail instead of hanging or crashing with an uncaught backtrace.
      #
      # @raise [ArgumentError] if any numeric parameter is out of bounds
      # @return [void]
      sig { void }
      def validate!
        validate_positive_bounds
        validate_non_negative_bounds
        warn_on_oversubscription
        nil
      end

      private

      # Rejects the parameters that must be strictly greater than zero.
      #
      # @return [void]
      sig { void }
      def validate_positive_bounds
        require_positive!(:connections_count, connections)
        require_positive!(:max_concurrent_connections, max_concurrent_connections)
        require_positive!(:ping_period, ping_period)
      end

      # Rejects the parameters that must not be negative (zero disables the feature).
      #
      # @return [void]
      sig { void }
      def validate_non_negative_bounds
        require_non_negative!(:http_loader_timeout, http_loader_timeout)
        require_non_negative!(:connections_per_second, connections_per_second)
        require_non_negative!(:reopen_interval, reopen_interval)
        require_non_negative!(:read_timeout, read_timeout)
        require_non_negative!(:ramp_up, ramp_up)
        require_non_negative!(:jitter, jitter)
        require_non_negative!(:qps_per_connection, qps_per_connection)
        require_non_negative!(:slowloris_delay, slowloris_delay)
      end

      # Rejects a parameter that must be strictly greater than zero.
      #
      # @param name [Symbol] the user-facing flag name
      # @param value [Numeric] the supplied value
      # @return [void]
      sig { params(name: Symbol, value: Numeric).void }
      def require_positive!(name, value)
        return if value.to_f > 0.0

        raise ArgumentError, "--#{name} must be greater than 0 (got #{value})"
      end

      # Rejects a parameter that must not be negative (zero is a valid "disabled" sentinel).
      #
      # @param name [Symbol] the user-facing flag name
      # @param value [Numeric] the supplied value
      # @return [void]
      sig { params(name: Symbol, value: Numeric).void }
      def require_non_negative!(name, value)
        return unless value.to_f < 0.0

        raise ArgumentError, "--#{name} must not be negative (got #{value})"
      end

      # Warns when more connections are requested than the concurrency semaphore permits.
      # In keep-alive modes each permit is held for the connection's lifetime, so the
      # surplus connections would be parked indefinitely and never opened.
      #
      # @return [void]
      sig { void }
      def warn_on_oversubscription
        return unless connections > max_concurrent_connections

        warn "[Client] Warning: --connections_count (#{connections}) exceeds " \
             "--max_concurrent_connections (#{max_concurrent_connections}); " \
             'surplus connections are queued and, in keep-alive modes, may never open.'
      end
    end
  end
end
