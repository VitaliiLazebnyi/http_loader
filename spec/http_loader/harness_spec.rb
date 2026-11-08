# typed: true
# frozen_string_literal: true

# Copyright (c) 2026 Vitalii Lazebnyi

require 'spec_helper'

RSpec.describe(HttpLoader::Harness) do
  let(:config) do
    HttpLoader::Harness::Config.new(
      connections: 1, target_duration: 1.0, target_urls: ['http://localhost'], export_json: 'logs/telemetry.json'
    )
  end
  let(:harness)   { HttpLoader::Harness.new(config)            }
  let(:pm)        { harness.instance_variable_get(:@pm)        }
  let(:telemetry) { harness.instance_variable_get(:@telemetry) }

  before do
    allow($stdout).to(receive(:puts))
    allow($stdout).to(receive(:print))
    allow(pm).to(receive(:spawn_processes))
    allow(pm).to(receive(:cleanup))
    allow(pm).to(receive(:missing_process?).and_return(false))
    allow(telemetry).to(receive(:export))
    allow(telemetry).to(receive(:report_bottlenecks))
  end

  describe '#initialize' do
    it 'validates the config, rejecting an invalid one' do
      bad = HttpLoader::Harness::Config.new(connections: 0, target_urls: [], export_json: nil)
      expect { HttpLoader::Harness.new(bad) }
        .to(raise_error(ArgumentError))
    end

    it 'retains the config' do
      expect(harness.config).to(eq(config))
    end

    context 'when wiring its collaborators' do
      before do
        allow(HttpLoader::Harness::Telemetry).to(receive(:new).and_call_original)
        allow(HttpLoader::Harness::ProcessManager).to(receive(:new).and_call_original)
        HttpLoader::Harness.new(config)
      end

      it 'gives telemetry the repository logs dir and the export path' do
        # spec/http_loader -> repo root, then /logs
        expect(HttpLoader::Harness::Telemetry)
          .to(have_received(:new).with(File.expand_path('../../logs', __dir__), 'logs/telemetry.json'))
      end

      it('builds a process manager from the config') do
        expect(HttpLoader::Harness::ProcessManager).to(have_received(:new).with(config))
      end
    end

    it 'builds a resource monitor' do
      expect(harness.monitor.is_a?(HttpLoader::Harness::ResourceMonitor)).to(be(true))
    end
  end

  describe '#start' do
    before do
      allow(harness).to(receive(:print_startup_banner))
      allow(HttpLoader::FileLimits).to(receive(:bump!))
      allow(harness).to(receive(:run_lifecycle))
    end

    context 'when started' do
      before do
        allow($stdout).to(receive(:sync=))
        harness.start
      end

      it('enables synchronous stdout') { expect($stdout).to(have_received(:sync=).with(true)) }
      it('prints the banner') { expect(harness).to(have_received(:print_startup_banner)) }
      it('runs the lifecycle') { expect(harness).to(have_received(:run_lifecycle)) }

      it 'raises the open file limit toward the connection count plus headroom' do
        expect(HttpLoader::FileLimits).to(have_received(:bump!).with(1025, label: '[Harness]'))
      end
    end
  end

  describe '#run_lifecycle' do
    before do
      allow(harness).to(receive(:trap).with('INT'))
      allow(harness).to(receive(:monitor_resources))
      # Neutralise Kernel#exit so a mutation that runs the INT handler inline cannot tear down the
      # test runner with exit(0) (which would look like a passing run).
      allow(harness).to(receive(:exit))
    end

    it 'spawns the processes and then monitors resources' do
      calls = []
      allow(pm).to(receive(:spawn_processes) { calls << :spawn })
      allow(harness).to(receive(:monitor_resources) { calls << :monitor })
      harness.__send__(:run_lifecycle)
      expect(calls).to(eq(%i[spawn monitor]))
    end

    context 'when monitoring raises' do
      before do
        allow(harness).to(receive(:monitor_resources).and_raise(StandardError))
        harness.__send__(:run_lifecycle)
      rescue StandardError
        nil
      end

      it 're-raises the error' do
        expect { harness.__send__(:run_lifecycle) }
          .to(raise_error(StandardError))
      end

      it 'still exports telemetry' do
        expect(telemetry).to(have_received(:export))
      end

      it('still cleans up') { expect(pm).to(have_received(:cleanup)) }
    end

    context 'with the INT handler' do
      let(:handler) do
        captured = T.let(nil, T.nilable(Proc))
        allow(harness).to(receive(:trap).with('INT') { |&block| captured = block })
        # The ensure block cleans up once; the handler is registered, not run inline.
        harness.__send__(:run_lifecycle)
        T.must(captured)
      end

      it 'reports the interrupt' do
        expect { handler.call }
          .to(output(/\n\[Harness\] Caught interrupt, cleaning up processes\.\.\./).to_stdout)
      end

      it 'cleans up again and exits 0', :aggregate_failures do
        expect { handler.call }
          .to(output.to_stdout)
        expect(pm).to(have_received(:cleanup).twice)
        expect(harness).to(have_received(:exit).with(0))
      end
    end
  end

  describe '#monitor_resources' do
    before do
      allow(harness).to(receive(:print_table_header))
      allow(harness).to(receive(:sleep))
      allow(telemetry).to(receive(:restart))
    end

    it 'prints the header and restarts the clock of the run', :aggregate_failures do
      allow(harness).to(receive(:duration_exceeded?).and_return(true))
      harness.__send__(:monitor_resources)
      expect(harness).to(have_received(:print_table_header).ordered)
      expect(telemetry).to(have_received(:restart).ordered)
    end

    it 'reports bottlenecks and sleeps 2s each tick until the duration is exceeded', :aggregate_failures do
      allow(harness).to(receive(:duration_exceeded?).and_return(false, true))
      allow(harness).to(receive(:tick_failed?).and_return(false))
      harness.__send__(:monitor_resources)
      expect(telemetry).to(have_received(:report_bottlenecks).once)
      expect(harness).to(have_received(:sleep).with(2).once)
    end

    it 'breaks immediately (no bottleneck report or sleep) when a tick fails', :aggregate_failures do
      allow(harness).to(receive_messages(duration_exceeded?: false, tick_failed?: true))
      harness.__send__(:monitor_resources)
      expect(harness).to(have_received(:tick_failed?).once)
      expect(telemetry).not_to(have_received(:report_bottlenecks))
      expect(harness).not_to(have_received(:sleep))
    end
  end

  describe '#duration_exceeded?' do
    it 'is false for a negative target duration' do
      harness.instance_variable_get(:@config).instance_variable_set(:@target_duration, -1.0)
      allow(telemetry).to(receive(:elapsed).and_return(10.0))
      expect(harness.__send__(:duration_exceeded?)).to(be(false))
    end

    it 'is false when no target duration is configured (target not > 0)' do
      harness.instance_variable_get(:@config).instance_variable_set(:@target_duration, 0.0)
      allow(telemetry).to(receive(:elapsed).and_return(10.0))
      expect(harness.__send__(:duration_exceeded?)).to(be(false))
    end

    it 'is false while the elapsed time is below the target' do
      allow(telemetry).to(receive(:elapsed).and_return(0.9))
      expect(harness.__send__(:duration_exceeded?)).to(be(false))
    end

    it 'announces auto-shutdown and is true once elapsed passes the target', :aggregate_failures do
      allow(telemetry).to(receive(:elapsed).and_return(10.0))
      expect { expect(harness.__send__(:duration_exceeded?)).to(be(true)) }
        .to(output(/Target duration mathematically reached \(1\.0s\)\. auto-shutdown\./).to_stdout)
    end

    it 'fires at exactly the target (>=, not >)', :aggregate_failures do
      allow(telemetry).to(receive(:elapsed).and_return(1.0))
      expect { expect(harness.__send__(:duration_exceeded?)).to(be(true)) }
        .to(output(/auto-shutdown/).to_stdout)
    end
  end

  describe '#tick_failed?' do
    let(:stats) { StatsFactory.stats }

    before { allow(harness).to(receive(:print_combined_stats)) }

    it 'records the active connections as an observation of the run' do
      allow(telemetry).to(receive(:observe))
      allow(harness).to(receive_messages(extract_client_stats: [5, stats], missing_socket?: false))
      harness.__send__(:tick_failed?)
      expect(telemetry).to(have_received(:observe).with(5))
    end

    it 'fails when the socket disappears, passing the client sample to missing_socket?', :aggregate_failures do
      allow(harness).to(receive(:extract_client_stats).and_return([0, stats]))
      allow(harness).to(receive(:missing_socket?).with(0, stats).and_return(true))
      expect(harness.__send__(:tick_failed?)).to(be(true))
      expect(harness).not_to(have_received(:print_combined_stats))
    end

    it 'fails when a child process is missing', :aggregate_failures do
      allow(harness).to(receive_messages(extract_client_stats: [1, stats], missing_socket?: false))
      allow(pm).to(receive(:missing_process?).and_return(true))
      expect(harness.__send__(:tick_failed?)).to(be(true))
      expect(harness).not_to(have_received(:print_combined_stats))
    end

    it 'otherwise prints the combined stats and does not fail', :aggregate_failures do
      allow(harness).to(receive_messages(extract_client_stats: [1, stats], missing_socket?: false))
      expect(harness.__send__(:tick_failed?)).to(be(false))
      expect(harness).to(have_received(:print_combined_stats).with(1, stats))
    end
  end

  describe '#missing_socket?' do
    it 'logs a full UTC-stamped disconnect row and warns when a target peaked then dropped to zero',
      :aggregate_failures do
      allow(harness).to(receive(:log_table_row))
      # 17:34:56 UTC
      allow(Time).to(receive(:now).and_return(Time.new(2020, 1, 2, 12, 34, 56, '-05:00')))
      # exactly at the > 0 boundary
      telemetry.observe(1)
      client = StatsFactory.stats(cpu: '7.5', memory: '2 MB', threads: 3)
      expect { expect(harness.__send__(:missing_socket?, 0, client)).to(be(true)) }
        .to(output("\n[Harness] ⚠️ EXTERNAL SERVER DISCONNECTED!\n").to_stdout)
      expect(harness).to(
        have_received(:log_table_row).with(['17:34:56', 0, 'EXTERNAL', 'N/A', 'N/A', '7.5% / 3T', '2 MB', 'N/A'])
      )
    end

    it 'is false while connections are still active' do
      telemetry.observe(100)
      expect(harness.__send__(:missing_socket?, 1, StatsFactory.stats)).to(be(false))
    end

    it 'is false before any connection has ever been established (peak still zero)' do
      expect(harness.__send__(:missing_socket?, 0, StatsFactory.stats)).to(be(false))
    end

    it 'is false when no external target is configured' do
      cfg = HttpLoader::Harness::Config.new(connections: 1, target_urls: [], export_json: nil)
      local = HttpLoader::Harness.new(cfg)
      local.instance_variable_get(:@telemetry).observe(100)
      expect(local.__send__(:missing_socket?, 0, StatsFactory.stats)).to(be(false))
    end
  end
end
