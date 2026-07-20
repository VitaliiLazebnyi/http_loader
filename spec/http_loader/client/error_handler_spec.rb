# typed: false
# frozen_string_literal: true

require 'spec_helper'
require 'http_loader/client'

RSpec.describe HttpLoader::Client::ErrorHandler do
  # ErrorHandler casts `self` to a real HttpLoader::Client (requires_ancestor), so the
  # handler is exercised on an actual Client instance with a stubbed logger.
  let(:config) do
    HttpLoader::Client::Config.new(
      connections: 1, target_urls: [], use_https: false, verbose: false, ping: false,
      ping_period: 1, http_loader_timeout: 0.0, connections_per_second: 0,
      max_concurrent_connections: 1, reopen_closed_connections: false, reopen_interval: 0.0,
      read_timeout: 0.0, user_agent: 'A', jitter: 0.0, track_status_codes: false,
      ramp_up: 0.0, bind_ips: [], proxy_pool: [], qps_per_connection: 0, headers: {}, slowloris_delay: 0.0
    )
  end
  let(:logger) { instance_double(HttpLoader::Client::Logger, error: nil) }
  let(:client) { HttpLoader::Client.new(config) }

  before { allow(client).to receive(:logger).and_return(logger) }

  describe '#handle_err' do
    it 'classifies EMFILE as ERROR_EMFILE' do
      client.handle_err(0, Errno::EMFILE.new('dummy file'))
      expect(logger).to have_received(:error).with(/ERROR_EMFILE/)
    end

    it 'classifies EADDRNOTAVAIL as ERROR_EADDRNOTAVAIL' do
      client.handle_err(1, Errno::EADDRNOTAVAIL.new('dummy addr'))
      expect(logger).to have_received(:error).with(/ERROR_EADDRNOTAVAIL/)
    end

    it 'classifies ThreadError as ERROR_THREADLIMIT (live telemetry metric)' do
      client.handle_err(3, ThreadError.new('cannot create Thread'))
      expect(logger).to have_received(:error).with(/ERROR_THREADLIMIT/)
    end

    it 'classifies EAGAIN as ERROR_THREADLIMIT' do
      client.handle_err(4, Errno::EAGAIN.new('resource unavailable'))
      expect(logger).to have_received(:error).with(/ERROR_THREADLIMIT/)
    end

    it 'falls back to ERROR_OTHER for unrecognised errors' do
      client.handle_err(2, StandardError.new('custom msg'))
      expect(logger).to have_received(:error).with(/ERROR_OTHER: custom msg/)
    end
  end
end
