# typed: true
# frozen_string_literal: true

# Copyright (c) 2026 Vitalii Lazebnyi

require 'http_loader/client/config'
require 'http_loader/client/http_session'
require 'http_loader/client/logger'
require 'spec_helper'

RSpec.describe(HttpLoader::Client::HttpSession) do
  let(:config) do
    HttpLoader::Client::Config.new(
      connections: 1,
      target_urls: [],
      use_https: false,
      verbose: false,
      ping: true,
      ping_period: 3.0,
      http_loader_timeout: 0.1,
      connections_per_second: 0,
      max_concurrent_connections: 1,
      reopen_closed_connections: false,
      reopen_interval: 0.0,
      read_timeout: 5.0,
      user_agent: 'UA/1',
      jitter: 0.0,
      track_status_codes: false,
      ramp_up: 0.0,
      bind_ips: [],
      proxy_pool: [],
      qps_per_connection: 0,
      headers: { 'X-Foo' => 'bar' },
      slowloris_delay: 0.0
    )
  end
  let(:logger)   { instance_double(HttpLoader::Client::Logger, info: nil, status: nil) }
  let(:session)  { HttpLoader::Client::HttpSession.new(config, logger)                 }
  let(:uri)      { URI('http://local/')                                                }
  let(:http)     { Net::HTTP.new('localhost')                                          }
  let(:requests) { []                                                                  }

  # A real Net::HTTPResponse subclass instance so `success?` exercises genuine `is_a?` dispatch.
  def response(klass, code)
    res = klass.new('1.1', code, klass.name)
    allow(res).to(receive(:read_body).and_yield('chunk'))
    res
  end

  # Captures every request handed to http.request and yields/returns the given response.
  def stub_request(res)
    allow(http).to(receive(:request)) do |req, &block|
      requests << req
      block&.call(res)
      res
    end
  end

  before { allow(session).to(receive(:sleep)) }

  describe '#fire_initial_request' do
    it 'issues a keep-alive GET carrying the configured headers and drains the body', :aggregate_failures do
      allow(session).to(receive(:maintain_keepalive))
      res = response(Net::HTTPOK, '200')
      stub_request(res)
      session.run(0, uri, http, Time.now)
      get = requests.first
      expect(get.is_a?(Net::HTTP::Get)).to(be(true))
      expect(get.path).to(eq('/'))
      expect(get['Connection']).to(eq('keep-alive'))
      expect(get['User-Agent']).to(eq('UA/1'))
      expect(get['X-Foo']).to(eq('bar'))
      expect(http).to(have_received(:request).with(get))
    end
  end

  describe '#maintain_keepalive' do
    before do
      allow(session).to(receive(:fire_initial_request))
      stub_request(response(Net::HTTPOK, '200'))
    end

    it 'runs a heartbeat while there is budget, passing the remaining seconds through', :aggregate_failures do
      allow(session).to(receive(:budget_remaining).and_return(0.1, 0.0))
      allow(session).to(receive(:process_heartbeat?).and_return(true))
      start = Time.now
      session.run(0, uri, http, start)
      expect(session).to(have_received(:process_heartbeat?).with(0, uri, http, 0.1).once)
      expect(session).to(have_received(:budget_remaining).with(config.http_loader_timeout, start).at_least(:once))
    end

    it 'logs the client index and stops once the budget is exactly exhausted', :aggregate_failures do
      allow(session).to(receive(:budget_remaining).and_return(0.0, -1.0))
      allow(session).to(receive(:process_heartbeat?).and_return(true))
      session.run(9, uri, http, Time.now)
      expect(logger).to(have_received(:info).with('[Client 9] Keep-alive timeout reached, closing.'))
      expect(session).not_to(have_received(:process_heartbeat?))
    end

    it 'stops on a negative (overrun) budget, not only on exactly zero' do
      allow(session).to(receive(:budget_remaining).and_return(-0.5, 0.0))
      allow(session).to(receive(:process_heartbeat?).and_return(true))
      session.run(0, uri, http, Time.now)
      expect(session).not_to(have_received(:process_heartbeat?))
    end

    it 'stops immediately when a heartbeat reports the connection should close' do
      allow(session).to(receive(:budget_remaining).and_return(0.1, 0.1))
      allow(session).to(receive(:process_heartbeat?).and_return(false))
      session.run(0, uri, http, Time.now)
      expect(session).to(have_received(:process_heartbeat?).once)
    end

    it 'treats a nil (unbounded) budget as "keep going" rather than crashing' do
      unbounded = HttpLoader::Client::HttpSession.new(config.with(http_loader_timeout: 0.0), logger)
      allow(unbounded).to(receive(:fire_initial_request))
      allow(unbounded).to(receive(:process_heartbeat?).and_raise('stop-the-loop'))
      expect { unbounded.run(0, uri, http, Time.now) }
        .to(raise_error('stop-the-loop'))
    end
  end

  describe '#process_heartbeat?' do
    it 'performs a QPS request when qps_per_connection is positive', :aggregate_failures do
      sess = HttpLoader::Client::HttpSession.new(config.with(qps_per_connection: 5), logger)
      allow(sess).to(receive_messages(perform_qps?: true, perform_ping?: false))
      expect(sess.__send__(:process_heartbeat?, 1, uri, http, 0.2)).to(be(true))
      expect(sess).to(have_received(:perform_qps?).with(1, uri, http, 0.2))
      expect(sess).not_to(have_received(:perform_ping?))
    end

    it 'performs a ping request when qps is zero and ping is enabled', :aggregate_failures do
      sess = HttpLoader::Client::HttpSession.new(config.with(qps_per_connection: 0, ping: true), logger)
      allow(sess).to(receive_messages(perform_qps?: false, perform_ping?: true))
      expect(sess.__send__(:process_heartbeat?, 2, uri, http, 0.3)).to(be(true))
      expect(sess).to(have_received(:perform_ping?).with(2, uri, http, 0.3))
      expect(sess).not_to(have_received(:perform_qps?))
    end

    it 'idles with a budget-capped sleep and continues when neither QPS nor ping is set', :aggregate_failures do
      sess = HttpLoader::Client::HttpSession.new(config.with(qps_per_connection: 0, ping: false), logger)
      allow(sess).to(receive(:sleep))
      expect(sess.__send__(:process_heartbeat?, 0, uri, http, 0.2)).to(be(true))
      # cap_to_budget(jittered(1.0, 0), 0.2)
      expect(sess).to(have_received(:sleep).with(0.2))
    end
  end

  describe '#perform_qps?' do
    let(:sess) { HttpLoader::Client::HttpSession.new(config.with(qps_per_connection: 4, track_status_codes: true), logger) }

    before { allow(sess).to(receive(:sleep)) }

    it 'paces by 1/qps, GETs with headers, and reports success', :aggregate_failures do
      stub_request(response(Net::HTTPOK, '200'))
      expect(sess.__send__(:perform_qps?, 0, uri, http, 5.0)).to(be(true))
      # cap_to_budget(1.0/4, 5.0)
      expect(sess).to(have_received(:sleep).with(0.25))
      req = requests.first
      expect(req.is_a?(Net::HTTP::Get)).to(be(true))
      expect(req['Connection']).to(eq('keep-alive'))
      expect(req['User-Agent']).to(eq('UA/1'))
      expect(req['X-Foo']).to(eq('bar'))
    end

    it 'caps the QPS pace to a smaller remaining budget' do
      stub_request(response(Net::HTTPOK, '200'))
      sess.__send__(:perform_qps?, 0, uri, http, 0.1)
      # cap_to_budget(0.25, 0.1)
      expect(sess).to(have_received(:sleep).with(0.1))
    end

    it 'logs and reports failure on a non-success response', :aggregate_failures do
      stub_request(response(Net::HTTPInternalServerError, '500'))
      expect(sess.__send__(:perform_qps?, 3, uri, http, 5.0)).to(be(false))
      expect(logger).to(have_received(:status).with('[Client 3] Upstream returned HTTP 500'))
    end
  end

  describe '#perform_ping?' do
    let(:sess) { HttpLoader::Client::HttpSession.new(config.with(ping: true, ping_period: 3.0, track_status_codes: true), logger) }

    before { allow(sess).to(receive(:sleep)) }

    it 'paces by the ping period (as a Float) and HEADs with headers', :aggregate_failures do
      stub_request(response(Net::HTTPOK, '200'))
      expect(sess.__send__(:perform_ping?, 0, uri, http, 5.0)).to(be(true))
      # ping_period (3) must be coerced to 3.0 before pacing: eql is type-strict so 3 != 3.0.
      # cap_to_budget(ping_period.to_f, 5.0)
      expect(sess).to(have_received(:sleep).with(eql(3.0)))
      req = requests.first
      expect(req.is_a?(Net::HTTP::Head)).to(be(true))
      expect(req['Connection']).to(eq('keep-alive'))
      expect(req['User-Agent']).to(eq('UA/1'))
      expect(req['X-Foo']).to(eq('bar'))
    end

    it 'caps the ping pace to a smaller remaining budget' do
      stub_request(response(Net::HTTPOK, '200'))
      sess.__send__(:perform_ping?, 0, uri, http, 1.0)
      # cap_to_budget(3.0, 1.0)
      expect(sess).to(have_received(:sleep).with(1.0))
    end

    it 'logs and reports failure on a non-success response', :aggregate_failures do
      stub_request(response(Net::HTTPNotFound, '404'))
      expect(sess.__send__(:perform_ping?, 7, uri, http, 5.0)).to(be(false))
      expect(logger).to(have_received(:status).with('[Client 7] Upstream returned HTTP 404'))
    end
  end

  describe '#success?' do
    it 'is true for a 2xx success' do
      expect(session.__send__(:success?, response(Net::HTTPOK, '200'))).to(be(true))
    end

    it 'is true for a 3xx redirection' do
      expect(session.__send__(:success?, response(Net::HTTPFound, '302'))).to(be(true))
    end

    it 'is false for a 4xx client error' do
      expect(session.__send__(:success?, response(Net::HTTPNotFound, '404'))).to(be(false))
    end

    it 'is false for a 5xx server error' do
      expect(session.__send__(:success?, response(Net::HTTPInternalServerError, '500'))).to(be(false))
    end
  end

  describe '#log_status' do
    it 'logs the client index and code for a non-success response when tracking is on' do
      sess = HttpLoader::Client::HttpSession.new(config.with(track_status_codes: true), logger)
      sess.__send__(:log_status, 4, response(Net::HTTPServiceUnavailable, '503'))
      expect(logger).to(have_received(:status).with('[Client 4] Upstream returned HTTP 503'))
    end

    it 'logs nothing when tracking is disabled' do
      sess = HttpLoader::Client::HttpSession.new(config.with(track_status_codes: false), logger)
      sess.__send__(:log_status, 4, response(Net::HTTPInternalServerError, '500'))
      expect(logger).not_to(have_received(:status))
    end

    it 'logs nothing for a successful response even when tracking is on' do
      sess = HttpLoader::Client::HttpSession.new(config.with(track_status_codes: true), logger)
      sess.__send__(:log_status, 4, response(Net::HTTPOK, '200'))
      expect(logger).not_to(have_received(:status))
    end
  end
end
