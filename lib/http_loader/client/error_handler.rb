# typed: strong
# frozen_string_literal: true

require 'sorbet-runtime'

# Primary namespace for the load testing framework.
module HttpLoader
  # Subsystem responsible for generating concurrent load.
  class Client
    # Module providing error handling logic for connection failures during load generation.
    module ErrorHandler
      extend T::Sig
      extend T::Helpers

      requires_ancestor { HttpLoader::Client }

      # Logs detailed information for client connection errors, identifying specific OS-level socket exhaustion.
      #
      # @param idx [Integer] the unique identifier of the connection context
      # @param err [StandardError] the caught exception occurring during the request execution
      # @return [void]
      sig { params(idx: Integer, err: StandardError).void }
      def handle_err(idx, err)
        client = T.cast(self, HttpLoader::Client)
        case err
        when Errno::EMFILE
          client.logger.error("[Client #{idx}] ERROR_EMFILE: #{err.message}")
        when Errno::EADDRNOTAVAIL
          client.logger.error("[Client #{idx}] ERROR_EADDRNOTAVAIL: Ephemeral port limit reached.")
        else
          client.logger.error("[Client #{idx}] ERROR_OTHER: #{err.message}")
        end
      end
    end
  end
end
