# typed: strong
# frozen_string_literal: true

# Copyright (c) 2026 Vitalii Lazebnyi

require 'async'
require 'falcon/server'
require 'io/endpoint/host_endpoint'
require 'io/endpoint/ssl_endpoint'
require 'ipaddr'
require 'openssl'
require 'protocol/rack/adapter'
require 'rack'
require 'rackup'
require 'rackup/handler/falcon'
require 'socket'
require 'sorbet-runtime'

# Primary namespace for the load testing framework.
module HttpLoader
  # Server provides a lightweight, natively asynchronous HTTP/HTTPS mock endpoint
  class Server
    extend T::Sig

    # The Rack application signature: a callable taking the env hash and returning the
    # `[status, headers, body]` triple. A static type, checked by `srb tc`.
    RackApp =
      T.type_alias do
        T.proc.params(env: T::Hash[String, Object]).returns([Integer, T::Hash[String, String], T::Array[String]])
      end
    private_constant :RackApp

    # The address that binds every IPv4 interface (INADDR_ANY), so that remote load generators can connect.
    BIND_ADDRESS = T.let(IPAddr.new(Socket::INADDR_ANY, Socket::AF_INET).to_s, String)
    private_constant :BIND_ADDRESS

    # A self-signed TLS context for localhost, with a new 2048-bit RSA key.
    #
    # @return [OpenSSL::SSL::SSLContext] the context
    sig { returns(OpenSSL::SSL::SSLContext) }
    def self.ssl_context
      rsa = T.cast(OpenSSL::PKey::RSA.new(2048), OpenSSL::PKey::RSA)
      context = OpenSSL::SSL::SSLContext.new
      context.cert = certificate(rsa)
      context.key = rsa
      context
    end

    # Allocates the Rack mapped mock layer simulating an identical, ultra-efficient mock endpoint.
    #
    # @param https [Boolean] whether to serve HTTPS (on 8443, with an ephemeral self-signed certificate) rather
    #   than plain HTTP (on 8080)
    # @return [void]
    sig { params(https: T::Boolean).void }
    def initialize(https:)
      @https = https
      @app = T.let(
        proc do |_env|
          [200, { 'content-type' => 'text/plain', 'content-length' => '2' }, ['OK']]
        end,
        RackApp
      )
    end

    # Serves until interrupted: HTTPS on 8443, or plain HTTP on 8080.
    #
    # @return [void]
    sig { void }
    def start
      @https ? start_secure(8443) : start_plaintext(8080)
    end

    # A certificate for localhost, valid for a year from now, self-signed with the key.
    #
    # @param rsa [OpenSSL::PKey::RSA] the key
    # @return [OpenSSL::X509::Certificate] the signed certificate
    sig { params(rsa: OpenSSL::PKey::RSA).returns(OpenSSL::X509::Certificate) }
    def self.certificate(rsa)
      cert = OpenSSL::X509::Certificate.new
      identify(cert)
      validity(cert, Time.now)
      cert.public_key = rsa.public_key
      T.cast(cert.sign(rsa, OpenSSL::Digest.new('SHA256')), OpenSSL::X509::Certificate)
    end

    # Names localhost as the subject and the issuer of a certificate, an X.509 v3 one with serial number 1.
    #
    # @param cert [OpenSSL::X509::Certificate] the certificate
    # @return [void]
    sig { params(cert: OpenSSL::X509::Certificate).void }
    def self.identify(cert)
      cert.subject = cert.issuer = OpenSSL::X509::Name.parse('/CN=localhost')
      cert.serial = 1
      cert.version = 2
    end

    # Makes a certificate valid for a year (365 days) from a time.
    #
    # @param cert [OpenSSL::X509::Certificate] the certificate
    # @param now [Time] the start of the validity
    # @return [void]
    sig { params(cert: OpenSSL::X509::Certificate, now: Time).void }
    def self.validity(cert, now)
      cert.not_before = now
      cert.not_after = now + (365 * 24 * 60 * 60)
    end

    private_class_method :certificate, :identify, :validity

    private

    # Binds securely over HTTPS natively bypassing normal HTTP routing constraints dynamically.
    #
    # @param port [Integer] local physical OS target port
    # @return [void]
    sig { params(port: Integer).void }
    def start_secure(port)
      puts("[Server] Binding natively to HTTPS over port #{port}")
      ssl_context = Server.ssl_context

      Sync do |_raw_task|
        run_falcon(port, ssl_context)
      end
    end

    # Orchestrates asynchronous falcon execution within local async boundary. Shutdown is
    # unified with the plaintext path: `exit(0)` alone tears down the reactor, so the
    # previously redundant `task.stop` (and its version-dependent behavior) is gone.
    #
    # @param port [Integer] physical OS boundary target identifier
    # @param context [OpenSSL::SSL::SSLContext] verified generated payload map
    # @return [void]
    sig { params(port: Integer, context: OpenSSL::SSL::SSLContext).void }
    def run_falcon(port, context)
      server = build_falcon_server(port, context)
      server_task = T.cast(server.run, Async::Task)
      setup_interrupt { exit(0) }
      server_task.wait
    end

    # Interlinks raw async descriptors configuring a strictly asynchronous HTTP1 web socket.
    #
    # @param port [Integer] target
    # @param context [OpenSSL::SSL::SSLContext] populated encryption mappings
    # @return [Falcon::Server] internally mapped interface natively wrapping the app
    sig { params(port: Integer, context: OpenSSL::SSL::SSLContext).returns(::Falcon::Server) }
    def build_falcon_server(port, context)
      endpoint = IO::Endpoint.tcp(BIND_ADDRESS, port)
      secure = IO::Endpoint::SSLEndpoint.new(endpoint, ssl_context: context)
      adapter = Protocol::Rack::Adapter.new(@app)
      Falcon::Server.new(adapter, secure, protocol: Async::HTTP::Protocol::HTTP1, scheme: 'https')
    end

    # Initializes native Rack bindings strictly wrapping Rackup fallback mechanisms.
    #
    # @param port [Integer] mapped integer binding OS constraints
    # @return [void]
    sig { params(port: Integer).void }
    def start_plaintext(port)
      puts("[Server] Binding natively to plaintext HTTP over port #{port}")
      Rackup::Handler::Falcon.run(@app, Host: BIND_ADDRESS, Port: port) do |_server|
        setup_interrupt { exit(0) }
      end
    end

    # Abstracts UNIX interrupt traps correctly resolving anonymous code closures cleanly.
    #
    # @yield to caller upon catching OS interaction interruption manually.
    # @return [void]
    sig { params(blk: T.proc.void).void }
    def setup_interrupt(&blk)
      trap('INT') do |_signo|
        puts("\n[Server] Shutting down immediately...")
        yield
      end
    end
  end
end
