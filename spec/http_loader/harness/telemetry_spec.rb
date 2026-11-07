# typed: true
# frozen_string_literal: true

# Copyright (c) 2026 Vitalii Lazebnyi

require 'fileutils'
require 'http_loader/harness/telemetry'
require 'json'
require 'spec_helper'
require 'tmpdir'

RSpec.describe(HttpLoader::Harness::Telemetry) do
  let(:log_dir)     { Dir.mktmpdir                                             }
  let(:export_path) { File.join(log_dir, 'out.json')                           }
  let(:telemetry)   { HttpLoader::Harness::Telemetry.new(log_dir, export_path) }
  let(:client_log)  { File.join(log_dir, 'client.log')                         }
  # The exported JSON, read on first use (after the example has exported it).
  let(:payload) { JSON.parse(File.read(export_path), symbolize_names: true) }

  before { allow($stdout).to(receive(:puts)) }
  after { FileUtils.remove_entry(log_dir) }

  describe 'ErrorTally::METRICS' do
    it 'is frozen' do
      expect(HttpLoader::Harness::ErrorTally::METRICS.frozen?).to(be(true))
    end

    it 'maps each metric to its log token' do
      expect(HttpLoader::Harness::ErrorTally::METRICS.transform_values(&:token)).to(
        eq(emfile: 'ERROR_EMFILE', eaddr_count: 'ERROR_EADDRNOTAVAIL', thread_errors: 'ERROR_THREADLIMIT')
      )
    end
  end

  describe '#observe' do
    it 'keeps the peak connection count', :aggregate_failures do
      expect(telemetry.peak_connections).to(eq(0))
      [3, 7, 5].each { |count| telemetry.observe(count) }
      expect(telemetry.peak_connections).to(eq(7))
    end
  end

  describe '#elapsed and #restart' do
    # The temporary log directory is created first: Dir.mktmpdir reads the clock too.
    before { log_dir }

    it 'counts the seconds since the construction' do
      allow(Time).to(receive(:now).and_return(Time.at(10), Time.at(12.5)))
      expect(telemetry.elapsed).to(eq(2.5))
    end

    it 'counts the seconds since the restart' do
      allow(Time).to(receive(:now).and_return(Time.at(10), Time.at(20), Time.at(21)))
      telemetry.restart
      expect(telemetry.elapsed).to(eq(1.0))
    end
  end

  describe '#export' do
    it 'does not write anything when export_json is nil' do
      HttpLoader::Harness::Telemetry.new(log_dir, nil).export
      expect(File).not_to(exist(export_path))
    end

    it 'writes the exact payload, rounding the elapsed time to two decimals' do
      log_dir
      allow(Time).to(receive(:now).and_return(Time.at(100.0), Time.at(103.456)))
      telemetry.observe(7)
      telemetry.export
      expect(payload).to(
        eq(
          peak_connections: 7,
          test_duration_seconds: 3.46,
          errors: { emfile: 0, eaddrnotavail: 0, thread_limit: 0 }
        )
      )
    end

    it 'announces the export path on stdout' do
      telemetry.export
      expect($stdout).to(have_received(:puts).with("[Harness] Telemetry JSON securely sinked to #{export_path}."))
    end

    it 'folds error tokens from both client logs into the errors payload' do
      File.write(client_log, "ERROR_EMFILE\nERROR_EMFILE\nERROR_THREADLIMIT\n", mode: 'wb')
      File.write(File.join(log_dir, 'client.err'), "ERROR_EADDRNOTAVAIL\n")
      telemetry.export
      expect(payload.fetch(:errors)).to(eq(emfile: 2, eaddrnotavail: 1, thread_limit: 1))
    end
  end

  describe '#report_bottlenecks' do
    it 'reports all three OS limits in order, pipe-separated' do
      File.write(client_log, "ERROR_EMFILE\nERROR_EADDRNOTAVAIL\nERROR_THREADLIMIT\n", mode: 'wb')
      telemetry.report_bottlenecks
      expect($stdout).to(
        have_received(:puts).with(
          '   => BOTTLENECK ACTIVE: [OS FDs Limit: 1 EMFILE] | ' \
            '[OS Ports Limit: 1 EADDRNOTAVAIL] | [OS Thread Limit: 1 ThreadError]'
        )
      )
    end

    it 'reports only EMFILE (with its count) when it is the only positive metric' do
      File.write(client_log, "ERROR_EMFILE\nERROR_EMFILE\n", mode: 'wb')
      telemetry.report_bottlenecks
      expect($stdout).to(have_received(:puts).with('   => BOTTLENECK ACTIVE: [OS FDs Limit: 2 EMFILE]'))
    end

    it 'reports only EADDRNOTAVAIL when it is the only positive metric' do
      File.write(client_log, "ERROR_EADDRNOTAVAIL\n", mode: 'wb')
      telemetry.report_bottlenecks
      expect($stdout).to(have_received(:puts).with('   => BOTTLENECK ACTIVE: [OS Ports Limit: 1 EADDRNOTAVAIL]'))
    end

    it 'reports only the thread limit when it is the only positive metric' do
      File.write(client_log, "ERROR_THREADLIMIT\n", mode: 'wb')
      telemetry.report_bottlenecks
      expect($stdout).to(have_received(:puts).with('   => BOTTLENECK ACTIVE: [OS Thread Limit: 1 ThreadError]'))
    end

    it 'prints nothing when no error tokens are present' do
      File.write(client_log, "a quiet line\n", mode: 'wb')
      telemetry.report_bottlenecks
      expect($stdout).not_to(have_received(:puts))
    end

    it 'prints nothing when the log files do not exist' do
      telemetry.report_bottlenecks
      expect($stdout).not_to(have_received(:puts))
    end

    it 'swallows a read error without printing or raising', :aggregate_failures do
      allow(File).to(receive(:size).and_raise(StandardError))
      File.write(client_log, "ERROR_EMFILE\n", mode: 'wb')
      expect { telemetry.report_bottlenecks }
        .not_to(raise_error)
      expect($stdout).not_to(have_received(:puts))
    end
  end
end
