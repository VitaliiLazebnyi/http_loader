# typed: true
# frozen_string_literal: true

# Copyright (c) 2026 Vitalii Lazebnyi

require 'spec_helper'

RSpec.describe(HttpLoader::Client) do
  let(:client) { HttpLoader::Client.new(config) }

  let(:config) do
    HttpLoader::Client::Config.new(
      connections: 2, target_urls: ['http://localhost'], max_concurrent_connections: 2, jitter: 0.0
    )
  end

  describe '#initialize' do
    it 'validates the config, rejecting an out-of-bounds value' do
      expect { HttpLoader::Client.new(HttpLoader::Client::Config.new(connections: 0)) }
        .to(raise_error(ArgumentError, /connections_count/))
    end

    it 'builds a logger carrying the verbose flag', :aggregate_failures do
      cli = HttpLoader::Client.new(HttpLoader::Client::Config.new(connections: 1, verbose: true))
      expect(cli.logger.is_a?(HttpLoader::Client::Logger)).to(be(true))
      expect(cli.logger.instance_variable_get(:@verbose)).to(be(true))
    end

    it 'keeps the config' do
      expect(client.instance_variable_get(:@config)).to(be(config))
    end

    it 'builds a target manager' do
      expect(client.instance_variable_get(:@target_manager).is_a?(HttpLoader::Client::TargetManager)).to(be(true))
    end

    it 'runs the connections with an HTTP session engine given the config and the logger', :aggregate_failures do
      session = client.instance_variable_get(:@session)
      expect(session.instance_of?(HttpLoader::Client::HttpSession)).to(be(true))
      expect(session.instance_variable_get(:@config)).to(be(config))
      expect(session.instance_variable_get(:@logger)).to(be(client.logger))
    end

    it 'runs them with a Slowloris engine given the config and the logger when slowloris_delay is positive',
      :aggregate_failures do
      cli = HttpLoader::Client.new(HttpLoader::Client::Config.new(connections: 1, slowloris_delay: 0.1))
      session = cli.instance_variable_get(:@session)
      expect(session.instance_of?(HttpLoader::Client::Slowloris)).to(be(true))
      expect(session.instance_variable_get(:@config)).to(be(cli.instance_variable_get(:@config)))
      expect(session.instance_variable_get(:@logger)).to(be(cli.logger))
    end
  end

  describe '#start' do
    before do
      allow(client).to(receive(:log_startup_message))
      allow(client).to(receive(:trap))
      allow(HttpLoader::FileLimits).to(receive(:bump!))
      allow(client.logger).to(receive(:prepare_files))
      allow(client.logger).to(receive(:flush))
      allow(client).to(receive(:run_engine))
      allow(client).to(receive(:Async).and_yield(instance_double(Async::Task)))
      # Spy on (and neutralise) Kernel#exit so the INT handler can be asserted and a mutation that
      # runs exit(0) inline (in place of trap('INT') { exit(0) }) cannot tear down the test runner.
      allow(client).to(receive(:exit))
    end

    context 'when it runs to completion' do
      before { client.start }

      it('logs the startup message') { expect(client).to(have_received(:log_startup_message)) }
      it('traps INT') { expect(client).to(have_received(:trap).with('INT')) }
      it('sets up the log files') { expect(client.logger).to(have_received(:prepare_files)) }
      it('runs the engine') { expect(client).to(have_received(:run_engine)) }
      it('flushes the logger') { expect(client.logger).to(have_received(:flush)) }

      it 'raises the fd limit by the connection count plus headroom' do
        expect(HttpLoader::FileLimits).to(have_received(:bump!).with(config.connections + 1024, label: '[Client]'))
      end
    end

    it 'still flushes the logger when the engine raises', :aggregate_failures do
      allow(client).to(receive(:run_engine).and_raise(StandardError))
      expect { client.start }
        .to(raise_error(StandardError))
      expect(client.logger).to(have_received(:flush))
    end

    it 'installs an INT handler that exits with an explicit status 0' do
      captured = T.let(nil, T.nilable(Proc))
      allow(client).to(receive(:trap).with('INT') { |_signal, &block| captured = block })
      client.start
      T.must(captured).call
      expect(client).to(have_received(:exit).with(0))
    end
  end

  describe '#log_startup_message' do
    let(:lines) { [] }

    before do
      allow($stdout).to(receive(:puts) { |*args| lines.concat(args) })
      allow(client.logger).to(receive(:info))
    end

    it 'logs the connection count and protocol' do
      client.__send__(:log_startup_message)
      expect(client.logger).to(have_received(:info).with('Starting 2 EXTERNAL HTTP connections'))
    end

    it 'prints the connection count and protocol, plus the suppression note' do
      client.__send__(:log_startup_message)
      expect(lines).to(
        eq(
          [
            '[Client] Starting 2 EXTERNAL HTTP connections to targeted urls...',
            '[Client] Note: Output of individual pings is suppressed.'
          ]
        )
      )
    end

    it 'omits the suppression note when verbose' do
      cli = HttpLoader::Client.new(
        HttpLoader::Client::Config.new(
          **config.serialize.transform_keys(&:to_sym),
          verbose: true
        )
      )
      allow(cli.logger).to(receive(:info))
      cli.__send__(:log_startup_message)
      expect(lines).to(eq(['[Client] Starting 2 EXTERNAL HTTP connections to targeted urls...']))
    end
  end

  describe '#calc_ramp' do
    it 'apportions ramp_up across the connections' do
      cli = HttpLoader::Client.new(HttpLoader::Client::Config.new(connections: 2, ramp_up: 10.0))
      expect(cli.__send__(:calc_ramp)).to(eq(5.0))
    end

    it 'uses a sub-one ramp_up over connections (ramp_up takes precedence, boundary is > 0)' do
      cli = HttpLoader::Client.new(
        HttpLoader::Client::Config.new(connections: 2, ramp_up: 0.5, connections_per_second: 10)
      )
      expect(cli.__send__(:calc_ramp)).to(eq(0.25))
    end

    it 'falls back to the connections-per-second interval' do
      cli = HttpLoader::Client.new(HttpLoader::Client::Config.new(connections: 2, connections_per_second: 10))
      expect(cli.__send__(:calc_ramp)).to(eq(0.1))
    end

    it 'is zero when no pacing is configured' do
      expect(HttpLoader::Client.new(HttpLoader::Client::Config.new(connections: 2)).__send__(:calc_ramp)).to(eq(0.0))
    end
  end

  describe '#exec_conn' do
    it 'runs a single session when reopen is disabled' do
      cli = HttpLoader::Client.new(HttpLoader::Client::Config.new(connections: 2, reopen_closed_connections: false))
      allow(cli).to(receive(:run_session))
      cli.__send__(:exec_conn, 0)
      expect(cli).to(have_received(:run_session).with(0, instance_of(Time)).once)
    end

    context 'when reopen is enabled' do
      let(:cli) do
        HttpLoader::Client.new(
          HttpLoader::Client::Config.new(
            connections: 2,
            reopen_closed_connections: true,
            reopen_interval: 1.0,
            jitter: 0.0
          )
        )
      end

      before do
        calls = 0
        allow(cli).to(receive(:run_session)) do
          calls += 1
          cli.instance_variable_get(:@config).instance_variable_set(:@reopen_closed_connections, false) if calls == 2
        end
        allow(cli).to(receive(:sleep))
        cli.__send__(:exec_conn, 0)
      end

      it('reopens until reopen is turned off') { expect(cli).to(have_received(:run_session).twice) }

      it 'sleeps the jittered reopen interval (1.0 with no jitter) between sessions' do
        expect(cli).to(have_received(:sleep).with(1.0))
      end
    end
  end

  describe '#run_session' do
    let(:mock_http) { Net::HTTP.new('localhost')              }
    let(:session)   { client.instance_variable_get(:@session) }
    let(:target) do
      HttpLoader::Client::TargetManager::Target.new(uri: URI('http://test.local'), http_args: { a: 1 })
    end

    before do
      target_manager = client.instance_variable_get(:@target_manager)
      allow(target_manager).to(receive(:context_for).with(5).and_return(target))
      allow(target_manager).to(receive(:http_opts_for).with(5, { a: 1 }).and_return({ opt: 1 }))
      allow(HttpLoader::Client).to(receive(:start_http).and_yield(mock_http))
      allow(session).to(receive(:run))
      allow(client.logger).to(receive(:info))
    end

    context 'when the connection opens' do
      before { client.__send__(:run_session, 5, Time.at(0)) }

      it 'starts HTTP to the target URI with the options of the worker' do
        expect(HttpLoader::Client).to(have_received(:start_http).with(target.uri, { opt: 1 }))
      end

      it 'runs the session on the connection' do
        expect(session).to(
          have_received(:run).with(having_attributes(index: 5, uri: target.uri, http: mock_http, started: Time.at(0)))
        )
      end

      it 'logs the established and the closed connection', :aggregate_failures do
        expect(client.logger).to(have_received(:info).with('[Client 5] Connection established to test.local.'))
        expect(client.logger).to(have_received(:info).with('[Client 5] Connection gracefully closed.'))
      end
    end

    context 'when the connection fails' do
      before do
        allow(client).to(receive(:handle_err))
        allow(HttpLoader::Client).to(receive(:start_http).and_raise(Errno::EMFILE))
        client.__send__(:run_session, 5, Time.at(0))
      end

      it('routes the error to handle_err with the index') {
        expect(client).to(have_received(:handle_err).with(5, an_instance_of(Errno::EMFILE)))
      }

      it('logs no closed connection') { expect(client.logger).not_to(have_received(:info)) }
    end
  end

  describe '.start_http' do
    before { allow(Net::HTTP).to(receive(:start).and_yield(:the_http)) }

    it 'starts Net::HTTP with host, port and options' do
      HttpLoader::Client.start_http(URI('http://test.local'), { use_ssl: true }) { |_http| nil }
      expect(Net::HTTP).to(have_received(:start).with('test.local', 80, use_ssl: true))
    end

    it 'forwards the block' do
      expect { |probe| HttpLoader::Client.start_http(URI('http://test.local'), {}, &probe) }
        .to(yield_with_args(:the_http))
    end
  end

  describe '#run_engine' do
    let(:task)        { instance_double(Async::Task)            }
    let(:logger_task) { instance_double(Async::Task, stop: nil) }
    let(:conn_task)   { instance_double(Async::Task, wait: nil) }

    before do
      semaphore = instance_double(Async::Semaphore)
      allow(client.logger).to(receive(:run_task).and_return(logger_task))
      allow(Async::Semaphore).to(receive(:new).and_return(semaphore))
      allow(semaphore).to(receive(:async).and_yield.and_return(conn_task))
      allow(client).to(receive_messages(exec_conn: nil, calc_ramp: 0.0, sleep: nil))
    end

    context 'when the ramp is zero' do
      before { client.__send__(:run_engine, task) }

      it('starts the logger task on the reactor task') { expect(client.logger).to(have_received(:run_task).with(task)) }
      it('waits for every connection task') { expect(conn_task).to(have_received(:wait).twice) }
      it('stops the logger task') { expect(logger_task).to(have_received(:stop)) }
      it('does not pace') { expect(client).not_to(have_received(:sleep)) }

      it 'caps the concurrency with a semaphore under the reactor task' do
        expect(Async::Semaphore).to(have_received(:new).with(config.max_concurrent_connections, parent: task))
      end

      it 'spawns a worker per connection', :aggregate_failures do
        expect(client).to(have_received(:exec_conn).with(0))
        expect(client).to(have_received(:exec_conn).with(1))
      end
    end

    context 'when the ramp is positive' do
      before do
        allow(client).to(receive(:calc_ramp).and_return(1.0))
        client.__send__(:run_engine, task)
      end

      it 'paces between connections, not before the first' do
        expect(client).to(have_received(:sleep).with(1.0).once)
      end
    end
  end
end
