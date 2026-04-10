# typed: false
# frozen_string_literal: true

require 'spec_helper'

RSpec.describe KeepAlive::Server do
  let(:server) { described_class.new }

  before do
    # Prevent stdout noise
    allow($stdout).to receive(:puts)
    allow(Rackup::Handler::Falcon).to receive(:run)
  end

  describe '#start' do
    context 'without https' do
      it 'binds natively to plaintext HTTP', rspec: true do
        server.start(use_https: false, port: 8080)
        expect(Rackup::Handler::Falcon).to have_received(:run).with(
          instance_of(Proc),
          Host: '0.0.0.0',
          Port: 8080
        )
      end
    end

    context 'with https' do
      it 'binds natively to HTTPS with generated keys', rspec: true do
        server.start(use_https: true, port: 8443)
        expect(Rackup::Handler::Falcon).to have_received(:run).with(
          instance_of(Proc),
          hash_including(
            Host: '0.0.0.0',
            Port: 8443,
            SSLEnable: true,
            ssl_context: instance_of(OpenSSL::SSL::SSLContext)
          )
        )
      end
    end
  end

  describe 'app evaluator' do
    it 'returns the correct rack response triplet', rspec: true do
      app = server.instance_variable_get(:@app)
      response = app.call({})

      expect(response[0]).to eq(200)
      expect(response[1]['Content-Type']).to eq('text/event-stream')
      expect(response[2]).to be_a(Enumerator)
    end
  end
end
