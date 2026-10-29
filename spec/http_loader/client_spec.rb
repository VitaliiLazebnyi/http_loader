# typed: false
# frozen_string_literal: true

require 'spec_helper'

RSpec.describe HttpLoader::Client do
  let(:config) do
    HttpLoader::Client::Config.new(
      connections: 2, target_urls: ['http://localhost'], max_concurrent_connections: 2, jitter: 0.0
    )
  end
  let(:client) { described_class.new(config) }
  let(:lines) { [] }

  before { allow($stdout).to receive(:puts) { |*args| lines.concat(args) } }

  describe '#initialize' do
    it 'validates the config, rejecting an out-of-bounds value' do
      expect { described_class.new(HttpLoader::Client::Config.new(connections: 0)) }
        .to raise_error(ArgumentError, /connections_count/)
    end

    it 'builds a logger carrying the verbose flag' do
      cli = described_class.new(HttpLoader::Client::Config.new(connections: 1, verbose: true))
      expect(cli.logger).to be_a(HttpLoader::Client::Logger)
      expect(cli.logger.instance_variable_get(:@verbose)).to be(true)
    end

    it 'wires the target manager and both session engines with the config and logger' do
      expect(client.instance_variable_get(:@config)).to eq(config)
      expect(client.instance_variable_get(:@target_manager)).to be_a(HttpLoader::Client::TargetManager)
      [client.instance_variable_get(:@slow_sess), client.instance_variable_get(:@http_sess)].each do |engine|
        expect(engine.instance_variable_get(:@config)).to eq(config)
        expect(engine.instance_variable_get(:@logger)).to be(client.logger)
      end
      expect(client.instance_variable_get(:@slow_sess)).to be_a(HttpLoader::Client::Slowloris)
      expect(client.instance_variable_get(:@http_sess)).to be_a(HttpLoader::Client::HttpSession)
    end
  end

  describe '#start' do
    before do
      allow(client).to receive(:log_startup_message)
      allow(client).to receive(:trap)
      allow(HttpLoader::FileLimits).to receive(:bump!)
      allow(client.logger).to receive(:setup_files!)
      allow(client.logger).to receive(:flush_synchronously!)
      allow(client).to receive(:run_engine)
      allow(client).to receive(:Async).and_yield(instance_double(Async::Task))
      # Spy on (and neutralise) Kernel#exit so the INT handler can be asserted and a mutation that
      # runs exit(0) inline (in place of trap('INT') { exit(0) }) cannot tear down the test runner.
      allow(client).to receive(:exit)
    end

    it 'logs, bumps the fd limit, sets up files, traps INT, runs the engine, and flushes on exit' do
      client.start
      expect(client).to have_received(:log_startup_message)
      expect(client).to have_received(:trap).with('INT')
      expect(HttpLoader::FileLimits).to have_received(:bump!).with(config.connections + 1024, label: '[Client]')
      expect(client.logger).to have_received(:setup_files!)
      expect(client).to have_received(:run_engine)
      expect(client.logger).to have_received(:flush_synchronously!)
    end

    it 'still flushes the logger when the engine raises' do
      allow(client).to receive(:run_engine).and_raise(StandardError)
      expect { client.start }.to raise_error(StandardError)
      expect(client.logger).to have_received(:flush_synchronously!)
    end

    it 'installs an INT handler that exits with an explicit status 0' do
      handler = nil
      allow(client).to receive(:trap).with('INT') { |*, &block| handler = block }
      client.start
      expect(handler).not_to be_nil
      handler.call
      expect(client).to have_received(:exit).with(0)
    end
  end

  describe '#log_startup_message' do
    before { allow(client.logger).to receive(:info) }

    it 'logs and prints the connection count and protocol, plus the suppression note' do
      client.send(:log_startup_message)
      expect(client.logger).to have_received(:info).with('Starting 2 EXTERNAL HTTP connections')
      expect(lines).to eq(
        [
          '[Client] Starting 2 EXTERNAL HTTP connections to targeted urls...',
          '[Client] Note: Output of individual pings is suppressed.'
        ]
      )
    end

    it 'omits the suppression note when verbose' do
      cli = described_class.new(config.with(verbose: true))
      allow(cli.logger).to receive(:info)
      cli.send(:log_startup_message)
      expect(lines).to eq(['[Client] Starting 2 EXTERNAL HTTP connections to targeted urls...'])
    end
  end

  describe '#calc_ramp' do
    it 'apportions ramp_up across the connections' do
      cli = described_class.new(HttpLoader::Client::Config.new(connections: 2, ramp_up: 10.0))
      expect(cli.send(:calc_ramp)).to eq(5.0)
    end

    it 'uses a sub-one ramp_up over connections (ramp_up takes precedence, boundary is > 0)' do
      cli = described_class.new(HttpLoader::Client::Config.new(connections: 2, ramp_up: 0.5, connections_per_second: 10))
      expect(cli.send(:calc_ramp)).to eq(0.25)
    end

    it 'falls back to the connections-per-second interval' do
      cli = described_class.new(HttpLoader::Client::Config.new(connections: 2, connections_per_second: 10))
      expect(cli.send(:calc_ramp)).to eq(0.1)
    end

    it 'is zero when no pacing is configured' do
      expect(described_class.new(HttpLoader::Client::Config.new(connections: 2)).send(:calc_ramp)).to eq(0.0)
    end
  end

  describe '#perform_sleep' do
    it 'delegates to the reactor-aware Kernel#sleep' do
      allow(client).to receive(:sleep)
      client.send(:perform_sleep, 0.1)
      expect(client).to have_received(:sleep).with(0.1)
    end
  end

  describe '#exec_conn' do
    it 'runs a single session when reopen is disabled' do
      cli = described_class.new(HttpLoader::Client::Config.new(connections: 2, reopen_closed_connections: false))
      allow(cli).to receive(:run_session)
      cli.send(:exec_conn, 0)
      expect(cli).to have_received(:run_session).with(0, instance_of(Time)).once
    end

    it 'reopens with a jittered reopen-interval sleep until reopen is turned off' do
      cli = described_class.new(
        HttpLoader::Client::Config.new(connections: 2, reopen_closed_connections: true, reopen_interval: 1.0, jitter: 0.0)
      )
      calls = 0
      allow(cli).to receive(:run_session) do
        calls += 1
        cli.instance_variable_get(:@config).instance_variable_set(:@reopen_closed_connections, false) if calls == 2
      end
      allow(cli).to receive(:sleep)
      cli.send(:exec_conn, 0)
      expect(cli).to have_received(:run_session).twice
      expect(cli).to have_received(:sleep).with(1.0) # jittered_interval(reopen_interval 1.0, jitter 0)
    end
  end

  describe '#run_session' do
    let(:mock_http) { Net::HTTP.new('localhost') }
    let(:ctx) { { uri: URI('http://test.local'), http_args: { a: 1 } } }

    before do
      allow(client.instance_variable_get(:@target_manager)).to receive(:context_for).with(5).and_return(ctx)
      allow(client).to receive(:fetch_opts).and_return({ opt: 1 })
      allow(mock_http).to receive(:max_retries=)
      allow(client).to receive(:start_http).and_yield(mock_http)
      allow(client).to receive(:dispatch_sess)
      allow(client.logger).to receive(:info)
    end

    it 'opens the connection, disables retries, logs establish/close, and dispatches the session' do
      start = Time.now
      client.send(:run_session, 5, start)
      expect(client).to have_received(:fetch_opts).with(5, ctx)
      expect(client).to have_received(:start_http).with(URI('http://test.local'), { opt: 1 })
      expect(mock_http).to have_received(:max_retries=).with(0)
      expect(client.logger).to have_received(:info).with('[Client 5] Connection established to test.local.')
      expect(client).to have_received(:dispatch_sess).with(5, URI('http://test.local'), mock_http, start)
      expect(client.logger).to have_received(:info).with('[Client 5] Connection gracefully closed.')
    end

    it 'skips max_retries= when the connection does not support it' do
      allow(mock_http).to receive(:respond_to?).with(:max_retries=).and_return(false)
      client.send(:run_session, 5, Time.now)
      expect(mock_http).not_to have_received(:max_retries=)
    end

    it 'routes a raised error to handle_err with the index and the exception' do
      boom = Errno::EMFILE.new
      allow(client).to receive(:start_http).and_raise(boom)
      allow(client).to receive(:handle_err)
      client.send(:run_session, 5, Time.now)
      expect(client).to have_received(:handle_err).with(5, boom)
    end
  end

  describe '#fetch_opts' do
    it 'resolves http_opts_for with the index and the context http_args' do
      tm = client.instance_variable_get(:@target_manager)
      allow(tm).to receive(:http_opts_for).and_return({ use_ssl: true })
      expect(client.send(:fetch_opts, 3, { http_args: { a: 2 } })).to eq({ use_ssl: true })
      expect(tm).to have_received(:http_opts_for).with(3, { a: 2 })
    end
  end

  describe '#start_http' do
    it 'starts Net::HTTP with host, port and options, forwarding the block' do
      allow(Net::HTTP).to receive(:start).and_yield(:the_http)
      yielded = nil
      client.send(:start_http, URI('http://test.local'), { use_ssl: true }) { |h| yielded = h }
      expect(Net::HTTP).to have_received(:start).with('test.local', 80, use_ssl: true)
      expect(yielded).to eq(:the_http)
    end
  end

  describe '#dispatch_sess' do
    let(:mock_http) { Net::HTTP.new('localhost') }
    let(:uri) { URI('http://localhost') }
    let(:time) { Time.now }

    it 'routes to the slowloris engine when slowloris_delay is positive' do
      cli = described_class.new(HttpLoader::Client::Config.new(connections: 1, slowloris_delay: 0.1))
      slow = cli.instance_variable_get(:@slow_sess)
      http_sess = cli.instance_variable_get(:@http_sess)
      allow(slow).to receive(:run)
      allow(http_sess).to receive(:run)
      cli.send(:dispatch_sess, 0, uri, mock_http, time)
      expect(slow).to have_received(:run).with(0, uri, mock_http, time)
      expect(http_sess).not_to have_received(:run)
    end

    it 'routes to the HTTP session engine when slowloris_delay is zero' do
      cli = described_class.new(HttpLoader::Client::Config.new(connections: 1, slowloris_delay: 0.0))
      slow = cli.instance_variable_get(:@slow_sess)
      http_sess = cli.instance_variable_get(:@http_sess)
      allow(slow).to receive(:run)
      allow(http_sess).to receive(:run)
      cli.send(:dispatch_sess, 0, uri, mock_http, time)
      expect(http_sess).to have_received(:run).with(0, uri, mock_http, time)
      expect(slow).not_to have_received(:run)
    end
  end

  describe '#run_engine' do
    let(:task) { instance_double(Async::Task) }
    let(:logger_task) { instance_double(Async::Task, stop: nil) }
    let(:sem) { instance_double(Async::Semaphore) }
    let(:conn_task) { instance_double(Async::Task, wait: nil) }

    before do
      allow(client.logger).to receive(:run_task).and_return(logger_task)
      allow(Async::Semaphore).to receive(:new).and_return(sem)
      allow(sem).to receive(:async).and_yield.and_return(conn_task)
      allow(client).to receive(:exec_conn)
    end

    it 'starts the logger task, builds the semaphore, spawns a worker per connection, waits, and stops' do
      allow(client).to receive(:calc_ramp).and_return(0.0)
      allow(client).to receive(:perform_sleep)
      client.send(:run_engine, task)
      expect(client.logger).to have_received(:run_task).with(task)
      expect(Async::Semaphore).to have_received(:new).with(config.max_concurrent_connections, parent: task)
      expect(client).to have_received(:exec_conn).with(0)
      expect(client).to have_received(:exec_conn).with(1)
      expect(conn_task).to have_received(:wait).twice
      expect(logger_task).to have_received(:stop)
      expect(client).not_to have_received(:perform_sleep) # ramp is 0 => no pacing
    end

    it 'paces between connections (not before the first) when the ramp is positive' do
      allow(client).to receive(:calc_ramp).and_return(1.0)
      allow(client).to receive(:perform_sleep)
      client.send(:run_engine, task)
      expect(client).to have_received(:perform_sleep).with(1.0).once # only the 2nd of 2 connections
    end
  end
end
