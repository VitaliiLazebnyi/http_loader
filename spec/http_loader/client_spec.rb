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

    it 'builds a Slowloris engine and an HTTP session engine', :aggregate_failures do
      expect(client.instance_variable_get(:@slow_sess).is_a?(HttpLoader::Client::Slowloris)).to(be(true))
      expect(client.instance_variable_get(:@http_sess).is_a?(HttpLoader::Client::HttpSession)).to(be(true))
    end

    it 'gives both engines the config and the logger', :aggregate_failures do
      engines = [client.instance_variable_get(:@slow_sess), client.instance_variable_get(:@http_sess)]
      expect(engines.map { |engine| engine.instance_variable_get(:@config) }).to(all(be(config)))
      expect(engines.map { |engine| engine.instance_variable_get(:@logger) }).to(all(be(client.logger)))
    end
  end

  describe '#start' do
    before do
      allow(client).to(receive(:log_startup_message))
      allow(client).to(receive(:trap))
      allow(HttpLoader::FileLimits).to(receive(:bump!))
      allow(client.logger).to(receive(:setup_files!))
      allow(client.logger).to(receive(:flush_synchronously!))
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
      it('sets up the log files') { expect(client.logger).to(have_received(:setup_files!)) }
      it('runs the engine') { expect(client).to(have_received(:run_engine)) }
      it('flushes the logger') { expect(client.logger).to(have_received(:flush_synchronously!)) }

      it 'raises the fd limit by the connection count plus headroom' do
        expect(HttpLoader::FileLimits).to(have_received(:bump!).with(config.connections + 1024, label: '[Client]'))
      end
    end

    it 'still flushes the logger when the engine raises', :aggregate_failures do
      allow(client).to(receive(:run_engine).and_raise(StandardError))
      expect { client.start }
        .to(raise_error(StandardError))
      expect(client.logger).to(have_received(:flush_synchronously!))
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

  describe '#perform_sleep' do
    it 'delegates to the reactor-aware Kernel#sleep' do
      allow(client).to(receive(:sleep))
      client.__send__(:perform_sleep, 0.1)
      expect(client).to(have_received(:sleep).with(0.1))
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
    let(:mock_http) { Net::HTTP.new('localhost') }
    let(:start)     { Time.now                   }
    let(:target) do
      HttpLoader::Client::TargetManager::Target.new(uri: URI('http://test.local'), http_args: { a: 1 })
    end

    before do
      allow(client.instance_variable_get(:@target_manager)).to(receive(:context_for).with(5).and_return(target))
      allow(client).to(receive(:fetch_opts).and_return({ opt: 1 }))
      allow(mock_http).to(receive(:max_retries=))
      allow(client).to(receive(:start_http).and_yield(mock_http))
      allow(client).to(receive(:dispatch_sess))
      allow(client.logger).to(receive(:info))
    end

    context 'when the connection opens' do
      before { client.__send__(:run_session, 5, start) }

      it('resolves the options for the target') { expect(client).to(have_received(:fetch_opts).with(5, target)) }
      it('starts HTTP to the target URI') { expect(client).to(have_received(:start_http).with(target.uri, { opt: 1 })) }
      it('disables retries') { expect(mock_http).to(have_received(:max_retries=).with(0)) }

      it 'dispatches the session' do
        expect(client).to(have_received(:dispatch_sess).with(5, target.uri, mock_http, start))
      end

      it 'logs the established and the closed connection', :aggregate_failures do
        expect(client.logger).to(have_received(:info).with('[Client 5] Connection established to test.local.'))
        expect(client.logger).to(have_received(:info).with('[Client 5] Connection gracefully closed.'))
      end
    end

    it 'skips max_retries= when the connection does not support it' do
      allow(mock_http).to(receive(:respond_to?).with(:max_retries=).and_return(false))
      client.__send__(:run_session, 5, start)
      expect(mock_http).not_to(have_received(:max_retries=))
    end

    it 'routes a raised error to handle_err with the index and the exception' do
      boom = Errno::EMFILE.new
      allow(client).to(receive_messages(start_http: nil, handle_err: nil))
      allow(client).to(receive(:start_http).and_raise(boom))
      client.__send__(:run_session, 5, start)
      expect(client).to(have_received(:handle_err).with(5, boom))
    end
  end

  describe '#fetch_opts' do
    let(:target_manager) { client.instance_variable_get(:@target_manager) }
    let(:target) { HttpLoader::Client::TargetManager::Target.new(uri: URI('http://a'), http_args: { a: 2 }) }

    before { allow(target_manager).to(receive(:http_opts_for).and_return({ use_ssl: true })) }

    it 'returns the options resolved by the target manager' do
      expect(client.__send__(:fetch_opts, 3, target)).to(eq({ use_ssl: true }))
    end

    it 'resolves them with the index and the target HTTP args' do
      client.__send__(:fetch_opts, 3, target)
      expect(target_manager).to(have_received(:http_opts_for).with(3, { a: 2 }))
    end
  end

  describe '#start_http' do
    before { allow(Net::HTTP).to(receive(:start).and_yield(:the_http)) }

    it 'starts Net::HTTP with host, port and options' do
      client.__send__(:start_http, URI('http://test.local'), { use_ssl: true }) { |_http| nil }
      expect(Net::HTTP).to(have_received(:start).with('test.local', 80, use_ssl: true))
    end

    it 'forwards the block' do
      expect { |probe| client.__send__(:start_http, URI('http://test.local'), {}, &probe) }
        .to(yield_with_args(:the_http))
    end
  end

  describe '#dispatch_sess' do
    let(:session) { [0, URI('http://localhost'), Net::HTTP.new('localhost'), Time.now] }
    let(:slowloris_delay) { 0.0 }
    let(:cli) do
      HttpLoader::Client.new(HttpLoader::Client::Config.new(connections: 1, slowloris_delay: slowloris_delay))
    end

    before do
      allow(cli.instance_variable_get(:@slow_sess)).to(receive(:run))
      allow(cli.instance_variable_get(:@http_sess)).to(receive(:run))
      cli.__send__(:dispatch_sess, *session)
    end

    context 'when slowloris_delay is positive' do
      let(:slowloris_delay) { 0.1 }

      it 'routes to the slowloris engine only', :aggregate_failures do
        expect(cli.instance_variable_get(:@slow_sess)).to(have_received(:run).with(*session))
        expect(cli.instance_variable_get(:@http_sess)).not_to(have_received(:run))
      end
    end

    context 'when slowloris_delay is zero' do
      it 'routes to the HTTP session engine only', :aggregate_failures do
        expect(cli.instance_variable_get(:@http_sess)).to(have_received(:run).with(*session))
        expect(cli.instance_variable_get(:@slow_sess)).not_to(have_received(:run))
      end
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
      allow(client).to(receive_messages(exec_conn: nil, calc_ramp: 0.0, perform_sleep: nil))
    end

    context 'when the ramp is zero' do
      before { client.__send__(:run_engine, task) }

      it('starts the logger task on the reactor task') { expect(client.logger).to(have_received(:run_task).with(task)) }
      it('waits for every connection task') { expect(conn_task).to(have_received(:wait).twice) }
      it('stops the logger task') { expect(logger_task).to(have_received(:stop)) }
      it('does not pace') { expect(client).not_to(have_received(:perform_sleep)) }

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
        expect(client).to(have_received(:perform_sleep).with(1.0).once)
      end
    end
  end
end
