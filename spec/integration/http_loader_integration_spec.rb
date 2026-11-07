# typed: true
# frozen_string_literal: true

# Copyright (c) 2026 Vitalii Lazebnyi

require 'fileutils'
require 'json'
require 'spec_helper'

RSpec.describe(HttpLoader, type: :integration) do
  let(:telemetry_file) { File.join(IntegrationRun::LOG_DIR, 'telemetry.json') }

  before do
    FileUtils.mkdir_p(IntegrationRun::LOG_DIR)
    FileUtils.rm_f(%w[client.log server.log telemetry.json].map { |name| File.join(IntegrationRun::LOG_DIR, name) })
  end

  after do
    system('pkill', '-9', '-f', 'http_loader server')
    system('pkill', '-9', '-f', 'http_loader client')
  end

  describe 'Mode 1: Fundamental HTTP Plaintext Mode' do
    it 'spawns HTTP Server and Client natively mapping successfully', :aggregate_failures do
      out, _err, status = IntegrationRun.run(%w[harness --connections_count=2 --target_duration=3.0 --verbose])
      expect(status.exitstatus).to(eq(0))
      expect(out.include?('Starting test with 2 connections to **HTTP**')).to(be(true))
      expect(IntegrationRun.client_log(await: 'Starting 2 HTTP connections').include?('Starting 2 HTTP')).to(be(true))
    end
  end

  describe 'Mode 2: Encrypted HTTPS TLS Architecture' do
    it 'bootstraps secure contexts actively avoiding TLS handshaking drops seamlessly', :aggregate_failures do
      out, _err, status = IntegrationRun.run(
        %w[
          harness
          --connections_count=2
          --target_duration=6.0
          --reopen_closed_connections
          --reopen_interval=0.5
          --https
          --verbose
        ]
      )
      expect(status.exitstatus).to(eq(0))
      expect(out).to(match(/to \*\*HTTPS\*\*.*Target duration mathematically reached/m))
      expect(IntegrationRun.client_log(await: 'Starting 2 HTTPS connections').include?('Starting 2 HTTPS')).to(be(true))
    end
  end

  describe 'Mode 3: QPS Payload Active Simulation' do
    it 'maps rhythmic GET payloads cleanly across active tunnels', :aggregate_failures do
      args = %w[harness --connections_count=2 --target_duration=3.0 --qps_per_connection=5 --no-ping --verbose]
      _out, _err, status = IntegrationRun.run(args)
      expect(status.exitstatus).to(eq(0))
      expect(IntegrationRun.client_log(await: 'Starting 2 HTTP connections').include?('Starting 2 HTTP')).to(be(true))
    end
  end

  describe 'Mode 4: Resilience Slowloris Thread Simulator' do
    it 'allocates and drops byte gap writes elegantly securely', :aggregate_failures do
      args = %w[harness --connections_count=2 --target_duration=3.0 --slowloris_delay=0.1 --verbose]
      _out, _err, status = IntegrationRun.run(args)
      expect(status.exitstatus).to(eq(0))
      expect(IntegrationRun.client_log(await: 'Starting 2 HTTP connections').include?('Starting 2 HTTP')).to(be(true))
    end
  end

  describe 'Mode 5: External Target Mapping Logs' do
    before { IntegrationRun.start_server }

    it 'targets an external URL and exports JSON telemetry (against a local server, no network)', :aggregate_failures do
      out, _err, status = IntegrationRun.run(
        %w[
          harness
          --connections_count=2
          --target_duration=2.0
          --url=http://localhost:8080
          --export_json=logs/telemetry.json
          --verbose
        ]
      )
      expect([status.exitstatus, out.include?('**EXTERNAL URL**')]).to(eq([0, true]))
      expect(JSON.parse(File.read(telemetry_file)).keys).to(
        contain_exactly(
          'peak_connections',
          'test_duration_seconds',
          'errors'
        )
      )
    end
  end

  describe 'CLI validation (REQ-CLI-023)' do
    it 'fast-fails with a Configuration Error on connections_count=0 instead of deadlocking', :aggregate_failures do
      _out, err, status = IntegrationRun.run(%w[client --connections_count=0])
      expect(status.exitstatus).to(eq(1))
      expect(err.include?('Configuration Error')).to(be(true))
    end

    it 'fast-fails on a non-numeric flag value', :aggregate_failures do
      _out, err, status = IntegrationRun.run(%w[client --connections_count=abc])
      expect(status.exitstatus).to(eq(1))
      expect(err.include?('Configuration Error')).to(be(true))
    end

    it 'fast-fails on a malformed target URL', :aggregate_failures do
      _out, err, status = IntegrationRun.run(['client', '--connections_count=1', '--url=http://bad host/'])
      expect(status.exitstatus).to(eq(1))
      expect(err.include?('Configuration Error')).to(be(true))
    end
  end
end
