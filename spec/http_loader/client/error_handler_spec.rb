# typed: false
# frozen_string_literal: true

require 'spec_helper'
require 'http_loader/client'

RSpec.describe HttpLoader::Client::ErrorHandler do
  # ErrorHandler requires_ancestor HttpLoader::Client, so the handler is exercised on an
  # actual Client instance with a stubbed logger.
  let(:config) do
    HttpLoader::Client::Config.new(
      connections: 1, target_urls: [], use_https: false, verbose: false, ping: false,
      ping_period: 1.0, http_loader_timeout: 0.0, connections_per_second: 0,
      max_concurrent_connections: 1, reopen_closed_connections: false, reopen_interval: 0.0,
      read_timeout: 0.0, user_agent: 'A', jitter: 0.0, track_status_codes: false,
      ramp_up: 0.0, bind_ips: [], proxy_pool: [], qps_per_connection: 0, headers: {}, slowloris_delay: 0.0
    )
  end
  let(:logger) { instance_double(HttpLoader::Client::Logger, error: nil) }
  let(:client) { HttpLoader::Client.new(config) }

  before { allow(client).to receive(:logger).and_return(logger) }

  describe '#handle_err' do
    it 'classifies EMFILE as ERROR_EMFILE, tagged with the connection index and message' do
      err = Errno::EMFILE.new('dummy file')
      client.handle_err(0, err)
      expect(logger).to have_received(:error).with("[Client 0] ERROR_EMFILE: #{err.message}")
    end

    it 'classifies EADDRNOTAVAIL as ERROR_EADDRNOTAVAIL with a fixed explanation' do
      client.handle_err(1, Errno::EADDRNOTAVAIL.new('dummy addr'))
      expect(logger).to have_received(:error)
        .with('[Client 1] ERROR_EADDRNOTAVAIL: Ephemeral port limit reached.')
    end

    it 'classifies ThreadError as ERROR_THREADLIMIT (live telemetry metric)' do
      err = ThreadError.new('cannot create Thread')
      client.handle_err(3, err)
      expect(logger).to have_received(:error).with("[Client 3] ERROR_THREADLIMIT: #{err.message}")
    end

    it 'classifies EAGAIN as ERROR_THREADLIMIT' do
      err = Errno::EAGAIN.new('resource unavailable')
      client.handle_err(4, err)
      expect(logger).to have_received(:error).with("[Client 4] ERROR_THREADLIMIT: #{err.message}")
    end

    it 'falls back to ERROR_OTHER for unrecognised errors' do
      client.handle_err(2, StandardError.new('custom msg'))
      expect(logger).to have_received(:error).with('[Client 2] ERROR_OTHER: custom msg')
    end
  end
end
