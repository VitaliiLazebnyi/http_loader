# typed: true
# frozen_string_literal: true

# Copyright (c) 2026 Vitalii Lazebnyi

require 'spec_helper'

RSpec.describe(HttpLoader::Client::HttpSession) do
  let(:overrides) { {}                                                                  }
  let(:logger)    { instance_double(HttpLoader::Client::Logger, info: nil, status: nil) }
  let(:uri)       { URI('http://local/')                                                }
  let(:http)      { Net::HTTP.new('localhost')                                          }
  let(:session) do
    settings = {
      connections: 1,
      ping_period: 3.0,
      http_loader_timeout: 0.1,
      read_timeout: 5.0,
      user_agent: 'UA/1',
      jitter: 0.0,
      headers: { 'X-Foo' => 'bar' }
    }
    HttpLoader::Client::HttpSession.new(ConfigFactory.client(settings.merge(overrides)), logger)
  end

  before do
    allow(session).to(receive(:sleep))
    allow(http).to(receive(:request).and_return(Net::HTTPOK.new('1.1', '200', 'OK')))
  end

  describe '#fire_initial_request' do
    it 'issues a keep-alive GET to the URI path carrying the configured headers' do
      allow(session).to(receive(:maintain_keepalive))
      session.run(0, uri, http, Time.now)
      expect(http).to(
        have_received(:request).with(
          keep_alive_request(
            Net::HTTP::Get,
            path: '/',
            user_agent: 'UA/1',
            headers: { 'X-Foo' => 'bar' }
          )
        )
      )
    end
  end

  describe '#maintain_keepalive' do
    before do
      allow(session).to(receive(:fire_initial_request))
      allow(session).to(receive(:process_heartbeat?).and_return(true))
    end

    context 'with budget left' do
      before do
        allow(session).to(receive(:budget_remaining).and_return(0.1, 0.0))
        session.run(0, uri, http, Time.at(0))
      end

      it 'runs a heartbeat, passing the remaining seconds through' do
        expect(session).to(have_received(:process_heartbeat?).with(0, uri, http, 0.1).once)
      end

      it 'measures the budget against the keep-alive timeout from the start time' do
        expect(session).to(have_received(:budget_remaining).with(0.1, Time.at(0)).twice)
      end
    end

    context 'when the budget is exactly exhausted' do
      before do
        allow(session).to(receive(:budget_remaining).and_return(0.0, -1.0))
        session.run(9, uri, http, Time.now)
      end

      it('runs no heartbeat') { expect(session).not_to(have_received(:process_heartbeat?)) }

      it 'logs the client index and stops' do
        expect(logger).to(have_received(:info).with('[Client 9] Keep-alive timeout reached, closing.'))
      end
    end

    it 'stops on a negative (overrun) budget, not only on exactly zero' do
      allow(session).to(receive(:budget_remaining).and_return(-0.5, 0.0))
      session.run(0, uri, http, Time.now)
      expect(session).not_to(have_received(:process_heartbeat?))
    end

    it 'stops immediately when a heartbeat reports the connection should close' do
      allow(session).to(receive_messages(budget_remaining: 0.1, process_heartbeat?: false))
      session.run(0, uri, http, Time.now)
      expect(session).to(have_received(:process_heartbeat?).once)
    end

    it 'does not log a timeout when a heartbeat closes the connection' do
      allow(session).to(receive_messages(budget_remaining: 0.1, process_heartbeat?: false))
      session.run(0, uri, http, Time.now)
      expect(logger).not_to(have_received(:info))
    end

    context 'with an unbounded (nil) budget' do
      let(:overrides) { { http_loader_timeout: 0.0 } }

      it 'keeps going rather than crashing' do
        allow(session).to(receive(:process_heartbeat?).and_raise('stop-the-loop'))
        expect { session.run(0, uri, http, Time.now) }
          .to(raise_error('stop-the-loop'))
      end
    end
  end

  describe '#process_heartbeat?' do
    before { allow(session).to(receive_messages(perform_qps?: true, perform_ping?: true)) }

    context 'when qps_per_connection is positive' do
      let(:overrides) { { qps_per_connection: 5 } }

      it 'performs a QPS request and continues', :aggregate_failures do
        expect(session.__send__(:process_heartbeat?, 1, uri, http, 0.2)).to(be(true))
        expect(session).to(have_received(:perform_qps?).with(1, uri, http, 0.2))
        expect(session).not_to(have_received(:perform_ping?))
      end
    end

    context 'when qps is zero and ping is enabled' do
      it 'performs a ping request and continues', :aggregate_failures do
        expect(session.__send__(:process_heartbeat?, 2, uri, http, 0.3)).to(be(true))
        expect(session).to(have_received(:perform_ping?).with(2, uri, http, 0.3))
        expect(session).not_to(have_received(:perform_qps?))
      end
    end

    context 'when neither QPS nor ping is set' do
      let(:overrides) { { ping: false } }

      it 'idles with a budget-capped sleep (1.0s capped to 0.2s) and continues', :aggregate_failures do
        expect(session.__send__(:process_heartbeat?, 0, uri, http, 0.2)).to(be(true))
        expect(session).to(have_received(:sleep).with(0.2))
      end
    end
  end

  describe '#perform_qps?' do
    let(:overrides) { { qps_per_connection: 4, track_status_codes: true } }

    it 'reports success' do
      expect(session.__send__(:perform_qps?, 0, uri, http, 5.0)).to(be(true))
    end

    it 'paces by 1/qps' do
      session.__send__(:perform_qps?, 0, uri, http, 5.0)
      expect(session).to(have_received(:sleep).with(0.25))
    end

    it 'sends a keep-alive GET with the configured headers' do
      session.__send__(:perform_qps?, 0, uri, http, 5.0)
      expect(http).to(
        have_received(:request).with(
          keep_alive_request(
            Net::HTTP::Get,
            path: '/',
            user_agent: 'UA/1',
            headers: { 'X-Foo' => 'bar' }
          )
        )
      )
    end

    it 'caps the QPS pace (0.25s) to a smaller remaining budget' do
      session.__send__(:perform_qps?, 0, uri, http, 0.1)
      expect(session).to(have_received(:sleep).with(0.1))
    end

    it 'logs and reports failure on a non-success response', :aggregate_failures do
      allow(http).to(receive(:request).and_return(Net::HTTPInternalServerError.new('1.1', '500', 'Error')))
      expect(session.__send__(:perform_qps?, 3, uri, http, 5.0)).to(be(false))
      expect(logger).to(have_received(:status).with('[Client 3] Upstream returned HTTP 500'))
    end
  end

  describe '#perform_ping?' do
    let(:overrides) { { track_status_codes: true } }

    it 'reports success' do
      expect(session.__send__(:perform_ping?, 0, uri, http, 5.0)).to(be(true))
    end

    it 'paces by the ping period as a Float (eql is type-strict, so 3 would not match)' do
      session.__send__(:perform_ping?, 0, uri, http, 5.0)
      expect(session).to(have_received(:sleep).with(eql(3.0)))
    end

    it 'sends a keep-alive HEAD with the configured headers' do
      session.__send__(:perform_ping?, 0, uri, http, 5.0)
      expect(http).to(
        have_received(:request).with(
          keep_alive_request(
            Net::HTTP::Head,
            path: '/',
            user_agent: 'UA/1',
            headers: { 'X-Foo' => 'bar' }
          )
        )
      )
    end

    it 'caps the ping pace (3.0s) to a smaller remaining budget' do
      session.__send__(:perform_ping?, 0, uri, http, 1.0)
      expect(session).to(have_received(:sleep).with(1.0))
    end

    it 'logs and reports failure on a non-success response', :aggregate_failures do
      allow(http).to(receive(:request).and_return(Net::HTTPNotFound.new('1.1', '404', 'Not Found')))
      expect(session.__send__(:perform_ping?, 7, uri, http, 5.0)).to(be(false))
      expect(logger).to(have_received(:status).with('[Client 7] Upstream returned HTTP 404'))
    end
  end

  describe '#success?' do
    it 'is true for a 2xx success' do
      expect(session.__send__(:success?, Net::HTTPOK.new('1.1', '200', 'OK'))).to(be(true))
    end

    it 'is true for a 3xx redirection' do
      expect(session.__send__(:success?, Net::HTTPFound.new('1.1', '302', 'Found'))).to(be(true))
    end

    it 'is false for a 4xx client error' do
      expect(session.__send__(:success?, Net::HTTPNotFound.new('1.1', '404', 'Not Found'))).to(be(false))
    end

    it 'is false for a 5xx server error' do
      expect(session.__send__(:success?, Net::HTTPInternalServerError.new('1.1', '500', 'Error'))).to(be(false))
    end
  end

  describe '#log_status' do
    let(:overrides) { { track_status_codes: true } }

    it 'logs the client index and code for a non-success response when tracking is on' do
      session.__send__(:log_status, 4, Net::HTTPServiceUnavailable.new('1.1', '503', 'Unavailable'))
      expect(logger).to(have_received(:status).with('[Client 4] Upstream returned HTTP 503'))
    end

    it 'logs nothing for a successful response even when tracking is on' do
      session.__send__(:log_status, 4, Net::HTTPOK.new('1.1', '200', 'OK'))
      expect(logger).not_to(have_received(:status))
    end

    context 'when tracking is disabled' do
      let(:overrides) { { track_status_codes: false } }

      it 'logs nothing' do
        session.__send__(:log_status, 4, Net::HTTPInternalServerError.new('1.1', '500', 'Error'))
        expect(logger).not_to(have_received(:status))
      end
    end
  end
end
