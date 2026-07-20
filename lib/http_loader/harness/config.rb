# typed: strong
# frozen_string_literal: true

require 'sorbet-runtime'

# Primary namespace for the load testing framework.
module HttpLoader
  # Harness orchestrates the entire load testing lifecycle seamlessly and securely.
  class Harness
    # Config parameters for Harness manager execution natively validated structurally via Sorbet.
    class Config < T::Struct
      extend T::Sig

      const :connections, Integer
      const :target_urls, T::Array[String], default: []
      const :use_https, T::Boolean, default: false
      const :client_args, T::Array[String], default: []
      const :export_json, T.nilable(String), default: nil
      const :target_duration, Float, default: 0.0

      # Enforces REQ-CLI-023 numeric bounds for the orchestrator, raising ArgumentError
      # so the CLI entrypoint renders a clean "Configuration Error".
      #
      # @raise [ArgumentError] if connections or target_duration are out of bounds
      # @return [void]
      sig { void }
      def validate!
        raise ArgumentError, "--connections_count must be greater than 0 (got #{connections})" unless connections.positive?
        raise ArgumentError, "--target_duration must not be negative (got #{target_duration})" if target_duration < 0.0

        nil
      end
    end
  end
end
