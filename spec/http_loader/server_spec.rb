# typed: true
# frozen_string_literal: true

# Copyright (c) 2026 Vitalii Lazebnyi

require 'ipaddr'
require 'spec_helper'

RSpec.describe(HttpLoader::Server) do
  let(:server) { HttpLoader::Server.new(https: false) }
  # The IPv4 wildcard address (INADDR_ANY), which binds every interface.
  let(:wildcard) { satisfy('the IPv4 wildcard address') { |host| IPAddr.new(host) == IPAddr.new(0, Socket::AF_INET) } }

  before { allow($stdout).to(receive(:puts)) }

  describe 'the mock Rack app' do
    let(:response) { server.instance_variable_get(:@app).call({}) }

    it 'answers every request with a fixed 200 OK plaintext body, with Rack 3 (lowercase) header names' do
      expect(response).to(eq([200, { 'content-type' => 'text/plain', 'content-length' => '2' }, ['OK']]))
    end

    it 'is a proc (lenient arity), not a strict lambda' do
      expect(server.instance_variable_get(:@app).lambda?).to(be(false))
    end
  end

  describe '#start' do
    before do
      allow(server).to(receive(:start_plaintext))
      allow(server).to(receive(:start_secure))
    end

    it 'serves plain HTTP on 8080 without HTTPS', :aggregate_failures do
      server.start
      expect(server).to(have_received(:start_plaintext).with(8080))
      expect(server).not_to(have_received(:start_secure))
    end

    context 'with HTTPS' do
      let(:server) { HttpLoader::Server.new(https: true) }

      it 'serves HTTPS on 8443', :aggregate_failures do
        server.start
        expect(server).to(have_received(:start_secure).with(8443))
        expect(server).not_to(have_received(:start_plaintext))
      end
    end
  end

  describe '#start_plaintext' do
    before { allow(Rackup::Handler::Falcon).to(receive(:run)) }

    it 'announces the port' do
      expect { server.__send__(:start_plaintext, 8080) }
        .to(output("[Server] Binding natively to plaintext HTTP over port 8080\n").to_stdout)
    end

    it 'runs the Falcon Rackup handler with the mock app on every IPv4 interface' do
      server.__send__(:start_plaintext, 8080)
      expect(Rackup::Handler::Falcon)
        .to(have_received(:run).with(be(server.instance_variable_get(:@app)), Host: wildcard, Port: 8080))
    end

    context 'when the handler yields' do
      let(:interrupt) do
        allow(Rackup::Handler::Falcon).to(receive(:run).and_yield(instance_double(Object)))
        captured = T.let(nil, T.nilable(Proc))
        allow(server).to(receive(:setup_interrupt) { |&block| captured = block })
        server.__send__(:start_plaintext, 8080)
        T.must(captured)
      end

      it 'installs an interrupt that exits with status 0' do
        allow(server).to(receive(:exit))
        interrupt.call
        expect(server).to(have_received(:exit).with(0))
      end
    end
  end

  describe '#start_secure' do
    let(:ssl_context) { instance_double(OpenSSL::SSL::SSLContext) }

    before do
      allow(server).to(receive(:run_falcon))
      allow(HttpLoader::Server).to(receive(:ssl_context).and_return(ssl_context))
      allow(server).to(receive(:Sync).and_yield(instance_double(Async::Task)))
    end

    it 'announces the port and runs Falcon inside a Sync reactor with the generated SSL context', :aggregate_failures do
      expect { server.__send__(:start_secure, 8443) }
        .to(output("[Server] Binding natively to HTTPS over port 8443\n").to_stdout)
      expect(server).to(have_received(:run_falcon).with(8443, ssl_context))
    end
  end

  describe '#run_falcon' do
    let(:ssl_context) { instance_double(OpenSSL::SSL::SSLContext)      }
    let(:falcon)      { instance_double(Falcon::Server)                }
    let(:task)        { instance_double(Async::Task, wait: nil)        }

    before do
      allow(server).to(receive(:build_falcon_server).with(8443, ssl_context).and_return(falcon))
      allow(falcon).to(receive(:run).and_return(task))
      allow(server).to(receive(:setup_interrupt))
      allow(server).to(receive(:exit))
    end

    it 'builds the Falcon server for the port/context, runs it, and waits on its task', :aggregate_failures do
      server.__send__(:run_falcon, 8443, ssl_context)
      expect(server).to(have_received(:build_falcon_server).with(8443, ssl_context))
      expect(falcon).to(have_received(:run))
      expect(task).to(have_received(:wait))
    end

    it 'installs an interrupt that exits with status 0' do
      captured = T.let(nil, T.nilable(Proc))
      allow(server).to(receive(:setup_interrupt) { |&block| captured = block })
      server.__send__(:run_falcon, 8443, ssl_context)
      T.must(captured).call
      expect(server).to(have_received(:exit).with(0))
    end
  end

  describe '#build_falcon_server' do
    subject(:built) { server.__send__(:build_falcon_server, 8443, ssl_context) }

    let(:ssl_context) { instance_double(OpenSSL::SSL::SSLContext) }
    let(:endpoint) { instance_double(IO::Endpoint::HostEndpoint) }
    let(:secure)   { instance_double(IO::Endpoint::SSLEndpoint)  }

    before do
      allow(IO::Endpoint).to(receive(:tcp).and_return(endpoint))
      allow(IO::Endpoint::SSLEndpoint).to(receive(:new).and_return(secure))
      allow(Protocol::Rack::Adapter).to(receive(:new).and_return(instance_double(Protocol::Rack::Adapter)))
      allow(Falcon::Server).to(receive(:new).and_return(instance_double(Falcon::Server)))
    end

    it 'returns the Falcon server' do
      # The stubbed Falcon::Server.new returns the same double on every call.
      expect(built).to(be(Falcon::Server.new))
    end

    it 'binds a TCP endpoint on every IPv4 interface' do
      built
      expect(IO::Endpoint).to(have_received(:tcp).with(wildcard, 8443))
    end

    it 'wraps the TCP endpoint in TLS with the SSL context' do
      built
      expect(IO::Endpoint::SSLEndpoint).to(have_received(:new).with(endpoint, ssl_context: ssl_context))
    end

    it 'adapts the mock app' do
      built
      expect(Protocol::Rack::Adapter).to(have_received(:new).with(be(server.instance_variable_get(:@app))))
    end

    it 'serves the adapted app over HTTP/1 with the https scheme on the TLS endpoint' do
      built
      expect(Falcon::Server).to(
        have_received(:new)
                .with(Protocol::Rack::Adapter.new(nil), secure, protocol: Async::HTTP::Protocol::HTTP1, scheme: 'https')
      )
    end
  end

  describe '#setup_interrupt' do
    let(:handler) do
      captured = T.let(nil, T.nilable(Proc))
      allow(server).to(receive(:trap).with('INT') { |&block| captured = block })
      server.__send__(:setup_interrupt) { nil }
      T.must(captured)
    end

    it 'traps INT and prints the shutdown notice' do
      expect { handler.call('INT') }
        .to(output("\n[Server] Shutting down immediately...\n").to_stdout)
    end

    it 'yields to the supplied block when INT arrives' do
      allow(server).to(receive(:trap).with('INT').and_yield('INT'))
      expect { |probe| server.__send__(:setup_interrupt, &probe) }
        .to(output.to_stdout.and(yield_control))
    end
  end

  describe '.certificate (private)' do
    subject(:cert) { HttpLoader::Server.__send__(:certificate, rsa) }

    let(:rsa) { OpenSSL::PKey::RSA.new(2048) }

    it 'mints a v3 localhost certificate (serial 1) carrying the key, signed so it self-verifies',
      :aggregate_failures do
      expect(cert.subject.to_s).to(eq('/CN=localhost'))
      expect(cert.issuer.to_s).to(eq('/CN=localhost'))
      expect(cert.serial).to(eq(1))
      expect(cert.version).to(eq(2))
      expect(cert.public_key.to_pem).to(eq(rsa.public_key.to_pem))
      expect(cert.verify(rsa)).to(be(true))
    end

    it 'opens the validity window now and closes it exactly one year (365 days) later', :aggregate_failures do
      expect(cert.not_before).to(be_within(10).of(Time.now))
      expect(cert.not_after - cert.not_before).to(eq(365 * 24 * 60 * 60))
    end
  end

  describe '.ssl_context' do
    subject(:context) { HttpLoader::Server.ssl_context }

    it 'returns a context pairing a 2048-bit RSA key with a certificate that verifies against it',
      :aggregate_failures do
      expect(context.is_a?(OpenSSL::SSL::SSLContext)).to(be(true))
      expect(context.key.is_a?(OpenSSL::PKey::RSA)).to(be(true))
      expect(context.key.n.num_bits).to(eq(2048))
      expect(context.cert.public_key.to_pem).to(eq(context.key.public_key.to_pem))
      expect(context.cert.verify(context.key)).to(be(true))
    end
  end
end
