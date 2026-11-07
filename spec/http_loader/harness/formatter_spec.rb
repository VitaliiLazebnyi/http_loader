# typed: false
# frozen_string_literal: true

require 'spec_helper'
require 'http_loader/harness'

RSpec.describe HttpLoader::Harness::Formatter do
  let(:dummy_class) do
    Class.new(HttpLoader::Harness) do
      def initialize(config)
        super
        @config = config
      end
    end
  end

  let(:config) do
    HttpLoader::Harness::Config.new(
      target_urls: [], connections: 1, use_https: false, client_args: [], export_json: nil
    )
  end
  let(:harness) { dummy_class.new(config) }
  let(:lines) { [] }

  before { allow($stdout).to receive(:puts) { |*args| lines.concat(args) } }

  # Wires a mocked ResourceMonitor and ProcessManager onto the harness. Server pid 1 and client
  # pid 2 return deliberately different stats so field misroutes are visible.
  def stub_backends(server_pid: 1, client_pid: 2, server_conns: 16, client_conns: 5)
    stats = { server_pid => ['50.0', '100MB', 2048.0, 8], client_pid => ['30.0', '60MB', 1024.0, 4] }
    conns = { server_pid => server_conns, client_pid => client_conns }
    monitor = instance_double(HttpLoader::Harness::ResourceMonitor)
    allow(monitor).to receive(:process_stats) { |pid| stats.fetch(pid) }
    allow(monitor).to receive(:count_established_connections) { |pid| conns.fetch(pid) }
    harness.instance_variable_set(:@monitor, monitor)
    harness.instance_variable_set(
      :@pm, instance_double(HttpLoader::Harness::ProcessManager, server_pid:, client_pid:)
    )
  end

  # The exact formatted table row produced by the given column values.
  def row(fields)
    [
      fields.fetch(:t).ljust(10), fields.fetch(:ac).ljust(11), fields.fetch(:sc).ljust(16),
      fields.fetch(:sm).ljust(14), fields.fetch(:sk).ljust(14), fields.fetch(:cc).ljust(16),
      fields.fetch(:cm).ljust(14), fields.fetch(:ck).ljust(14)
    ].join(' | ')
  end

  describe '#startup_target_msg' do
    it 'describes multiple targets with their count' do
      expect(dummy_class.new(config.with(target_urls: %w[http://a http://b])).startup_target_msg)
        .to eq('**MULTIPLE TARGETS** (2 URLs).')
    end

    it 'names the single external URL' do
      expect(dummy_class.new(config.with(target_urls: ['http://local'])).startup_target_msg)
        .to eq('**EXTERNAL URL** http://local.')
    end

    it 'reports HTTPS when no URL is given and https is enabled' do
      expect(dummy_class.new(config.with(use_https: true)).startup_target_msg).to eq('**HTTPS**.')
    end

    it 'reports HTTP when no URL is given and https is disabled' do
      expect(dummy_class.new(config.with(use_https: false)).startup_target_msg).to eq('**HTTP**.')
    end
  end

  describe '#print_startup_banner' do
    it 'prints the connection count and the target description verbatim' do
      harness.print_startup_banner
      expect(lines).to eq(['[Harness] Starting test with 1 connections to **HTTP**.'])
    end
  end

  describe '#print_table_header' do
    it 'prints the banner, two full-width rules and the exact column header' do
      harness.print_table_header
      expect(lines).to eq(
        [
          '[Harness] Monitoring resources (Press Ctrl+C to stop)...',
          '-' * 125,
          'Time (UTC) | Real Conns  | Srv CPU/Thrds    | Srv Mem        | Srv Mem/Conn   | ' \
          'Cli CPU/Thrds    | Cli Mem        | Cli Mem/Conn  ',
          '-' * 125
        ]
      )
    end
  end

  describe '#format_kb_conn' do
    it 'returns EXTERNAL when the pid is nil' do
      expect(harness.format_kb_conn(10.0, 1, nil)).to eq('EXTERNAL')
    end

    it 'returns N/A when connections are zero' do
      expect(harness.format_kb_conn(10.0, 0, 123)).to eq('N/A')
    end

    it 'returns N/A when connections are negative' do
      expect(harness.format_kb_conn(10.0, -1, 123)).to eq('N/A')
    end

    it 'rounds the per-connection footprint to two decimals' do
      expect(harness.format_kb_conn(10.0, 3, 123)).to eq('3.33 KB')
    end
  end

  describe '#log_table_row' do
    it 'left-justifies every field to its column width, pipe-separated' do
      fields = {
        t: '12:34:56', ac: '10', sc: '50.0% / 8', sm: '100MB',
        sk: '128.0 KB', cc: '30.0% / 4', cm: '60MB', ck: '102.4 KB'
      }
      harness.log_table_row(fields)
      expect(lines).to eq([row(fields)])
    end
  end

  describe '#extract_server_stats' do
    it 'returns server cpu, mem, threads and the formatted mem/conn' do
      stub_backends
      expect(harness.extract_server_stats).to eq(['50.0', '100MB', 8, '128.0 KB'])
    end

    it 'labels the mem/conn EXTERNAL when the server pid is nil' do
      stub_backends(server_pid: nil)
      expect(harness.extract_server_stats).to eq(['50.0', '100MB', 8, 'EXTERNAL'])
    end
  end

  describe '#extract_client_stats' do
    it 'returns client active conns, cpu, threads and mem' do
      stub_backends
      expect(harness.extract_client_stats).to eq([5, '30.0', 4, '60MB'])
    end
  end

  describe '#print_combined_stats' do
    # #utc yields a real UTC time (so strftime format mutations are caught), while the receiver's
    # own #strftime returns a sentinel, so dropping the `.utc` call visibly changes the printed row.
    let(:frozen_now) { instance_double(Time, utc: Time.utc(2021, 1, 1, 7, 34, 56), strftime: 'LOCAL-NOT-UTC') }

    before { allow(Time).to receive(:now).and_return(frozen_now) }

    it 'prints a fully formatted row combining server and client metrics in UTC' do
      stub_backends
      harness.print_combined_stats(10, '30.0', 4, '60MB')
      expect(lines).to eq(
        [row(t: '07:34:56', ac: '10', sc: '50.0% / 8', sm: '100MB',
             sk: '128.0 KB', cc: '30.0% / 4', cm: '60MB', ck: '102.4 KB')]
      )
    end

    it 'labels the client mem/conn EXTERNAL when the client pid is nil' do
      stub_backends(client_pid: nil)
      harness.print_combined_stats(10, '30.0', 4, '60MB')
      expect(lines.first).to end_with("| #{'EXTERNAL'.ljust(14)}")
    end

    it 'labels the server mem/conn EXTERNAL when the server pid is nil' do
      stub_backends(server_pid: nil)
      harness.print_combined_stats(10, '30.0', 4, '60MB')
      expect(lines.first).to include("| #{'EXTERNAL'.ljust(14)} |")
    end
  end
end
