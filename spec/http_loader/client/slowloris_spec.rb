# typed: false
# frozen_string_literal: true

require 'spec_helper'
require 'stringio'
require 'http_loader/client/slowloris'
require 'http_loader/client/logger'
require 'http_loader/client/config'

RSpec.describe HttpLoader::Client::Slowloris do
  let(:config) do
    HttpLoader::Client::Config.new(
      connections: 1, target_urls: [], use_https: false,
      verbose: false, ping: false, ping_period: 1, http_loader_timeout: 0.1,
      connections_per_second: 0, max_concurrent_connections: 1,
      reopen_closed_connections: false, reopen_interval: 0.0,
      read_timeout: 5.0, user_agent: 'A', jitter: 0.0,
      track_status_codes: false, ramp_up: 0.0, bind_ips: [],
      proxy_pool: [], qps_per_connection: 0, headers: {}, slowloris_delay: 1.0
    )
  end
  let(:logger) { instance_double(HttpLoader::Client::Logger, info: nil) }
  let(:slowloris) { described_class.new(config, logger) }
  let(:uri) { URI('http://local/') }
  let(:http) { Net::HTTP.new('localhost') }
  let(:io) { StringIO.new }

  # The complete (deliberately unfinished) request the slowloris streams for this config.
  let(:payload) do
    "GET / HTTP/1.1\r\nHost: local\r\nConnection: keep-alive\r\nUser-Agent: A\r\nX-Slowloris: "
  end

  before do
    socket = instance_double(Net::BufferedIO, io: io)
    allow(http).to receive(:instance_variable_get).with(:@socket).and_return(socket)
    allow(slowloris).to receive(:sleep)
    allow(io).to receive(:write).and_call_original
    allow(io).to receive(:flush).and_call_original
    # Keep-alive byte is rand(97..122).chr => 'a'; the jitter call rand(-0.0..0.0) stays 0.0.
    allow(slowloris).to receive(:rand) { |range| range == (97..122) ? 97 : 0.0 }
  end

  # Deterministic: budget (0.1s) is intact on the first maintain_hold check and expired on the
  # second, so exactly one keep-alive byte is written before the loop breaks.
  def freeze_after_one(start)
    allow(Time).to receive(:now).and_return(start, start + 1.0)
  end

  describe '#run guards' do
    it 'writes nothing and never reads the socket when slowloris_delay is 0' do
      slow = described_class.new(config.with(slowloris_delay: 0.0), logger)
      allow(slow).to receive(:sleep)
      slow.run(0, uri, http, Time.now)
      expect(http).not_to have_received(:instance_variable_get)
      expect(io.string).to eq('')
    end

    it 'writes nothing when the socket is absent' do
      allow(http).to receive(:instance_variable_get).with(:@socket).and_return(nil)
      slowloris.run(0, uri, http, Time.now)
      expect(io.string).to eq('')
    end
  end

  describe '#run streaming' do
    it 'streams the exact incomplete request then one keep-alive byte, logging the client index' do
      start = Time.now
      freeze_after_one(start)
      slowloris.run(3, uri, http, start)
      expect(io.string).to eq("#{payload}a")
      expect(logger).to have_received(:info)
        .with('[Client 3] Keep-alive timeout reached, closing Slowloris thread.')
    end

    it 'maps the path and query into the request line' do
      start = Time.now
      freeze_after_one(start)
      slowloris.run(0, URI('http://local/path?q=1'), http, start)
      expect(io.string).to start_with('GET /path?q=1 HTTP/1.1')
    end

    it 'defaults an empty path to /' do
      start = Time.now
      freeze_after_one(start)
      slowloris.run(0, URI('http://local'), http, start)
      expect(io.string).to start_with('GET / HTTP/1.1')
    end

    it 'appends each configured header before the unfinished one' do
      slow = described_class.new(config.with(headers: { 'X-Foo' => 'bar' }), logger)
      allow(slow).to receive_messages(sleep: nil, rand: 97)
      start = Time.now
      freeze_after_one(start)
      slow.run(0, uri, http, start)
      expect(io.string).to eq(
        "GET / HTTP/1.1\r\nHost: local\r\nConnection: keep-alive\r\nUser-Agent: A\r\n" \
        "X-Foo: bar\r\nX-Slowloris: a"
      )
    end

    it 'paces every payload byte except the last, then paces the keep-alive within budget' do
      start = Time.now
      freeze_after_one(start)
      slowloris.run(0, uri, http, start)
      expect(slowloris).to have_received(:sleep).with(1.0).exactly(payload.length - 1).times
      expect(slowloris).to have_received(:sleep).with(0.1).once # cap_to_budget(1.0, 0.1)
    end

    it 'flushes after every payload byte and after the keep-alive byte' do
      start = Time.now
      freeze_after_one(start)
      slowloris.run(0, uri, http, start)
      expect(io).to have_received(:flush).exactly(payload.length + 1).times
    end
  end

  describe '#maintain_hold budget handling' do
    # These isolate maintain_hold by stubbing the payload phase and driving budget_remaining with a
    # fixed sequence, so each keep-alive decision is deterministic and the loop always terminates.
    before { allow(slowloris).to receive(:fire_initial_payload) }

    it 'writes one keep-alive byte within budget, flushing and pacing to the remaining budget' do
      allow(slowloris).to receive(:budget_remaining).and_return(0.1, 0.0)
      start = Time.now
      slowloris.run(5, uri, http, start)
      expect(io.string).to eq('a') # rand(97..122) => 97 => 'a'
      expect(io).to have_received(:flush).once
      expect(slowloris).to have_received(:rand).with(97..122)
      expect(slowloris).to have_received(:sleep).with(0.1) # cap_to_budget(1.0, 0.1)
      expect(slowloris).to have_received(:budget_remaining).with(config.http_loader_timeout, start).at_least(:once)
    end

    it 'logs (with the client index) and stops when the budget is exactly exhausted' do
      allow(slowloris).to receive(:budget_remaining).and_return(0.0, -1.0)
      slowloris.run(7, uri, http, Time.now)
      expect(logger).to have_received(:info)
        .with('[Client 7] Keep-alive timeout reached, closing Slowloris thread.')
      expect(io).not_to have_received(:write) # broke before writing a keep-alive byte
    end

    it 'stops on a negative (overrun) budget rather than only on exactly zero' do
      allow(slowloris).to receive(:budget_remaining).and_return(-0.5, 0.0)
      slowloris.run(0, uri, http, Time.now)
      expect(io).not_to have_received(:write)
    end

    it 'treats a nil (unbounded) budget as "keep going" rather than crashing' do
      unbounded = described_class.new(config.with(http_loader_timeout: 0.0), logger)
      allow(unbounded).to receive_messages(fire_initial_payload: nil, sleep: nil, rand: 97)
      socket = instance_double(Net::BufferedIO, io: io)
      allow(http).to receive(:instance_variable_get).with(:@socket).and_return(socket)
      allow(io).to receive(:write).and_raise('stop-the-loop') # otherwise the hold never ends
      expect { unbounded.run(0, uri, http, Time.now) }.to raise_error('stop-the-loop')
    end
  end
end
