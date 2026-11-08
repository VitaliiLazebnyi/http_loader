# typed: strong
# frozen_string_literal: true

# Copyright (c) 2026 Vitalii Lazebnyi

require 'openssl'
require 'sorbet-runtime'
require_relative 'connection'
require_relative 'pacing'

# Primary namespace for the load testing framework.
module HttpLoader
  class Client
    # Handles deliberate thread-hogging Slowloris tactics.
    class Slowloris
      extend T::Sig

      # The connection's socket (TLS-wrapped for HTTPS).
      Socket = T.type_alias { T.any(IO, OpenSSL::SSL::SSLSocket) }
      private_constant :Socket

      # The raw text of an HTTP/1.1 GET request whose last header is deliberately left unfinished.
      #
      # @param uri [URI::Generic] the target
      # @param headers [Hash{String => String}] the request headers, after Host
      # @return [String] the incomplete request
      sig { params(uri: URI::Generic, headers: T::Hash[String, String]).returns(String) }
      def self.payload(uri, headers)
        lines = ["GET #{request_target(uri)} HTTP/1.1", "Host: #{uri.host}"]
        lines.concat(headers.map { |name, value| "#{name}: #{value}" })
        "#{lines.join("\r\n")}\r\nX-Slowloris: "
      end

      # The request target of a URI: its path, `/` when empty, and its query.
      #
      # @param uri [URI::Generic] the target
      # @return [String] e.g. "/search?q=1"
      sig { params(uri: URI::Generic).returns(String) }
      def self.request_target(uri)
        path = T.must(uri.path)
        path = '/' if path.empty?
        query = uri.query
        query ? "#{path}?#{query}" : path
      end

      # Builds the slowloris execution strategy instance.
      #
      # @param config [Config] the validated config parameters
      # @param logger [Logger] the isolated asynchronous log context
      # @return [void]
      sig { params(config: Config, logger: Logger).void }
      def initialize(config, logger)
        @config = config
        @logger = logger
      end

      # Engages the slowloris thread hold directly manipulating the raw socket bypassing HTTP standards.
      #
      # @param connection [Connection] the open connection
      # @return [void]
      sig { params(connection: Connection).void }
      def run(connection)
        return if @config.slowloris_delay <= 0.0

        io = T.cast(connection.http.instance_variable_get(:@socket), T.nilable(Net::BufferedIO))&.io
        return unless io

        trickle(io, Slowloris.payload(connection.uri, @config.request_headers))
        hold(connection, io)
      end

      private

      # Writes the payload one character at a time, pacing before each but the first, so that no pause
      # follows the final character (#hold paces its own bytes).
      #
      # @param io [IO, OpenSSL::SSL::SSLSocket] the connection's socket
      # @param payload [String] the incomplete request
      # @return [void]
      sig { params(io: Socket, payload: String).void }
      def trickle(io, payload)
        payload.chars.each_with_index do |char, index|
          sleep(Pacing.jittered_interval(@config.slowloris_delay, @config.jitter)) if index.positive?
          io.write(char)
          io.flush
        end
      end

      # Keeps the socket occupied with a random letter every (jittered) delay until the keep-alive budget is
      # spent.
      #
      # @param connection [Connection] the open connection
      # @param io [IO, OpenSSL::SSL::SSLSocket] the connection's socket
      # @return [void]
      sig { params(connection: Connection, io: Socket).void }
      def hold(connection, io)
        loop do
          remaining = Pacing.budget_remaining(@config.http_loader_timeout, connection.started)
          break if Pacing.budget_spent?(remaining)

          nudge(io, remaining)
        end
        @logger.info("#{connection.label} Keep-alive timeout reached, closing Slowloris thread.")
      end

      # Writes one random letter, then waits one (jittered) delay, capped to the remaining budget.
      #
      # @param io [IO, OpenSSL::SSL::SSLSocket] the connection's socket
      # @param remaining [Float, nil] the remaining keep-alive budget in seconds, or nil if unbounded
      # @return [void]
      sig { params(io: Socket, remaining: T.nilable(Float)).void }
      def nudge(io, remaining)
        io.write(rand(97..122).chr)
        io.flush
        sleep(Pacing.cap_to_budget(Pacing.jittered_interval(@config.slowloris_delay, @config.jitter), remaining))
      end
    end
  end
end
