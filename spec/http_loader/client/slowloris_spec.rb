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
  let(:logger) { HttpLoader::Client::Logger.new(false) }
  let(:slowloris) { described_class.new(config, logger) }

  describe '#run' do
    let(:uri) { URI('http://local/') }
    let(:http) { Net::HTTP.new('localhost') }
    let(:io) { StringIO.new }

    before do
      socket = instance_double(Net::BufferedIO, io: io)
      allow(http).to receive(:instance_variable_get).with(:@socket).and_return(socket)
      allow(slowloris).to receive(:sleep)
    end

    # Deterministic: budget (0.1s) is intact on the first maintain_hold check and expired
    # on the second, so exactly one keep-alive byte is written before the loop breaks.
    def freeze_after_one(start)
      allow(Time).to receive(:now).and_return(start, start + 1.0)
    end

    it 'streams the incomplete HTTP request byte-by-byte then holds the socket' do
      start = Time.now
      freeze_after_one(start)
      slowloris.run(0, uri, http, start)
      expect(io.string).to start_with("GET / HTTP/1.1\r\nHost: local\r\n")
      expect(io.string).to include('X-Slowloris: ') # deliberately unfinished header
      expect(slowloris).to have_received(:sleep).at_least(:once)
    end

    it 'writes exactly one lowercase keep-alive byte per maintain_hold iteration' do
      start = Time.now
      freeze_after_one(start)
      slowloris.run(0, uri, http, start)
      expect(io.string[-1]).to match(/[a-z]/)
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

    it 'applies jitter to the pacing without corrupting the payload' do
      slow = described_class.new(config.with(jitter: 0.1), logger)
      allow(slow).to receive(:sleep)
      start = Time.now
      freeze_after_one(start)
      slow.run(0, uri, http, start)
      expect(io.string).to start_with('GET / HTTP/1.1')
      expect(slow).to have_received(:sleep).with(a_value >= 0.0).at_least(:once)
    end

    it 'returns early (writes nothing) when slowloris_delay is 0' do
      slow = described_class.new(config.with(slowloris_delay: 0.0), logger)
      slow.run(0, uri, http, Time.now)
      expect(http).not_to have_received(:instance_variable_get)
      expect(io.string).to eq('')
    end

    it 'returns early (writes nothing) when the socket is absent' do
      allow(http).to receive(:instance_variable_get).with(:@socket).and_return(nil)
      slowloris.run(0, uri, http, Time.now)
      expect(io.string).to eq('')
    end
  end
end
