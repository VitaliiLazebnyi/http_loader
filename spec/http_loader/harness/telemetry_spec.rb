# typed: false
# frozen_string_literal: true

require 'spec_helper'
require 'stringio'
require 'http_loader/harness/telemetry'

RSpec.describe HttpLoader::Harness::Telemetry do
  let(:telemetry) { described_class.new('/logs', 'test.json') }

  before do
    allow($stdout).to receive(:puts)
    allow(File).to receive(:write)
    # Default: both log files exist but are empty.
    allow(File).to receive_messages(exist?: true, size: 0)
  end

  # Makes `client.log` (or the given basename) yield `content` through the tail reader.
  def stub_log(content, basename: 'client.log')
    path = "/logs/#{basename}"
    allow(File).to receive(:size).with(path).and_return(content.bytesize)
    allow(File).to receive(:open).with(path, 'rb').and_yield(StringIO.new(content))
  end

  describe '#export!' do
    it 'writes the telemetry JSON with an errors payload' do
      telemetry.export!(100, Time.now.utc)
      expect(File).to have_received(:write).with('test.json', /"peak_connections":100/)
    end

    it 'returns early when export_json is nil' do
      described_class.new('/logs', nil).export!(100, Time.now.utc)
      expect(File).not_to have_received(:write)
    end

    it 'accumulates error tokens from the client logs into the payload' do
      stub_log("[t] ERROR_EMFILE: boom\n[t] ERROR_THREADLIMIT: x\n")
      telemetry.export!(5, Time.now.utc)
      expect(File).to have_received(:write).with('test.json', /"emfile":1.*"thread_limit":1/)
    end
  end

  describe '#check_bottlenecks!' do
    it 'reports an active bottleneck for EMFILE and THREADLIMIT' do
      stub_log("[t] ERROR_EMFILE: a\n[t] ERROR_THREADLIMIT: b\n")
      telemetry.check_bottlenecks!
      expect($stdout).to have_received(:puts).with(/BOTTLENECK ACTIVE.*EMFILE.*ThreadError/)
    end

    it 'reports EADDRNOTAVAIL' do
      stub_log("[t] ERROR_EADDRNOTAVAIL: ports\n", basename: 'client.err')
      telemetry.check_bottlenecks!
      expect($stdout).to have_received(:puts).with(/EADDRNOTAVAIL/)
    end

    it 'prints nothing when there are no errors' do
      telemetry.check_bottlenecks!
      expect($stdout).not_to have_received(:puts)
    end

    it 'skips a log file that does not exist yet' do
      allow(File).to receive(:exist?).and_return(false)
      telemetry.check_bottlenecks!
      expect($stdout).not_to have_received(:puts)
    end

    it 'only counts complete lines, deferring a partial trailing line to the next tick' do
      # No trailing newline: the token must NOT be counted yet.
      stub_log('[t] ERROR_EMFILE: partial')
      telemetry.check_bottlenecks!
      expect($stdout).not_to have_received(:puts)
    end

    it 'resets the offset and re-reads when a log is truncated' do
      stub_log("[t] ERROR_EMFILE: one\n")
      telemetry.check_bottlenecks!
      # Simulate truncation: size shrinks below the stored offset.
      stub_log("[t] ERROR_EMFILE: fresh\n")
      allow(File).to receive(:size).with('/logs/client.log').and_return(5, "[t] ERROR_EMFILE: fresh\n".bytesize)
      telemetry.check_bottlenecks!
      expect($stdout).to have_received(:puts).with(/EMFILE/).at_least(:once)
    end

    it 'rescues a read error silently' do
      allow(File).to receive(:size).and_raise(StandardError)
      telemetry.check_bottlenecks!
      expect($stdout).not_to have_received(:puts)
    end
  end
end
