# typed: strong
# frozen_string_literal: true

# Copyright (c) 2026 Vitalii Lazebnyi

require 'net/http'
require 'sorbet-runtime'
require 'uri'

# Primary namespace for the load testing framework.
module HttpLoader
  class Client
    # One open connection of a worker, as the sessions drive it: the worker's index, the target, the
    # Net::HTTP session and when the connection was opened (the start of its keep-alive budget).
    class Connection < T::Struct
      extend T::Sig

      const :index, Integer
      const :uri, URI::Generic
      const :http, Net::HTTP
      const :started, Time

      # The prefix of every log line about this connection.
      #
      # @return [String] e.g. "[Client 3]"
      sig { returns(String) }
      def label
        "[Client #{index}]"
      end
    end
  end
end
