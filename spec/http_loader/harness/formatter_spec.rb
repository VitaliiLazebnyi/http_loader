# typed: true
# frozen_string_literal: true

# Copyright (c) 2026 Vitalii Lazebnyi

require 'http_loader/harness'
require 'spec_helper'

RSpec.describe(HttpLoader::Harness::Formatter) do
  include HarnessBackends

  let(:harness) { HttpLoader::Harness.new(ConfigFactory.harness(connections: 1)) }
  let(:lines)   { []                                                             }

  before { allow($stdout).to(receive(:puts) { |*args| lines.concat(args) }) }

  describe '#startup_target_msg' do
    it 'describes multiple targets with their count' do
      expect(HttpLoader::Harness.new(ConfigFactory.harness(target_urls: %w[http://a http://b])).startup_target_msg)
        .to(eq('**MULTIPLE TARGETS** (2 URLs).'))
    end

    it 'names the single external URL' do
      expect(HttpLoader::Harness.new(ConfigFactory.harness(target_urls: ['http://local'])).startup_target_msg)
        .to(eq('**EXTERNAL URL** http://local.'))
    end

    it 'reports HTTPS when no URL is given and https is enabled' do
      expect(HttpLoader::Harness.new(ConfigFactory.harness(use_https: true)).startup_target_msg).to(eq('**HTTPS**.'))
    end

    it 'reports HTTP when no URL is given and https is disabled' do
      expect(HttpLoader::Harness.new(ConfigFactory.harness(use_https: false)).startup_target_msg).to(eq('**HTTP**.'))
    end
  end

  describe '#print_startup_banner' do
    it 'prints the connection count and the target description verbatim' do
      harness.print_startup_banner
      expect(lines).to(eq(['[Harness] Starting test with 1 connections to **HTTP**.']))
    end
  end

  describe '#print_table_header' do
    it 'prints the banner, two full-width rules and the exact column header' do
      harness.print_table_header
      expect(lines).to(
        eq(
          [
            '[Harness] Monitoring resources (Press Ctrl+C to stop)...',
            '-' * 125,
            'Time (UTC) | Real Conns  | Srv CPU/Thrds    | Srv Mem        | Srv Mem/Conn   | ' \
              'Cli CPU/Thrds    | Cli Mem        | Cli Mem/Conn  ',
            '-' * 125
          ]
        )
      )
    end
  end

  describe '#format_kb_conn' do
    it 'returns EXTERNAL when the pid is nil' do
      expect(harness.format_kb_conn(10.0, 1, nil)).to(eq('EXTERNAL'))
    end

    it 'returns N/A when connections are zero' do
      expect(harness.format_kb_conn(10.0, 0, 123)).to(eq('N/A'))
    end

    it 'returns N/A when connections are negative' do
      expect(harness.format_kb_conn(10.0, -1, 123)).to(eq('N/A'))
    end

    it 'rounds the per-connection footprint to two decimals' do
      expect(harness.format_kb_conn(10.0, 3, 123)).to(eq('3.33 KB'))
    end
  end

  describe '#log_table_row' do
    it 'left-justifies every field to its column width, pipe-separated' do
      fields = {
        t: '12:34:56',
        ac: '10',
        sc: '50.0% / 8',
        sm: '100MB',
        sk: '128.0 KB',
        cc: '30.0% / 4',
        cm: '60MB',
        ck: '102.4 KB'
      }
      harness.log_table_row(fields)
      expect(lines).to(
        eq(
          [
            '12:34:56   | 10          | 50.0% / 8        | 100MB          | 128.0 KB       | 30.0% / 4        | ' \
              '60MB           | 102.4 KB      '
          ]
        )
      )
    end
  end

  describe '#extract_server_stats' do
    it 'returns server cpu, mem, threads and the formatted mem/conn' do
      stub_backends(harness)
      expect(harness.extract_server_stats).to(eq(['50.0', '100MB', 8, '128.0 KB']))
    end

    it 'labels the mem/conn EXTERNAL when the server pid is nil' do
      stub_backends(harness, server_pid: nil)
      expect(harness.extract_server_stats).to(eq(['50.0', '100MB', 8, 'EXTERNAL']))
    end
  end

  describe '#extract_client_stats' do
    it 'returns client active conns, cpu, threads and mem' do
      stub_backends(harness)
      expect(harness.extract_client_stats).to(eq([5, '30.0', 4, '60MB']))
    end
  end

  describe '#print_combined_stats' do
    # #utc yields a real UTC time (so strftime format mutations are caught), while the receiver's
    # own #strftime returns a sentinel, so dropping the `.utc` call visibly changes the printed row.
    let(:frozen_now) { instance_double(Time, utc: Time.utc(2021, 1, 1, 7, 34, 56), strftime: 'LOCAL-NOT-UTC') }

    before { allow(Time).to(receive(:now).and_return(frozen_now)) }

    it 'prints a fully formatted row combining server and client metrics in UTC' do
      stub_backends(harness)
      harness.print_combined_stats(10, '30.0', 4, '60MB')
      expect(lines).to(
        eq(
          [
            '07:34:56   | 10          | 50.0% / 8        | 100MB          | 128.0 KB       | 30.0% / 4        | ' \
              '60MB           | 102.4 KB      '
          ]
        )
      )
    end

    it 'labels the client mem/conn EXTERNAL when the client pid is nil' do
      stub_backends(harness, client_pid: nil)
      harness.print_combined_stats(10, '30.0', 4, '60MB')
      expect(lines.first).to(end_with("| #{'EXTERNAL'.ljust(14)}"))
    end

    it 'labels the server mem/conn EXTERNAL when the server pid is nil' do
      stub_backends(harness, server_pid: nil)
      harness.print_combined_stats(10, '30.0', 4, '60MB')
      expect(lines.first.include?("| #{'EXTERNAL'.ljust(14)} |")).to(be(true))
    end
  end
end
