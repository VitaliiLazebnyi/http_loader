# typed: strict
# frozen_string_literal: true

require 'sorbet-runtime'
require 'rack'
require 'rackup'
require 'rackup/handler/falcon'
require 'openssl'

module KeepAlive
  class Server
    extend T::Sig

    sig { void }
    def initialize
      @app = T.let(
        proc do |_env|
          [
            200,
            {
              'Content-Type' => 'text/event-stream',
              'Cache-Control' => 'no-cache'
            },
            Enumerator.new do |yielder|
              loop do
                yielder << "data: ping\n\n"
                sleep 15
              end
            rescue Errno::EPIPE, IOError
              # Justified Exception: The architecture requires dropping disconnected clients without emitting stacktraces.
              nil
            end
          ]
        end,
        T.proc.params(arg0: T.untyped).returns(T::Array[T.untyped])
      )
    end

    sig { params(use_https: T::Boolean, port: Integer).void }
    def start(use_https: false, port: 8080)
      if use_https
        puts "[Server] Binding natively to HTTPS over port #{port}"
        ssl_context = generate_ssl_context
        Rackup::Handler::Falcon.run(@app, Host: '0.0.0.0', Port: port, SSLEnable: true,
                                          ssl_context: ssl_context) do |_server|
          trap('INT') do
            puts "\n[Server] Shutting down immediately..."
            exit(0)
          end
        end
      else
        puts "[Server] Binding natively to plaintext HTTP over port #{port}"
        Rackup::Handler::Falcon.run(@app, Host: '0.0.0.0', Port: port) do |_server|
          trap('INT') do
            puts "\n[Server] Shutting down immediately..."
            exit(0)
          end
        end
      end
    end

    private

    sig { returns(OpenSSL::SSL::SSLContext) }
    def generate_ssl_context
      rsa = OpenSSL::PKey::RSA.new(2048)
      cert = OpenSSL::X509::Certificate.new
      cert.subject = cert.issuer = OpenSSL::X509::Name.parse('/CN=localhost')
      cert.not_before = Time.now.utc
      cert.not_after = Time.now.utc + (365 * 24 * 60 * 60)
      cert.public_key = rsa.public_key
      cert.serial = 0x0
      cert.version = 2
      cert.sign(rsa, OpenSSL::Digest.new('SHA256'))

      ssl_context = OpenSSL::SSL::SSLContext.new
      ssl_context.cert = cert
      ssl_context.key = rsa
      ssl_context
    end
  end
end
