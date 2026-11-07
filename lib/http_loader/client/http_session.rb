# typed: strong
# frozen_string_literal: true

# Copyright (c) 2026 Vitalii Lazebnyi

require 'net/http'
require 'sorbet-runtime'
require_relative 'connection'
require_relative 'pacing'

# Primary namespace for the load testing framework.
module HttpLoader
  class Client
    # Handles normal and QPS-driven HTTP keep-alive connections.
    class HttpSession
      extend T::Sig

      # The request class of a heartbeat: GET under a QPS rate, HEAD for a ping.
      RequestClass = T.type_alias { T.class_of(Net::HTTPRequest) }
      private_constant :RequestClass

      # What a heartbeat does: wait the interval, then send a request of the class, if any.
      class Heartbeat < T::Struct
        const :interval, Float
        const :request_class, T.nilable(T.class_of(Net::HTTPRequest)), default: nil
      end
      private_constant :Heartbeat

      # A request of the given class to the URI, carrying the headers in order.
      #
      # @param request_class [Class<Net::HTTPRequest>] Net::HTTP::Get or Net::HTTP::Head
      # @param uri [URI::Generic] the target
      # @param headers [Hash{String => String}] the request headers
      # @return [Net::HTTPRequest] the request
      sig do
        params(
          request_class: RequestClass,
          uri: URI::Generic,
          headers: T::Hash[String, String]
        ).returns(Net::HTTPRequest)
      end
      def self.request(request_class, uri, headers)
        request = request_class.new(uri)
        headers.each { |name, value| request[name] = value }
        request
      end

      # Whether a response counts as a success: a 2xx or a 3xx.
      #
      # @param response [Net::HTTPResponse] the response
      # @return [Boolean] true for a success or a redirection
      sig { params(response: Net::HTTPResponse).returns(T::Boolean) }
      def self.success?(response)
        response.is_a?(Net::HTTPSuccess) || response.is_a?(Net::HTTPRedirection)
      end

      # Constructs a new HTTP pooling session instance.
      #
      # @param config [Config] core runtime rules configuration
      # @param logger [Logger] the thread-safe async logger context
      # @return [void]
      sig { params(config: Config, logger: Logger).void }
      def initialize(config, logger)
        @config = config
        @logger = logger
      end

      # Sends the initial GET, then keeps the connection alive until its budget is spent or a heartbeat fails.
      # The initial request has no block: Net::HTTP reads (and so drains) the whole body, keeping the
      # keep-alive connection reusable.
      #
      # @param connection [Connection] the open connection
      # @return [void]
      sig { params(connection: Connection).void }
      def run(connection)
        connection.http.request(HttpSession.request(Net::HTTP::Get, connection.uri, @config.request_headers))
        keep_alive(connection)
      end

      private

      # Runs heartbeats until the keep-alive budget is spent (logged) or one of them fails.
      #
      # @param connection [Connection] the open connection
      # @return [void]
      sig { params(connection: Connection).void }
      def keep_alive(connection)
        loop do
          remaining = Pacing.budget_remaining(@config.http_loader_timeout, connection.started)
          if Pacing.budget_spent?(remaining)
            break @logger.info("#{connection.label} Keep-alive timeout reached, closing.")
          end
          break unless heartbeat?(connection, remaining)
        end
      end

      # Waits one heartbeat interval (capped to the remaining budget), then sends the heartbeat request, if any.
      #
      # @param connection [Connection] the open connection
      # @param remaining [Float, nil] the remaining keep-alive budget in seconds, or nil if unbounded
      # @return [Boolean] whether the connection stays open: false after a failed request
      sig { params(connection: Connection, remaining: T.nilable(Float)).returns(T::Boolean) }
      def heartbeat?(connection, remaining)
        beat = heartbeat
        request_class = beat.request_class
        sleep(Pacing.cap_to_budget(Pacing.jittered_interval(beat.interval, @config.jitter), remaining))
        request_class ? request?(connection, request_class) : true
      end

      # The heartbeat interval and request: a GET every 1/QPS seconds under a QPS rate, else a HEAD every
      # ping period when pings are on, else no request, every second.
      #
      # @return [Heartbeat] the interval in seconds and the request class
      sig { returns(Heartbeat) }
      def heartbeat
        qps = @config.qps_per_connection
        if qps.positive?
          Heartbeat.new(interval: 1.0 / qps, request_class: Net::HTTP::Get)
        elsif @config.ping
          Heartbeat.new(interval: @config.ping_period, request_class: Net::HTTP::Head)
        else
          Heartbeat.new(interval: 1.0)
        end
      end

      # Sends one heartbeat request and logs a failed response when status codes are tracked.
      #
      # @param connection [Connection] the open connection
      # @param request_class [Class<Net::HTTPRequest>] Net::HTTP::Get or Net::HTTP::Head
      # @return [Boolean] whether the response is a success
      sig { params(connection: Connection, request_class: RequestClass).returns(T::Boolean) }
      def request?(connection, request_class)
        request = HttpSession.request(request_class, connection.uri, @config.request_headers)
        response = T.cast(connection.http.request(request), Net::HTTPResponse)
        success = HttpSession.success?(response)
        log_failure(connection, response) unless success
        success
      end

      # Logs a failed response when status codes are tracked.
      #
      # @param connection [Connection] the open connection
      # @param response [Net::HTTPResponse] the failed response
      # @return [void]
      sig { params(connection: Connection, response: Net::HTTPResponse).void }
      def log_failure(connection, response)
        @logger.status("#{connection.label} Upstream returned HTTP #{response.code}") if @config.track_status_codes
      end
    end
  end
end
