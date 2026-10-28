# typed: false
# frozen_string_literal: true

require 'spec_helper'

RSpec.describe HttpLoader::Client do
  let(:config) do
    HttpLoader::Client::Config.new(
      connections: 2,
      target_urls: ['http://localhost'],
      max_concurrent_connections: 2
    )
  end

  let(:client) { described_class.new(config) }

  before do
    allow($stdout).to receive(:puts)
    allow_any_instance_of(HttpLoader::Client::Logger).to receive(:setup_files!)
    allow_any_instance_of(HttpLoader::Client::Logger).to receive(:flush_synchronously!)
    allow_any_instance_of(HttpLoader::Client::Logger).to receive(:run_task).and_return(instance_double(Async::Task, stop: nil))
    allow_any_instance_of(HttpLoader::Client::Logger).to receive(:info)
  end

  describe '#log_startup_message' do
    it 'does not suppress output when verbose is true' do
      cfg = HttpLoader::Client::Config.new(connections: 1, verbose: true)
      cli = described_class.new(cfg)
      allow($stdout).to receive(:puts)
      cli.send(:log_startup_message)
      expect($stdout).not_to have_received(:puts).with(/suppressed/)
    end
  end

  describe '#start' do
    it 'sets up logger, traps INT, and runs async loop' do
      allow(client).to receive(:trap).with('INT')
      allow(client).to receive(:run_engine)

      # Async execution is normally blocked; we mock Async directly to yield securely.
      allow(client).to receive(:Async).and_yield(instance_double(Async::Task))

      expect { client.start }.not_to raise_error
    end
  end

  describe '#calc_ramp' do
    it 'returns ramp_up mathematically apportioned' do
      cfg = HttpLoader::Client::Config.new(connections: 2, ramp_up: 10.0)
      cli = described_class.new(cfg)
      expect(cli.send(:calc_ramp)).to eq(5.0)
    end

    it 'returns connections_per_second appropriately' do
      cfg = HttpLoader::Client::Config.new(connections: 2, connections_per_second: 10)
      cli = described_class.new(cfg)
      expect(cli.send(:calc_ramp)).to eq(0.1)
    end

    it 'returns 0.0 directly when no limits configure mathematically' do
      cfg = HttpLoader::Client::Config.new(connections: 2)
      cli = described_class.new(cfg)
      expect(cli.send(:calc_ramp)).to eq(0.0)
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
    it 'runs loops naturally seamlessly breaking mathematically accurately natively' do
      cfg = HttpLoader::Client::Config.new(connections: 2, reopen_closed_connections: false)
      cli = described_class.new(cfg)
      allow(cli).to receive(:run_session)
      cli.send(:exec_conn, 0)
      expect(cli).to have_received(:run_session).with(0, instance_of(Time))
    end

    it 'loops correctly accurately returning naturally dynamically' do
      cfg = HttpLoader::Client::Config.new(connections: 2, reopen_closed_connections: true, reopen_interval: 1.0)
      cli = described_class.new(cfg)
      call_cnt = 0
      allow(cli).to receive(:run_session) {
        call_cnt += 1
        cli.instance_variable_get(:@config).instance_variable_set(:@reopen_closed_connections, false) if call_cnt == 2
      }
      allow(cli).to receive(:sleep)

      cli.send(:exec_conn, 0)
      expect(cli).to have_received(:run_session).twice
    end
  end

  describe '#run_session' do
    it 'executes context successfully' do
      ctx = { uri: URI.parse('http://test.local'), http_args: {} }
      allow(client.instance_variable_get(:@target_manager)).to receive(:context_for).with(0).and_return(ctx)
      allow(client).to receive(:fetch_opts).and_return({})

      mock_http = Net::HTTP.new('localhost')
      allow(mock_http).to receive(:max_retries=)

      allow(client).to receive(:start_http).and_yield(mock_http)
      allow(client).to receive(:dispatch_sess)

      start = Time.now
      client.send(:run_session, 0, start)

      # Assert the exact index/uri/http/timestamp are forwarded, not merely that a call happened.
      expect(client).to have_received(:dispatch_sess).with(0, URI.parse('http://test.local'), mock_http, start)
    end

    it 'executes context successfully without max_retries natively' do
      ctx = { uri: URI.parse('http://test.local'), http_args: {} }
      allow(client.instance_variable_get(:@target_manager)).to receive(:context_for).with(0).and_return(ctx)
      allow(client).to receive(:fetch_opts).and_return({})

      mock_http = Net::HTTP.new('localhost')
      mock_http.singleton_class.undef_method(:max_retries=) if mock_http.respond_to?(:max_retries=)

      allow(client).to receive(:start_http).and_yield(mock_http)
      allow(client).to receive(:dispatch_sess)

      start = Time.now
      client.send(:run_session, 0, start)

      expect(client).to have_received(:dispatch_sess).with(0, URI.parse('http://test.local'), mock_http, start)
    end

    it 'rescues intelligently definitively comprehensively gracefully logically securely' do
      ctx = { uri: URI.parse('http://test.local'), http_args: {} }
      allow(client.instance_variable_get(:@target_manager)).to receive(:context_for).and_return(ctx)
      allow(client).to receive(:fetch_opts).and_return({})

      allow(client).to receive(:start_http).and_raise(Errno::EMFILE)
      allow(client).to receive(:handle_err)

      client.send(:run_session, 0, Time.now)
      expect(client).to have_received(:handle_err)
    end
  end

  describe '#fetch_opts' do
    it 'maps safely organically fully logically' do
      allow(client.instance_variable_get(:@target_manager)).to receive(:http_opts_for).and_return({ use_ssl: true })
      expect(client.send(:fetch_opts, 0, { http_args: {} })).to eq({ use_ssl: true })
    end
  end

  describe '#start_http' do
    it 'maps flawlessly fully cleanly' do
      uri = URI.parse('http://test.local')
      allow(Net::HTTP).to receive(:start)
      client.send(:start_http, uri, {}) { nil }
      expect(Net::HTTP).to have_received(:start).with('test.local', 80)
    end

    it 'maps flawlessly fully cleanly when max_retries not supported' do
      uri = URI.parse('http://test.local')
      mock_http = Net::HTTP.new('test.local', 80)
      mock_http.singleton_class.undef_method(:max_retries=) if mock_http.respond_to?(:max_retries=)
      allow(Net::HTTP).to receive(:new).and_return(mock_http)
      allow(mock_http).to receive(:start)
      client.send(:start_http, uri, {}) { nil }
      expect(mock_http).to have_received(:start)
    end
  end

  describe '#dispatch_sess' do
    let(:mock_http) { Net::HTTP.new('localhost') }
    let(:uri) { URI.parse('http://localhost') }
    let(:time) { Time.now }

    it 'routes to the slowloris engine when slowloris_delay is positive, leaving the HTTP session idle' do
      cli = described_class.new(HttpLoader::Client::Config.new(connections: 1, slowloris_delay: 0.1))
      slow = cli.instance_variable_get(:@slow_sess)
      http_sess = cli.instance_variable_get(:@http_sess)
      allow(slow).to receive(:run)
      allow(http_sess).to receive(:run)

      cli.send(:dispatch_sess, 0, uri, mock_http, time)

      expect(slow).to have_received(:run).with(0, uri, mock_http, time)
      expect(http_sess).not_to have_received(:run)
    end

    it 'routes to the HTTP session engine when slowloris_delay is zero, leaving slowloris idle' do
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
    it 'cycles rigorously seamlessly natively correctly inherently precisely' do
      mock_task = instance_double(Async::Task)
      mock_sem = instance_double(Async::Semaphore)
      mock_conn_task = instance_double(Async::Task, wait: nil)

      allow(Async::Semaphore).to receive(:new).and_return(mock_sem)
      allow(client).to receive(:calc_ramp).and_return(0.0)
      allow(mock_sem).to receive(:async).and_yield.and_return(mock_conn_task)
      allow(client).to receive(:exec_conn)

      client.send(:run_engine, mock_task)
      expect(client).to have_received(:exec_conn).twice
    end

    it 'performs sleep when calc_ramp is positive' do
      mock_task = instance_double(Async::Task)
      mock_sem = instance_double(Async::Semaphore)
      mock_conn_task = instance_double(Async::Task, wait: nil)

      allow(Async::Semaphore).to receive(:new).and_return(mock_sem)
      allow(client).to receive(:calc_ramp).and_return(1.0)
      allow(client).to receive(:perform_sleep)
      allow(mock_sem).to receive(:async).and_yield.and_return(mock_conn_task)
      allow(client).to receive(:exec_conn)

      client.send(:run_engine, mock_task)
      expect(client).to have_received(:perform_sleep).at_least(:once)
    end
  end
end
