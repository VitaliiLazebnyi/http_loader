# typed: false
# frozen_string_literal: true

require 'spec_helper'
require 'tmpdir'
require 'fileutils'
require 'json'
require 'http_loader/harness/telemetry'

RSpec.describe HttpLoader::Harness::Telemetry do
  let(:log_dir) { Dir.mktmpdir }
  let(:export_path) { File.join(log_dir, 'out.json') }
  let(:telemetry) { described_class.new(log_dir, export_path) }

  before { allow($stdout).to receive(:puts) }
  after { FileUtils.remove_entry(log_dir) }

  # Writes (replacing) a client log file; `append` keeps the existing bytes.
  def write_log(content, basename: 'client.log', append: false)
    File.write(File.join(log_dir, basename), content, mode: append ? 'ab' : 'wb')
  end

  def payload
    JSON.parse(File.read(export_path), symbolize_names: true)
  end

  describe 'ERROR_TOKENS' do
    it 'is frozen' do
      expect(described_class::ERROR_TOKENS).to be_frozen
    end

    it 'maps each metric to its log token' do
      expect(described_class::ERROR_TOKENS).to eq(
        emfile: 'ERROR_EMFILE', eaddr_count: 'ERROR_EADDRNOTAVAIL', thread_errors: 'ERROR_THREADLIMIT'
      )
    end
  end

  describe '#export!' do
    it 'does not write anything when export_json is nil' do
      described_class.new(log_dir, nil).export!(100, Time.now)
      expect(File).not_to exist(export_path)
    end

    it 'writes the exact payload, rounding the elapsed time to two decimals' do
      now = Time.utc(2021, 1, 2, 3, 4, 5)
      allow(Time).to receive(:now).and_return(now)
      telemetry.export!(7, now - 3.456)
      expect(payload).to eq(
        peak_connections: 7, test_duration_seconds: 3.46,
        errors: { emfile: 0, eaddrnotavail: 0, thread_limit: 0 }
      )
    end

    it 'announces the export path on stdout' do
      telemetry.export!(1, Time.now)
      expect($stdout).to have_received(:puts).with("[Harness] Telemetry JSON securely sinked to #{export_path}.")
    end

    it 'folds error tokens from both client logs into the errors payload' do
      write_log("ERROR_EMFILE\nERROR_EMFILE\nERROR_THREADLIMIT\n")
      write_log("ERROR_EADDRNOTAVAIL\n", basename: 'client.err')
      telemetry.export!(0, Time.now)
      expect(payload[:errors]).to eq(emfile: 2, eaddrnotavail: 1, thread_limit: 1)
    end

    it 'ignores a trailing partial line until it is completed' do
      write_log("ERROR_EMFILE\nERROR_EMFILE_without_newline")
      telemetry.export!(0, Time.now)
      expect(payload[:errors][:emfile]).to eq(1)
    end

    it 'does not count a token on a line that has no newline yet' do
      write_log('ERROR_EMFILE never terminated')
      telemetry.export!(0, Time.now)
      expect(payload[:errors][:emfile]).to eq(0)
    end

    it 'counts a long pending line exactly once, only after its newline arrives' do
      # The first chunk is longer than any offset a mutation might wrongly carry forward, and has
      # no newline, so a correct reader consumes zero bytes and re-reads it whole once completed.
      write_log("ERROR_EMFILE #{'x' * 200}")
      telemetry.check_bottlenecks!
      write_log("\n", append: true)
      telemetry.export!(0, Time.now)
      expect(payload[:errors][:emfile]).to eq(1)
    end

    it 'reads log bytes in binary mode, tolerating non-UTF-8 content' do
      write_log("\xFFERROR_EMFILE\n")
      telemetry.export!(0, Time.now)
      expect(payload[:errors][:emfile]).to eq(1)
    end
  end

  describe '#check_bottlenecks!' do
    it 'reports all three OS limits in order, pipe-separated' do
      write_log("ERROR_EMFILE\nERROR_EADDRNOTAVAIL\nERROR_THREADLIMIT\n")
      telemetry.check_bottlenecks!
      expect($stdout).to have_received(:puts).with(
        '   => BOTTLENECK ACTIVE: [OS FDs Limit: 1 EMFILE] | ' \
        '[OS Ports Limit: 1 EADDRNOTAVAIL] | [OS Thread Limit: 1 ThreadError]'
      )
    end

    it 'reports only EMFILE (with its count) when it is the only positive metric' do
      write_log("ERROR_EMFILE\nERROR_EMFILE\n")
      telemetry.check_bottlenecks!
      expect($stdout).to have_received(:puts).with('   => BOTTLENECK ACTIVE: [OS FDs Limit: 2 EMFILE]')
    end

    it 'reports only EADDRNOTAVAIL when it is the only positive metric' do
      write_log("ERROR_EADDRNOTAVAIL\n")
      telemetry.check_bottlenecks!
      expect($stdout).to have_received(:puts).with('   => BOTTLENECK ACTIVE: [OS Ports Limit: 1 EADDRNOTAVAIL]')
    end

    it 'reports only the thread limit when it is the only positive metric' do
      write_log("ERROR_THREADLIMIT\n")
      telemetry.check_bottlenecks!
      expect($stdout).to have_received(:puts).with('   => BOTTLENECK ACTIVE: [OS Thread Limit: 1 ThreadError]')
    end

    it 'prints nothing when no error tokens are present' do
      write_log("a quiet line\n")
      telemetry.check_bottlenecks!
      expect($stdout).not_to have_received(:puts)
    end

    it 'prints nothing when the log files do not exist' do
      telemetry.check_bottlenecks!
      expect($stdout).not_to have_received(:puts)
    end

    it 'swallows a read error without printing or raising' do
      allow(File).to receive(:size).and_raise(StandardError)
      write_log("ERROR_EMFILE\n")
      expect { telemetry.check_bottlenecks! }.not_to raise_error
      expect($stdout).not_to have_received(:puts)
    end

    it 'counts only the newly-appended tail on each tick, never re-reading old bytes' do
      write_log("ERROR_EMFILE first chunk padded out\n")
      telemetry.check_bottlenecks!
      write_log("ERROR_EADDRNOTAVAIL\n", append: true)
      telemetry.check_bottlenecks!
      telemetry.export!(0, Time.now)
      expect(payload[:errors]).to eq(emfile: 1, eaddrnotavail: 1, thread_limit: 0)
    end

    it 'resets its offset and re-reads from the start when a log is truncated/rotated' do
      write_log("ERROR_EMFILE this first generation line is deliberately long\n")
      telemetry.check_bottlenecks!
      write_log("ERROR_THREADLIMIT\n") # shorter than the stored offset => rotation
      telemetry.check_bottlenecks!
      telemetry.export!(0, Time.now)
      expect(payload[:errors]).to eq(emfile: 1, eaddrnotavail: 0, thread_limit: 1)
    end
  end
end
