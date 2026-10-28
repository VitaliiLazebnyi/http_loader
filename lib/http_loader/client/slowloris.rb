# typed: strong
# frozen_string_literal: true

require 'sorbet-runtime'

# Primary namespace for the load testing framework.
module HttpLoader
  class Client
    # Handles deliberate thread-hogging Slowloris tactics.
    class Slowloris
      extend T::Sig
      include Pacing

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
      # @param client_index [Integer] numeric unique identifier for this virtual client
      # @param uri [URI::Generic] the parsed target destination
      # @param http [Net::HTTP] instantiated http connection payload
      # @param start_time [Time] context timestamp determining lifespan violations
      # @return [void]
      sig { params(client_index: Integer, uri: URI::Generic, http: Net::HTTP, start_time: Time).void }
      def run(client_index, uri, http, start_time)
        return unless @config.slowloris_delay > 0.0

        socket_wrapper = T.cast(http.instance_variable_get(:@socket), T.nilable(Net::BufferedIO))
        return unless socket_wrapper

        io = socket_wrapper.io
        fire_initial_payload(io, uri)
        maintain_hold(client_index, io, start_time)
      end

      private

      # Writes the HTTP payload character by character with configurable artificial delay constraints.
      #
      # @param io [IO] the physical IO bound socket instance
      # @param uri [URI::Generic] the targeted request identifier
      # @return [void]
      sig { params(io: IO, uri: URI::Generic).void }
      def fire_initial_payload(io, uri)
        chars = build_payload_headers(uri).chars
        last = chars.size - 1

        chars.each_with_index do |char, i|
          io.write(char)
          io.flush
          # No trailing pause after the final byte; maintain_hold immediately paces the
          # subsequent keep-alive bytes, so an extra sleep here is redundant.
          sleep(jittered_interval(@config.slowloris_delay, @config.jitter)) unless i == last
        end
      end

      # Crafts the raw text representing a completely viable HTTP/1.1 payload excluding finalizing line-breaks.
      #
      # @param uri [URI::Generic] the targeted parameters identifier
      # @return [String] the string representation of an artificially incomplete payload request
      sig { params(uri: URI::Generic).returns(String) }
      def build_payload_headers(uri)
        path = T.must(uri.path).empty? ? '/' : uri.path
        query = uri.query ? "?#{uri.query}" : ''
        payload = "GET #{path}#{query} HTTP/1.1\r\n" \
                  "Host: #{uri.host}\r\n" \
                  "Connection: keep-alive\r\n" \
                  "User-Agent: #{@config.user_agent}\r\n"
        @config.headers.each { |k, v| payload += "#{k}: #{v}\r\n" }
        payload += 'X-Slowloris: ' # unfinished header
        payload
      end

      # Keeps an ongoing socket indefinitely occupied via sporadic random byte injection.
      #
      # @param client_index [Integer] numeric connection index used by logging
      # @param io [IO] underlying network IO byte writer
      # @param start_time [Time] lifecycle origination period
      # @return [void]
      sig { params(client_index: Integer, io: IO, start_time: Time).void }
      def maintain_hold(client_index, io, start_time)
        loop do
          remaining = budget_remaining(@config.http_loader_timeout, start_time)
          if remaining && remaining <= 0.0
            @logger.info("[Client #{client_index}] Keep-alive timeout reached, closing Slowloris thread.")
            break
          end

          io.write(rand(97..122).chr)
          io.flush
          sleep(cap_to_budget(jittered_interval(@config.slowloris_delay, @config.jitter), remaining))
        end
      end
    end
  end
end
