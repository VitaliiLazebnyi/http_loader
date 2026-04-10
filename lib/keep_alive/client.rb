# typed: strict
# frozen_string_literal: true

require 'sorbet-runtime'
require 'net/http'
require 'uri'
require 'openssl'
require 'async'

module KeepAlive
  class Client
    extend T::Sig

    sig { params(connections: Integer, target_url: T.nilable(String), use_https: T::Boolean).void }
    def initialize(connections:, target_url: nil, use_https: false)
      @connections = connections
      @use_https = use_https
      @target_url = target_url
      @uri = T.let(determine_uri, URI::Generic)
      @http_args = T.let(determine_http_args, T::Hash[Symbol, T.untyped])
      @protocol_label = T.let(determine_protocol_label, String)
      @error_log = T.let(Mutex.new, Mutex)
    end

    sig { void }
    def start
      puts "[Client] Starting #{@connections} #{@protocol_label} connections to #{@uri}..."
      puts '[Client] Note: Output of individual pings is suppressed to avoid console spam.'

      trap('INT') { exit(0) }

      # Create/truncate log files deterministically
      File.write('client.err', '')

      Async do |task|
        @connections.times do |i|
          task.async do
            execute_connection(i)
          end
        end
      end
    end

    private

    sig { returns(URI::Generic) }
    def determine_uri
      if @target_url
        URI(@target_url.to_s)
      elsif @use_https
        URI('https://localhost:8443')
      else
        URI('http://localhost:8080')
      end
    end

    sig { returns(String) }
    def determine_protocol_label
      if @target_url
        "EXTERNAL #{@uri.scheme&.upcase}"
      elsif @use_https
        'HTTPS'
      else
        'HTTP'
      end
    end

    sig { returns(T::Hash[Symbol, T.untyped]) }
    def determine_http_args
      if @uri.scheme == 'https'
        { use_ssl: true, verify_mode: OpenSSL::SSL::VERIFY_NONE, read_timeout: nil }
      else
        { read_timeout: nil }
      end
    end

    sig { params(client_index: Integer).void }
    def execute_connection(client_index)
      Net::HTTP.start(T.must(@uri.host), @uri.port, **@http_args) do |http|
        request = Net::HTTP::Get.new(@uri)
        request['Connection'] = 'keep-alive'

        http.request(request) do |response|
          response.read_body do |_chunk|
            # Suppressed payload output
          end
        end

        loop do
          sleep(5)
          ping_request = Net::HTTP::Head.new(@uri)
          ping_request['Connection'] = 'keep-alive'
          response = http.request(ping_request)
          break unless response.is_a?(Net::HTTPSuccess) || response.is_a?(Net::HTTPRedirection)
        end
      end
    rescue Errno::EMFILE => e
      log_error("[Client #{client_index}] ERROR_EMFILE: #{e.message}")
    rescue Errno::EADDRNOTAVAIL
      log_error("[Client #{client_index}] ERROR_EADDRNOTAVAIL: Ephemeral port limit reached.")
    rescue StandardError => e
      log_error("[Client #{client_index}] ERROR_OTHER: #{e.message}")
    end

    sig { params(message: String).void }
    def log_error(message)
      @error_log.synchronize do
        File.open('client.err', 'a') { |f| f.puts(message) }
      end
    end
  end
end
