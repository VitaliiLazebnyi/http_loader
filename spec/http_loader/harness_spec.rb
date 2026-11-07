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
    allow(telemetry).to(receive(:export!))
    allow(telemetry).to(receive(:check_bottlenecks!))
  end

  describe '#initialize' do
    it 'validates the config, rejecting an invalid one' do
      bad = HttpLoader::Harness::Config.new(connections: 0, target_urls: [], export_json: nil)
      expect { HttpLoader::Harness.new(bad) }
        .to(raise_error(ArgumentError))
    end

    it 'retains the config and starts peak connections at zero', :aggregate_failures do
      expect(harness.config).to(eq(config))
      expect(harness.instance_variable_get(:@peak_connections)).to(eq(0))
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

    it 'stamps a UTC start time' do
      expect(harness.instance_variable_get(:@start_time)).to(be_within(5).of(Time.now.utc))
    end
  end

  describe '#start' do
    before do
      allow(harness).to(receive(:print_startup_banner))
      allow(harness).to(receive(:bump_file_limits))
      allow(harness).to(receive(:run_lifecycle))
    end

    context 'when started' do
      before do
        allow($stdout).to(receive(:sync=))
        harness.start
      end

      it('enables synchronous stdout') { expect($stdout).to(have_received(:sync=).with(true)) }
      it('prints the banner') { expect(harness).to(have_received(:print_startup_banner)) }
      it('bumps the file limits') { expect(harness).to(have_received(:bump_file_limits)) }
      it('runs the lifecycle') { expect(harness).to(have_received(:run_lifecycle)) }
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
        harness.instance_variable_set(:@peak_connections, 7)
        harness.__send__(:run_lifecycle)
      rescue StandardError
        nil
      end

      it 're-raises the error' do
        expect { harness.__send__(:run_lifecycle) }
          .to(raise_error(StandardError))
      end

      it 'still exports telemetry with the peak connections and the start time' do
        expect(telemetry).to(have_received(:export!).with(7, harness.instance_variable_get(:@start_time)))
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
    end

    it 'prints the header and resets the start time to now', :aggregate_failures do
      allow(harness).to(receive(:duration_exceeded?).and_return(true))
      # a stale start time to be reset
      harness.instance_variable_set(:@start_time, Time.now - 10_000)
      harness.__send__(:monitor_resources)
      expect(harness).to(have_received(:print_table_header))
      expect(harness.instance_variable_get(:@start_time)).to(be_within(5).of(Time.now))
    end

    it 'checks bottlenecks and sleeps 2s each tick until the duration is exceeded', :aggregate_failures do
      allow(harness).to(receive(:duration_exceeded?).and_return(false, true))
      allow(harness).to(receive(:tick_failed?).and_return(false))
      harness.__send__(:monitor_resources)
      expect(telemetry).to(have_received(:check_bottlenecks!).once)
      expect(harness).to(have_received(:sleep).with(2).once)
    end

    it 'breaks immediately (no bottleneck check or sleep) when a tick fails', :aggregate_failures do
      allow(harness).to(receive_messages(duration_exceeded?: false, tick_failed?: true))
      harness.__send__(:monitor_resources)
      expect(harness).to(have_received(:tick_failed?).once)
      expect(telemetry).not_to(have_received(:check_bottlenecks!))
      expect(harness).not_to(have_received(:sleep))
    end
  end

  describe '#duration_exceeded?' do
    it 'is false for a negative target duration' do
      harness.instance_variable_get(:@config).instance_variable_set(:@target_duration, -1.0)
      harness.instance_variable_set(:@start_time, Time.now.utc - 10)
      expect(harness.__send__(:duration_exceeded?)).to(be(false))
    end

    it 'is false when no target duration is configured (target not > 0)' do
      harness.instance_variable_get(:@config).instance_variable_set(:@target_duration, 0.0)
      harness.instance_variable_set(:@start_time, Time.now.utc - 10)
      expect(harness.__send__(:duration_exceeded?)).to(be(false))
    end

    it 'is false while the elapsed time is below the target' do
      harness.instance_variable_set(:@start_time, Time.now.utc)
      expect(harness.__send__(:duration_exceeded?)).to(be(false))
    end

    it 'announces auto-shutdown and is true once elapsed reaches the target', :aggregate_failures do
      harness.instance_variable_set(:@start_time, Time.now - 10)
      expect { expect(harness.__send__(:duration_exceeded?)).to(be(true)) }
        .to(output(/Target duration mathematically reached \(1\.0s\)\. auto-shutdown\./).to_stdout)
    end

    it 'fires at exactly the target (>=, not >)', :aggregate_failures do
      t0 = Time.now
      harness.instance_variable_set(:@start_time, t0)
      # elapsed == target (1.0)
      allow(Time).to(receive(:now).and_return(t0 + 1.0))
      expect { expect(harness.__send__(:duration_exceeded?)).to(be(true)) }
        .to(output(/auto-shutdown/).to_stdout)
    end
  end

  describe '#tick_failed?' do
    before { allow(harness).to(receive(:print_combined_stats)) }

    it 'records the running peak of active connections' do
      allow(harness).to(receive_messages(extract_client_stats: [5, '0.0', 1, '1 MB'], missing_socket?: false))
      harness.instance_variable_set(:@peak_connections, 3)
      harness.__send__(:tick_failed?)
      expect(harness.instance_variable_get(:@peak_connections)).to(eq(5))
    end

    it 'keeps the previous peak when the current active count is lower' do
      allow(harness).to(receive_messages(extract_client_stats: [2, '0.0', 1, '1 MB'], missing_socket?: false))
      harness.instance_variable_set(:@peak_connections, 9)
      harness.__send__(:tick_failed?)
      expect(harness.instance_variable_get(:@peak_connections)).to(eq(9))
    end

    it 'fails when the socket disappears, passing the client stats to missing_socket?', :aggregate_failures do
      allow(harness).to(receive(:extract_client_stats).and_return([0, '1.5', 4, '2 MB']))
      allow(harness).to(receive(:missing_socket?).with(0, '1.5', 4, '2 MB').and_return(true))
      expect(harness.__send__(:tick_failed?)).to(be(true))
      expect(harness).not_to(have_received(:print_combined_stats))
    end

    it 'fails when a child process is missing', :aggregate_failures do
      allow(harness).to(receive_messages(extract_client_stats: [1, '0.0', 1, '1 MB'], missing_socket?: false))
      allow(pm).to(receive(:missing_process?).and_return(true))
      expect(harness.__send__(:tick_failed?)).to(be(true))
      expect(harness).not_to(have_received(:print_combined_stats))
    end

    it 'otherwise prints the combined stats and does not fail', :aggregate_failures do
      allow(harness).to(receive_messages(extract_client_stats: [1, '0.0', 2, '1 MB'], missing_socket?: false))
      expect(harness.__send__(:tick_failed?)).to(be(false))
      expect(harness).to(have_received(:print_combined_stats).with(1, '0.0', 2, '1 MB'))
    end
  end

  describe '#bump_file_limits' do
    it 'raises only the soft limit toward connections+1024, preserving the hard ceiling' do
      allow(Process).to(receive(:getrlimit).with(Process::RLIMIT_NOFILE).and_return([256, 4096]))
      allow(Process).to(receive(:setrlimit))
      harness.__send__(:bump_file_limits)
      expect(Process).to(have_received(:setrlimit).with(Process::RLIMIT_NOFILE, 1025, 4096))
    end

    it 'clamps the requested soft limit to the existing hard ceiling (never raising it)' do
      allow(Process).to(receive(:getrlimit).with(Process::RLIMIT_NOFILE).and_return([256, 512]))
      allow(Process).to(receive(:setrlimit))
      harness.__send__(:bump_file_limits)
      # desired 1025 exceeds the hard limit 512, so the soft limit is clamped to 512; hard stays 512.
      expect(Process).to(have_received(:setrlimit).with(Process::RLIMIT_NOFILE, 512, 512))
    end

    it 'warns (without raising) when the OS rejects the change' do
      allow(Process).to(receive(:getrlimit).and_return([256, 4096]))
      allow(Process).to(receive(:setrlimit).and_raise(Errno::EPERM))
      expect { harness.__send__(:bump_file_limits) }
        .to(output(/\[Harness\].*Could not set RLIMIT_NOFILE/).to_stderr)
    end
  end

  describe '#missing_socket?' do
    it 'logs a full UTC-stamped disconnect row and warns when a target peaked then dropped to zero',
      :aggregate_failures do
      allow(harness).to(receive(:log_table_row))
      # 17:34:56 UTC
      allow(Time).to(receive(:now).and_return(Time.new(2020, 1, 2, 12, 34, 56, '-05:00')))
      # exactly at the > 0 boundary
      harness.instance_variable_set(:@peak_connections, 1)
      expect { expect(harness.__send__(:missing_socket?, 0, '7.5', 3, '2 MB')).to(be(true)) }
        .to(output("\n[Harness] ⚠️ EXTERNAL SERVER DISCONNECTED!\n").to_stdout)
      expect(harness).to(
        have_received(:log_table_row).with(
          t: '17:34:56', ac: 0, sc: 'EXTERNAL', sm: 'N/A', sk: 'N/A', cc: '7.5% / 3T', cm: '2 MB', ck: 'N/A'
        )
      )
    end

    it 'is false while connections are still active' do
      harness.instance_variable_set(:@peak_connections, 100)
      expect(harness.__send__(:missing_socket?, 1, '0', 1, 'M')).to(be(false))
    end

    it 'is false before any connection has ever been established (peak still zero)' do
      harness.instance_variable_set(:@peak_connections, 0)
      expect(harness.__send__(:missing_socket?, 0, '0', 1, 'M')).to(be(false))
    end

    it 'is false when no external target is configured' do
      cfg = HttpLoader::Harness::Config.new(connections: 1, target_urls: [], export_json: nil)
      local = HttpLoader::Harness.new(cfg)
      local.instance_variable_set(:@peak_connections, 100)
      expect(local.__send__(:missing_socket?, 0, '0', 1, 'M')).to(be(false))
    end
  end
end
