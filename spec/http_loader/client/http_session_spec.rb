# typed: true
# frozen_string_literal: true

# Copyright (c) 2026 Vitalii Lazebnyi

require 'spec_helper'

RSpec.describe(HttpLoader::Client::HttpSession) do
  let(:overrides)  { {}                                                                                      }
  let(:logger)     { instance_double(HttpLoader::Client::Logger, info: nil, status: nil)                     }
  let(:http)       { Net::HTTP.new('localhost')                                                              }
  let(:connection) { ConnectionFactory.build(http, index: 3, uri: 'http://local/')                           }
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

  describe '.request' do
    it 'builds a request of the class to the URI path, with every header' do
      request = HttpLoader::Client::HttpSession.request(Net::HTTP::Head, URI('http://h/p?q=1'), { 'X-A' => '1' })
      expect(request).to(an_instance_of(Net::HTTP::Head).and(having_attributes(path: '/p?q=1')))
    end

    it 'sets the headers in order, so a later one replaces an earlier one of the same name' do
      headers = { 'User-Agent' => 'first', 'user-agent' => 'second' }
      expect(
        HttpLoader::Client::HttpSession.request(
          Net::HTTP::Get,
          URI('http://local/'),
          headers
        )['User-Agent']
      ).to(eq('second'))
    end
  end

  describe '.success?' do
    it 'is true for a 2xx success' do
      expect(HttpLoader::Client::HttpSession.success?(Net::HTTPOK.new('1.1', '200', 'OK'))).to(be(true))
    end

    it 'is true for a 3xx redirection' do
      expect(HttpLoader::Client::HttpSession.success?(Net::HTTPFound.new('1.1', '302', 'Found'))).to(be(true))
    end

    it 'is false for a 4xx client error' do
      expect(HttpLoader::Client::HttpSession.success?(Net::HTTPNotFound.new('1.1', '404', 'Not Found'))).to(be(false))
    end

    it 'is false for a 5xx server error' do
      response = Net::HTTPInternalServerError.new('1.1', '500', 'Error')
      expect(HttpLoader::Client::HttpSession.success?(response)).to(be(false))
    end
  end

  describe '#run' do
    it 'issues a keep-alive GET to the URI path carrying the configured headers first' do
      allow(HttpLoader::Client::Pacing).to(receive(:budget_remaining).and_return(0.0))
      session.run(connection)
      expect(http).to(
        have_received(:request).with(
          keep_alive_request(Net::HTTP::Get, path: '/', user_agent: 'UA/1', headers: { 'X-Foo' => 'bar' })
        ).once
      )
    end

    context 'with budget left for one heartbeat' do
      before do
        allow(HttpLoader::Client::Pacing).to(receive(:budget_remaining).and_return(0.1, 0.0))
        session.run(connection)
      end

      it 'measures the budget against the keep-alive timeout from the connection start' do
        expect(HttpLoader::Client::Pacing).to(have_received(:budget_remaining).with(0.1, Time.at(0)).twice)
      end

      it 'pings with a keep-alive HEAD carrying the configured headers' do
        expect(http).to(
          have_received(:request).with(
            keep_alive_request(Net::HTTP::Head, path: '/', user_agent: 'UA/1', headers: { 'X-Foo' => 'bar' })
          )
        )
      end

      it 'waits the ping period (3.0s), capped to the remaining budget (0.1s), before the ping' do
        expect(session).to(have_received(:sleep).with(eql(0.1)).once)
      end

      it 'logs the connection label once the budget is spent' do
        expect(logger).to(have_received(:info).with('[Client 3] Keep-alive timeout reached, closing.'))
      end
    end

    context 'when the budget is exactly exhausted' do
      before do
        allow(HttpLoader::Client::Pacing).to(receive(:budget_remaining).and_return(0.0, -1.0))
        session.run(connection)
      end

      it('sends no heartbeat') { expect(http).to(have_received(:request).once) }

      it 'logs the timeout' do
        expect(logger).to(have_received(:info).with('[Client 3] Keep-alive timeout reached, closing.'))
      end
    end

    it 'stops on a negative (overrun) budget, not only on exactly zero' do
      allow(HttpLoader::Client::Pacing).to(receive(:budget_remaining).and_return(-0.5, 0.0))
      session.run(connection)
      expect(http).to(have_received(:request).once)
    end

    context 'when a heartbeat fails' do
      let(:overrides) { { track_status_codes: true } }

      before do
        allow(HttpLoader::Client::Pacing).to(receive(:budget_remaining).and_return(5.0))
        allow(http).to(
          receive(:request).and_return(
            Net::HTTPOK.new('1.1', '200', 'OK'),
            Net::HTTPInternalServerError.new('1.1', '500', 'Error')
          )
        )
        session.run(connection)
      end

      it('closes the connection after it') { expect(http).to(have_received(:request).twice) }

      it 'logs the failed status with the connection label' do
        expect(logger).to(have_received(:status).with('[Client 3] Upstream returned HTTP 500').once)
      end

      it('does not log a timeout') { expect(logger).not_to(have_received(:info)) }
    end

    context 'when a heartbeat fails and status codes are not tracked' do
      before do
        allow(HttpLoader::Client::Pacing).to(receive(:budget_remaining).and_return(5.0))
        allow(http).to(
          receive(:request).and_return(Net::HTTPOK.new('1.1', '200', 'OK'), Net::HTTPNotFound.new('1.1', '404', 'NF'))
        )
        session.run(connection)
      end

      it('closes the connection after it') { expect(http).to(have_received(:request).twice) }
      it('logs no status') { expect(logger).not_to(have_received(:status)) }
    end

    context 'with status codes tracked and only successful heartbeats' do
      let(:overrides) { { track_status_codes: true } }

      it 'logs no status' do
        allow(HttpLoader::Client::Pacing).to(receive(:budget_remaining).and_return(5.0, 0.0))
        session.run(connection)
        expect(logger).not_to(have_received(:status))
      end
    end

    context 'with a QPS rate' do
      let(:overrides) { { qps_per_connection: 4 } }

      before do
        allow(HttpLoader::Client::Pacing).to(receive(:budget_remaining).and_return(5.0, 0.0))
        session.run(connection)
      end

      it 'sends a keep-alive GET as the heartbeat' do
        expect(http).to(
          have_received(:request).with(
            keep_alive_request(Net::HTTP::Get, path: '/', user_agent: 'UA/1', headers: { 'X-Foo' => 'bar' })
          ).twice
        )
      end

      it('paces by 1/qps') { expect(session).to(have_received(:sleep).with(eql(0.25))) }
    end

    context 'with neither a QPS rate nor pings' do
      let(:overrides) { { ping: false } }

      before do
        allow(HttpLoader::Client::Pacing).to(receive(:budget_remaining).and_return(5.0, 0.2, 0.0))
        session.run(connection)
      end

      it('sends no heartbeat request') { expect(http).to(have_received(:request).once) }

      it 'idles one second at a time, capped to the remaining budget', :aggregate_failures do
        expect(session).to(have_received(:sleep).with(eql(1.0)).ordered)
        expect(session).to(have_received(:sleep).with(eql(0.2)).ordered)
      end
    end

    context 'with an unbounded (nil) budget' do
      let(:overrides) { { http_loader_timeout: 0.0 } }

      it 'keeps sending heartbeats' do
        calls = 0
        allow(http).to(receive(:request)) do
          (calls += 1) > 3 ? raise(StandardError, 'stop-the-loop') : Net::HTTPOK.new('1.1', '200', 'OK')
        end
        expect { session.run(connection) }
          .to(raise_error('stop-the-loop'))
      end
    end

    context 'with a jitter' do
      let(:overrides) { { jitter: 0.5, ping_period: 2.0 } }

      it 'spreads the heartbeat interval by it' do
        allow(HttpLoader::Client::Pacing).to(receive(:budget_remaining).and_return(nil, 0.0))
        allow(HttpLoader::Client::Pacing).to(receive(:rand).and_return(0.5))
        session.run(connection)
        expect(session).to(have_received(:sleep).with(eql(2.5)))
      end
    end
  end
end
