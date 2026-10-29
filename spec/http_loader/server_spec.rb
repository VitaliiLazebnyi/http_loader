# typed: false
# frozen_string_literal: true

require 'spec_helper'

RSpec.describe HttpLoader::Server do
  let(:server) { described_class.new }

  before { allow($stdout).to receive(:puts) }

  describe 'the mock Rack app' do
    let(:response) { server.instance_variable_get(:@app).call({}) }

    it 'answers every request with a fixed 200 OK plaintext body' do
      expect(response).to eq([200, { 'Content-Type' => 'text/plain', 'Content-Length' => '2' }, ['OK']])
    end

    it 'is a proc (lenient arity), not a strict lambda' do
      expect(server.instance_variable_get(:@app).lambda?).to be(false)
    end
  end

  describe '#start' do
    it 'routes to the plaintext path on the given port when HTTPS is disabled' do
      allow(server).to receive(:start_plaintext)
      allow(server).to receive(:start_secure)
      server.start(use_https: false, port: 8080)
      expect(server).to have_received(:start_plaintext).with(8080)
      expect(server).not_to have_received(:start_secure)
    end

    it 'routes to the secure path on the given port when HTTPS is enabled' do
      allow(server).to receive(:start_plaintext)
      allow(server).to receive(:start_secure)
      server.start(use_https: true, port: 8443)
      expect(server).to have_received(:start_secure).with(8443)
      expect(server).not_to have_received(:start_plaintext)
    end

    it 'defaults to plaintext on port 8080' do
      allow(server).to receive(:start_plaintext)
      server.start
      expect(server).to have_received(:start_plaintext).with(8080)
    end
  end

  describe '#start_plaintext' do
    it 'announces the port and runs the Falcon Rackup handler bound to 0.0.0.0 with the mock app' do
      allow(Rackup::Handler::Falcon).to receive(:run)
      expect { server.send(:start_plaintext, 8080) }
        .to output("[Server] Binding natively to plaintext HTTP over port 8080\n").to_stdout
      expect(Rackup::Handler::Falcon).to have_received(:run)
        .with(be(server.instance_variable_get(:@app)), Host: '0.0.0.0', Port: 8080)
    end

    it 'installs an interrupt that exits with status 0 once the handler yields' do
      allow(Rackup::Handler::Falcon).to receive(:run).and_yield(instance_double(Object))
      captured = nil
      allow(server).to receive(:setup_interrupt) { |&blk| captured = blk }
      allow(server).to receive(:exit)
      server.send(:start_plaintext, 8080)
      captured.call
      expect(server).to have_received(:exit).with(0)
    end
  end

  describe '#start_secure' do
    let(:ssl_context) { instance_double(OpenSSL::SSL::SSLContext) }

    before do
      allow(server).to receive_messages(generate_ssl_context: ssl_context, run_falcon: nil)
      allow(server).to receive(:Sync).and_yield(instance_double(Async::Task))
    end

    it 'announces the port and runs Falcon inside a Sync reactor with the generated SSL context' do
      expect { server.send(:start_secure, 8443) }
        .to output("[Server] Binding natively to HTTPS over port 8443\n").to_stdout
      expect(server).to have_received(:run_falcon).with(8443, ssl_context)
    end
  end

  describe '#run_falcon' do
    let(:ssl_context) { instance_double(OpenSSL::SSL::SSLContext) }
    let(:falcon) { instance_double(Falcon::Server) }
    let(:task) { instance_double(Async::Task, wait: nil) }

    before do
      allow(server).to receive(:build_falcon_server).with(8443, ssl_context).and_return(falcon)
      allow(falcon).to receive(:run).and_return(task)
      allow(server).to receive(:setup_interrupt)
      allow(server).to receive(:exit)
    end

    it 'builds the Falcon server for the port/context, runs it, and waits on its task' do
      server.send(:run_falcon, 8443, ssl_context)
      expect(server).to have_received(:build_falcon_server).with(8443, ssl_context)
      expect(falcon).to have_received(:run)
      expect(task).to have_received(:wait)
    end

    it 'installs an interrupt that exits with status 0' do
      captured = nil
      allow(server).to receive(:setup_interrupt) { |&blk| captured = blk }
      server.send(:run_falcon, 8443, ssl_context)
      captured.call
      expect(server).to have_received(:exit).with(0)
    end
  end

  describe '#build_falcon_server' do
    let(:ssl_context) { instance_double(OpenSSL::SSL::SSLContext) }
    let(:endpoint) { instance_double(IO::Endpoint::HostEndpoint) }
    let(:secure) { instance_double(IO::Endpoint::SSLEndpoint) }
    let(:adapter) { instance_double(Protocol::Rack::Adapter) }
    let(:falcon) { instance_double(Falcon::Server) }

    before do
      allow(IO::Endpoint).to receive(:tcp).and_return(endpoint)
      allow(IO::Endpoint::SSLEndpoint).to receive(:new).and_return(secure)
      allow(Protocol::Rack::Adapter).to receive(:new).and_return(adapter)
      allow(Falcon::Server).to receive(:new).and_return(falcon)
    end

    it 'wraps the mock app in an HTTPS Falcon server over an SSL endpoint bound to 0.0.0.0' do
      result = server.send(:build_falcon_server, 8443, ssl_context)
      expect(IO::Endpoint).to have_received(:tcp).with('0.0.0.0', 8443)
      expect(IO::Endpoint::SSLEndpoint).to have_received(:new).with(endpoint, ssl_context: ssl_context)
      expect(Protocol::Rack::Adapter).to have_received(:new).with(be(server.instance_variable_get(:@app)))
      expect(Falcon::Server).to have_received(:new)
        .with(adapter, secure, protocol: Async::HTTP::Protocol::HTTP1, scheme: 'https')
      expect(result).to be(falcon)
    end
  end

  describe '#setup_interrupt' do
    it 'traps INT, prints the shutdown notice, and yields to the supplied block' do
      captured = nil
      allow(server).to receive(:trap).with('INT') { |&blk| captured = blk }
      yielded = false
      server.send(:setup_interrupt) { yielded = true }
      expect(server).to have_received(:trap).with('INT')
      expect { captured.call('INT') }.to output("\n[Server] Shutting down immediately...\n").to_stdout
      expect(yielded).to be(true)
    end
  end

  describe '#parse_cert_info' do
    subject(:cert) do
      c = OpenSSL::X509::Certificate.new
      server.send(:parse_cert_info, c)
      c
    end

    it 'sets a localhost subject and issuer' do
      expect(cert.subject.to_s).to eq('/CN=localhost')
      expect(cert.issuer.to_s).to eq('/CN=localhost')
    end

    it 'opens the validity window now and closes it exactly one year (365 days) later' do
      expect(cert.not_before).to be_within(10).of(Time.now)
      expect(cert.not_after - cert.not_before).to eq(365 * 24 * 60 * 60)
    end
  end

  describe '#build_cert' do
    subject(:cert) { server.send(:build_cert, rsa) }

    let(:rsa) { OpenSSL::PKey::RSA.new(2048) }

    it 'mints a v3 localhost certificate (serial 1) carrying the key, signed so it self-verifies' do
      expect(cert.subject.to_s).to eq('/CN=localhost') # parse_cert_info was applied
      expect(cert.serial).to eq(1)
      expect(cert.version).to eq(2)
      expect(cert.public_key.to_pem).to eq(rsa.public_key.to_pem)
      expect(cert.verify(rsa)).to be(true)
    end
  end

  describe '#generate_ssl_context' do
    subject(:context) { server.send(:generate_ssl_context) }

    it 'returns a context pairing a 2048-bit RSA key with a certificate that verifies against it' do
      expect(context).to be_a(OpenSSL::SSL::SSLContext)
      expect(context.key).to be_a(OpenSSL::PKey::RSA)
      expect(context.key.n.num_bits).to eq(2048)
      expect(context.cert.public_key.to_pem).to eq(context.key.public_key.to_pem)
      expect(context.cert.verify(context.key)).to be(true)
    end
  end
end
