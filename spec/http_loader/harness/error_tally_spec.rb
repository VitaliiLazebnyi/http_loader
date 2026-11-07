# typed: true
# frozen_string_literal: true

# Copyright (c) 2026 Vitalii Lazebnyi

require 'fileutils'
require 'spec_helper'
require 'tmpdir'

RSpec.describe(HttpLoader::Harness::ErrorTally) do
  let(:log_dir)    { Dir.mktmpdir                                 }
  let(:tally)      { HttpLoader::Harness::ErrorTally.new(log_dir) }
  let(:client_log) { File.join(log_dir, 'client.log')             }

  after { FileUtils.remove_entry(log_dir) }

  describe '.complete_lines' do
    it('keeps the bytes up to and including the last newline') do
      expect(HttpLoader::Harness::ErrorTally.complete_lines("a\nb\nc")).to(eq("a\nb\n"))
    end

    it 'is nil without a newline' do
      expect(HttpLoader::Harness::ErrorTally.complete_lines('abc').nil?).to(be(true))
    end
  end

  describe '#counts' do
    it 'starts every metric at zero, while the logs do not exist' do
      expect(tally.counts).to(eq(emfile: 0, eaddr_count: 0, thread_errors: 0))
    end

    it 'returns a copy, so that changing it does not change the tally' do
      tally.counts[:emfile] = 99
      expect(tally.counts.fetch(:emfile)).to(eq(0))
    end

    it 'counts the tokens of both client logs' do
      File.write(File.join(log_dir, 'client.log'), "ERROR_EMFILE\nERROR_THREADLIMIT ERROR_THREADLIMIT\n")
      File.write(File.join(log_dir, 'client.err'), "ERROR_EADDRNOTAVAIL\n")
      expect(tally.counts).to(eq(emfile: 1, eaddr_count: 1, thread_errors: 2))
    end

    it 'ignores a trailing partial line until it is completed', :aggregate_failures do
      File.write(client_log, "ERROR_EMFILE\nERROR_EMFILE_partial", mode: 'wb')
      expect(tally.counts.fetch(:emfile)).to(eq(1))
      File.write(client_log, "\n", mode: 'ab')
      expect(tally.counts.fetch(:emfile)).to(eq(2))
    end

    it 'counts a long pending line exactly once, only after its newline arrives', :aggregate_failures do
      # The pending line is longer than any offset a mutation might wrongly carry forward.
      File.write(client_log, "ERROR_EMFILE #{'x' * 200}", mode: 'wb')
      expect(tally.counts.fetch(:emfile)).to(eq(0))
      File.write(client_log, "\n", mode: 'ab')
      expect(tally.counts.fetch(:emfile)).to(eq(1))
    end

    it 'reads the log bytes in binary mode, tolerating non-UTF-8 content' do
      File.write(client_log, "\xFFERROR_EMFILE\n", mode: 'wb')
      expect(tally.counts.fetch(:emfile)).to(eq(1))
    end

    it 'does not count the same lines again when nothing was appended' do
      File.write(client_log, "ERROR_EMFILE\n", mode: 'wb')
      tally.counts
      expect(tally.counts.fetch(:emfile)).to(eq(1))
    end

    context 'when a first count has read the logs' do
      before do
        File.write(client_log, "ERROR_EMFILE this first generation line is deliberately long\n", mode: 'wb')
        File.write(File.join(log_dir, 'client.err'), "a much longer line of the other log, which has no token at all\n")
        tally.counts
      end

      it 'counts only the newly appended tail of each log, never re-reading old bytes' do
        File.write(client_log, "ERROR_EADDRNOTAVAIL\n", mode: 'ab')
        expect(tally.counts).to(eq(emfile: 1, eaddr_count: 1, thread_errors: 0))
      end

      it 'reads on from the end of everything it has read, over several counts' do
        File.write(client_log, "ERROR_EADDRNOTAVAIL\n", mode: 'ab')
        tally.counts
        expect(tally.counts).to(eq(emfile: 1, eaddr_count: 1, thread_errors: 0))
      end

      it 'reads a log from the start again once it is shorter than before (truncated or rotated)' do
        File.write(client_log, "ERROR_THREADLIMIT\n", mode: 'wb')
        expect(tally.counts).to(eq(emfile: 1, eaddr_count: 0, thread_errors: 1))
      end
    end
  end
end
