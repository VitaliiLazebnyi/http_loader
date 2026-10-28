# typed: false
# frozen_string_literal: true

require 'spec_helper'
require 'http_loader/client/http_session'
require 'http_loader/client/logger'
require 'http_loader/client/config'

RSpec.describe HttpLoader::Client::HttpSession do
  let(:config) do
    HttpLoader::Client::Config.new(
      connections: 1, target_urls: [], use_https: false,
      verbose: false, ping: true, ping_period: 1, http_loader_timeout: 0.1,
      connections_per_second: 0, max_concurrent_connections: 1,
      reopen_closed_connections: false, reopen_interval: 0.0,
      read_timeout: 5.0, user_agent: 'A', jitter: 0.0,
      track_status_codes: false, ramp_up: 0.0, bind_ips: [],
      proxy_pool: [], qps_per_connection: 0, headers: {}, slowloris_delay: 0.0
    )
  end
  let(:session) { described_class.new(config, logger) }
  let(:logger) { HttpLoader::Client::Logger.new(false) }

  # Builds a real Net::HTTPResponse subclass instance so `success?` exercises the
  # genuine `is_a?` dispatch rather than a double that fakes it for every argument.
  def response(klass, code)
    res = klass.new('1.1', code, klass.name)
    allow(res).to receive(:read_body).and_yield('chunk')
    res
  end

  describe '#run' do
    let(:uri) { URI('http://local/') }
    let(:http) { Net::HTTP.new('localhost') }

    def stub_request(res)
      allow(http).to receive(:request) do |*_args, &block|
        block&.call(res)
        res
      end
    end

    before { allow(session).to receive(:sleep) }

    it 'fires exactly one initial GET then honours the keep-alive timeout' do
      stub_request(response(Net::HTTPOK, '200'))
      time = Time.now
      allow(Time).to receive(:now).and_return(time, time + 1.0)

      session.run(0, uri, http, time)

      # 1 initial GET + 1 ping HEAD before the +1.0s timeout breaks the loop.
      expect(http).to have_received(:request).twice
    end

    it 'applies jitter to the sleep interval without raising' do
      cfg = config.with(jitter: 0.1)
      sess = described_class.new(cfg, logger)
      allow(sess).to receive(:sleep)
      stub_request(response(Net::HTTPOK, '200'))
      time = Time.now
      allow(Time).to receive(:now).and_return(time, time + 1.0)

      sess.run(0, uri, http, time)

      expect(sess).to have_received(:sleep).with(a_value >= 0.0)
    end

    it 'logs a non-success status code when tracking is enabled' do
      cfg = config.with(qps_per_connection: 5, track_status_codes: true)
      sess = described_class.new(cfg, logger)
      allow(sess).to receive(:sleep)
      stub_request(response(Net::HTTPInternalServerError, '500'))

      allow(logger).to receive(:status)
      sess.run(0, uri, http, Time.now)

      expect(logger).to have_received(:status).with(/Upstream returned HTTP 500/)
      # Initial GET + one QPS GET; the 500 breaks the keep-alive loop.
      expect(http).to have_received(:request).twice
    end

    it 'does not log a successful status code even when tracking is enabled' do
      cfg = config.with(qps_per_connection: 5, track_status_codes: true)
      sess = described_class.new(cfg, logger)
      allow(sess).to receive(:sleep)
      stub_request(response(Net::HTTPOK, '200'))
      time = Time.now
      allow(Time).to receive(:now).and_return(time, time + 1.0)

      allow(logger).to receive(:status)
      sess.run(0, uri, http, time)

      expect(logger).not_to have_received(:status).with(/Upstream returned HTTP/)
    end

    it 'continues the session on a redirection response' do
      cfg = config.with(ping: true)
      sess = described_class.new(cfg, logger)
      allow(sess).to receive(:sleep)
      stub_request(response(Net::HTTPFound, '302'))
      time = Time.now
      allow(Time).to receive(:now).and_return(time, time + 1.0)

      sess.run(0, uri, http, time)

      # Redirection counts as success, so the loop pings once before timing out.
      expect(http).to have_received(:request).twice
    end

    it 'idles with a static sleep when both QPS and ping are disabled' do
      cfg = config.with(qps_per_connection: 0, ping: false)
      sess = described_class.new(cfg, logger)
      allow(sess).to receive(:sleep)
      stub_request(response(Net::HTTPOK, '200'))
      time = Time.now
      allow(Time).to receive(:now).and_return(time, time + 1.0)

      sess.run(0, uri, http, time)

      # Only the initial GET reaches the wire; the heartbeat is a bare sleep, capped to
      # the remaining keep-alive budget (0.1s) rather than the full 1.0s idle interval.
      expect(http).to have_received(:request).once
      expect(sess).to have_received(:sleep).with(0.1)
    end

    it 'caps the heartbeat sleep to the remaining keep-alive budget (no overshoot)' do
      # Idle mode with a 5s ping interval but only 0.1s of budget left: the sleep must be
      # clamped to 0.1s so the connection cannot overrun its deadline by a full interval.
      cfg = config.with(qps_per_connection: 0, ping: false, http_loader_timeout: 0.1)
      sess = described_class.new(cfg, logger)
      allow(sess).to receive(:sleep)
      stub_request(response(Net::HTTPOK, '200'))
      time = Time.now
      allow(Time).to receive(:now).and_return(time, time + 1.0)

      sess.run(0, uri, http, time)

      expect(sess).to have_received(:sleep).with(a_value <= 0.1)
    end
  end
end
