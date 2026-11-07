# typed: true
# frozen_string_literal: true

# Copyright (c) 2026 Vitalii Lazebnyi

require 'spec_helper'
require 'tempfile'

RSpec.describe(HttpLoader::Client::Slowloris) do
  let(:overrides) { {}                                                     }
  let(:logger)    { instance_double(HttpLoader::Client::Logger, info: nil) }
  let(:http)      { Net::HTTP.new('localhost')                             }
  # A real IO (the socket type Slowloris writes to); the bytes written are read back from its path.
  let(:io) { Tempfile.create('slowloris') }
  let(:slowloris) do
    settings = {
      connections: 1,
      ping: false,
      ping_period: 1.0,
      http_loader_timeout: 0.1,
      read_timeout: 5.0,
      user_agent: 'A',
      jitter: 0.0,
      slowloris_delay: 1.0
    }
    HttpLoader::Client::Slowloris.new(ConfigFactory.client(settings.merge(overrides)), logger)
  end

  before do
    allow(http).to(receive(:instance_variable_get).with(:@socket).and_return(instance_double(Net::BufferedIO, io: io)))
    allow(slowloris).to(receive(:sleep))
    allow(io).to(receive(:write).and_call_original)
    allow(io).to(receive(:flush).and_call_original)
    # Keep-alive byte is rand(97..122).chr => 'a'; the jitter call rand(-0.0..0.0) stays 0.0.
    allow(slowloris).to(receive(:rand) { |range| range == (97..122) ? 97 : 0.0 })
  end

  after do
    io.close
    File.unlink(io.path)
  end

  describe '#run guards' do
    context 'when slowloris_delay is 0' do
      let(:overrides) { { slowloris_delay: 0.0 } }

      it 'writes nothing and never reads the socket', :aggregate_failures do
        slowloris.run(0, URI('http://local/'), http, Time.now)
        expect(http).not_to(have_received(:instance_variable_get))
        expect(File.read(io.path)).to(eq(''))
      end
    end

    it 'writes nothing when the socket is absent' do
      allow(http).to(receive(:instance_variable_get).with(:@socket).and_return(nil))
      slowloris.run(0, URI('http://local/'), http, Time.now)
      expect(File.read(io.path)).to(eq(''))
    end
  end

  describe '#run streaming' do
    # Deterministic: the budget (0.1s) is intact on the first check and expired on the second, so exactly one
    # keep-alive byte is written after the payload.
    before { allow(Time).to(receive(:now).and_return(Time.at(0), Time.at(1))) }

    it 'streams the exact incomplete request then one keep-alive byte' do
      slowloris.run(3, URI('http://local/'), http, Time.at(0))
      expect(File.read(io.path))
        .to(eq("GET / HTTP/1.1\r\nHost: local\r\nConnection: keep-alive\r\nUser-Agent: A\r\nX-Slowloris: a"))
    end

    it 'logs the client index when the hold ends' do
      slowloris.run(3, URI('http://local/'), http, Time.at(0))
      expect(logger).to(have_received(:info).with('[Client 3] Keep-alive timeout reached, closing Slowloris thread.'))
    end

    it 'maps the path and query into the request line' do
      slowloris.run(0, URI('http://local/path?q=1'), http, Time.at(0))
      expect(File.read(io.path)).to(start_with('GET /path?q=1 HTTP/1.1'))
    end

    it 'defaults an empty path to /' do
      slowloris.run(0, URI('http://local'), http, Time.at(0))
      expect(File.read(io.path)).to(start_with('GET / HTTP/1.1'))
    end

    it 'paces every byte but the first with the slowloris delay, then caps the keep-alive pace to the budget',
       :aggregate_failures do
      slowloris.run(0, URI('http://local/'), http, Time.at(0))
      written = File.size(io.path)
      expect(slowloris).to(have_received(:sleep).with(1.0).exactly(written - 2).times)
      expect(slowloris).to(have_received(:sleep).with(0.1).once)
    end

    it 'flushes after every byte' do
      slowloris.run(0, URI('http://local/'), http, Time.at(0))
      expect(io).to(have_received(:flush).exactly(File.size(io.path)).times)
    end

    context 'with configured headers' do
      let(:overrides) { { headers: { 'X-Foo' => 'bar' } } }

      it 'appends each before the unfinished one' do
        slowloris.run(0, URI('http://local/'), http, Time.at(0))
        expect(File.read(io.path)).to(end_with("User-Agent: A\r\nX-Foo: bar\r\nX-Slowloris: a"))
      end
    end
  end

  describe '#maintain_hold budget handling' do
    # These isolate maintain_hold by stubbing the payload phase and driving budget_remaining with a fixed
    # sequence, so each keep-alive decision is deterministic and the loop always terminates.
    before { allow(slowloris).to(receive(:fire_initial_payload)) }

    context 'with budget left for one byte' do
      before do
        allow(slowloris).to(receive(:budget_remaining).and_return(0.1, 0.0))
        slowloris.run(5, URI('http://local/'), http, Time.at(0))
      end

      it('writes one random lowercase keep-alive byte') { expect(File.read(io.path)).to(eq('a')) }
      it('draws it from a..z') { expect(slowloris).to(have_received(:rand).with(97..122)) }
      it('flushes it') { expect(io).to(have_received(:flush).once) }
      it('caps the pace (1.0s) to the remaining budget') { expect(slowloris).to(have_received(:sleep).with(0.1)) }

      it 'measures the budget against the keep-alive timeout from the start time' do
        expect(slowloris).to(have_received(:budget_remaining).with(0.1, Time.at(0)).at_least(:once))
      end
    end

    it 'logs (with the client index) and stops when the budget is exactly exhausted', :aggregate_failures do
      allow(slowloris).to(receive(:budget_remaining).and_return(0.0, -1.0))
      slowloris.run(7, URI('http://local/'), http, Time.now)
      expect(logger).to(have_received(:info).with('[Client 7] Keep-alive timeout reached, closing Slowloris thread.'))
      expect(io).not_to(have_received(:write))
    end

    it 'stops on a negative (overrun) budget rather than only on exactly zero' do
      allow(slowloris).to(receive(:budget_remaining).and_return(-0.5, 0.0))
      slowloris.run(0, URI('http://local/'), http, Time.now)
      expect(io).not_to(have_received(:write))
    end

    context 'with an unbounded (nil) budget' do
      let(:overrides) { { http_loader_timeout: 0.0 } }

      it 'keeps going rather than crashing' do
        # Otherwise the hold never ends.
        allow(io).to(receive(:write).and_raise('stop-the-loop'))
        expect { slowloris.run(0, URI('http://local/'), http, Time.now) }
          .to(raise_error('stop-the-loop'))
      end
    end
  end
end
