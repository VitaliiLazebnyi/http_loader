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
        T.cast(self, HttpLoader::Client).logger.error("[Client #{idx}] #{classify_error(err)}")
      end

      # Maps a caught exception to its telemetry-tracked error token and message. The
      # tokens (ERROR_EMFILE / ERROR_EADDRNOTAVAIL / ERROR_THREADLIMIT / ERROR_OTHER)
      # are what the harness Telemetry scans for when reporting OS bottlenecks.
      #
      # @param err [StandardError] the caught exception
      # @return [String] the classified "TOKEN: message" string
      sig { params(err: StandardError).returns(String) }
      def classify_error(err)
        case err
        when Errno::EMFILE then "ERROR_EMFILE: #{err.message}"
        when Errno::EADDRNOTAVAIL then 'ERROR_EADDRNOTAVAIL: Ephemeral port limit reached.'
        when ThreadError, Errno::EAGAIN then "ERROR_THREADLIMIT: #{err.message}"
        else "ERROR_OTHER: #{err.message}"
        end
      end
    end
  end
end
