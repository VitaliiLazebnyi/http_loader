# typed: true
# frozen_string_literal: true

# Copyright (c) 2026 Vitalii Lazebnyi

require 'spec_helper'

RSpec.describe(HttpLoader::Harness::ResourceMonitor) do
  let(:monitor)   { HttpLoader::Harness::ResourceMonitor.new }
  let(:page_size) { "4096\n"                                 }
  let(:clk_tck)   { "100\n"                                  }

  # getconf is resolved eagerly at construction.
  before do
    allow(Open3).to(receive(:capture2).with('getconf', 'PAGE_SIZE').and_return([page_size, nil]))
    allow(Open3).to(receive(:capture2).with('getconf', 'CLK_TCK').and_return([clk_tck, nil]))
  end

  describe '#process_stats routing' do
    let(:native) { ['1.0', '1.00 MB', 1024.0, 3] }
    let(:fallback) { ['2.0', '2.00 MB', 2048.0, 4] }

    before do
      allow(monitor).to(receive_messages(native_linux_stats: native, fallback_ps_stats: fallback))
      allow(File).to(receive(:exist?).and_return(true))
    end

    it 'returns the EXTERNAL tuple for a nil pid without touching /proc', :aggregate_failures do
      expect(monitor.process_stats(nil)).to(eq(['EXTERNAL', 'EXTERNAL', 0.0, 0]))
      expect(monitor).not_to(have_received(:native_linux_stats))
    end

    it 'uses native /proc stats when both stat and statm exist' do
      expect(monitor.process_stats(5)).to(eq(native))
    end

    it 'falls back to ps (with the pid) when statm is missing (stat present)', :aggregate_failures do
      allow(File).to(receive(:exist?).with('/proc/5/statm').and_return(false))
      expect(monitor.process_stats(5)).to(eq(fallback))
      expect(monitor).to(have_received(:fallback_ps_stats).with(5))
    end

    it 'falls back to ps (with the pid) when stat is missing (statm present)', :aggregate_failures do
      allow(File).to(receive(:exist?).with('/proc/5/stat').and_return(false))
      expect(monitor.process_stats(5)).to(eq(fallback))
      expect(monitor).to(have_received(:fallback_ps_stats).with(5))
    end

    it 'falls back to ps (with the pid) when native stats raise', :aggregate_failures do
      allow(monitor).to(receive(:native_linux_stats).and_raise(StandardError))
      expect(monitor.process_stats(5)).to(eq(fallback))
      expect(monitor).to(have_received(:fallback_ps_stats).with(5))
    end
  end

  describe '#process_stats native /proc path' do
    # Fields 14/15 (utime/stime) are 100/200; comm has a space and parens to exercise the robust parse.
    let(:stat_line) { "123 (Web Content) S 1 1 1 0 -1 0 0 0 0 0 100 200 0 0 20 0 4 0 1 1 2560 1\n" }

    before do
      allow(File).to(receive(:exist?).and_return(true))
      allow(File).to(receive(:read).with('/proc/123/stat').and_return(stat_line))
      allow(File).to(receive(:read).with('/proc/123/statm').and_return("10240 317 1 1 1 1 1\n"))
      allow(File).to(receive(:read).with('/proc/123/status').and_return("Threads:   42\n"))
    end

    it 'reads a multi-space, multi-digit thread count from /proc/pid/status' do
      expect(monitor.process_stats(123).fetch(3)).to(eq(42))
    end

    it 'defaults the thread count to 1 when status has no Threads line' do
      allow(File).to(receive(:read).with('/proc/123/status').and_return("No threads here\n"))
      expect(monitor.process_stats(123).fetch(3)).to(eq(1))
    end

    it 'formats RSS as pages*page_size to two decimal MB and reports the raw KB float' do
      # statm pages 317 * 4096 B / 1024 = 1268.0 KB; /1024 = 1.23828125 MB -> 1.24.
      expect(monitor.process_stats(123).values_at(1, 2)).to(eq(['1.24 MB', 1268.0]))
    end

    it 'reports 0.0 CPU on the first sample' do
      expect(monitor.process_stats(123).fetch(0)).to(eq('0.0'))
    end

    it 'reports the CLK_TCK/interval-scaled delta on the second sample' do
      allow(Time).to(receive(:now).and_return(Time.at(0), Time.at(2)))
      monitor.process_stats(123)
      allow(File).to(receive(:read).with('/proc/123/stat').and_return(stat_line.sub('100 200', '150 300')))
      # delta (50 + 100) ticks / 100 CLK_TCK / 2s * 100 = 75.0%.
      expect(monitor.process_stats(123).fetch(0)).to(eq('75.0'))
    end

    it 'keeps per-pid CPU history separate (no cross-pid tick crediting)' do
      allow(Time).to(receive(:now).and_return(Time.at(0), Time.at(2)))
      monitor.process_stats(123)
      allow(File).to(receive(:read).with(%r{\A/proc/456/}) { |path| File.read(path.sub('456', '123')) })
      # 456's first sample, not a delta against 123.
      expect(monitor.process_stats(456).fetch(0)).to(eq('0.0'))
    end

    context 'with a non-default page size from getconf' do
      let(:page_size) { "8192\n" }

      # 317 * 8192 / 1024
      it('honours it') { expect(monitor.process_stats(123).fetch(2)).to(eq(2536.0)) }
    end

    context 'when getconf reports a page size with a leading zero' do
      let(:page_size) { "08192\n" }

      # Parsed as decimal: as octal (base 0) "08192" is invalid and would fall back to 4096.
      it('parses it as decimal') { expect(monitor.process_stats(123).fetch(2)).to(eq(2536.0)) }
    end

    it 'parses the statm resident page count as decimal, even with a leading zero' do
      allow(File).to(receive(:read).with('/proc/123/statm').and_return("10240 0317 1 1 1 1 1\n"))
      expect(monitor.process_stats(123).fetch(2)).to(eq(1268.0))
    end

    it 'parses the thread count as decimal, even with a leading zero' do
      allow(File).to(receive(:read).with('/proc/123/status').and_return("Threads:   042\n"))
      expect(monitor.process_stats(123).fetch(3)).to(eq(42))
    end

    context 'when getconf reports a zero page size' do
      let(:page_size) { "0\n" }

      it('uses the default page size (4096)') { expect(monitor.process_stats(123).fetch(2)).to(eq(1268.0)) }
    end

    it 'uses the default page size (4096) when getconf raises' do
      allow(Open3).to(receive(:capture2).with('getconf', 'PAGE_SIZE').and_raise(StandardError))
      expect(monitor.process_stats(123).fetch(2)).to(eq(1268.0))
    end
  end

  describe '#calculate_cpu' do
    it 'returns 0.0 on the first observation of a pid' do
      expect(monitor.__send__(:calculate_cpu, 1, 100.0)).to(eq(0.0))
    end

    it 'tracks each pid independently (a different pid is a first observation, not a cross-pid delta)' do
      allow(Time).to(receive(:now).and_return(Time.at(0), Time.at(1)))
      monitor.__send__(:calculate_cpu, 1, 100.0)
      expect(monitor.__send__(:calculate_cpu, 2, 500.0)).to(eq(0.0))
    end

    it 'returns 0.0 when the clock went backwards since the previous sample' do
      allow(Time).to(receive(:now).and_return(Time.at(1), Time.at(0)))
      monitor.__send__(:calculate_cpu, 1, 100.0)
      expect(monitor.__send__(:calculate_cpu, 1, 200.0)).to(eq(0.0))
    end

    it 'returns 0.0 when no time has elapsed since the previous sample' do
      allow(Time).to(receive(:now).and_return(Time.at(0)))
      monitor.__send__(:calculate_cpu, 1, 100.0)
      expect(monitor.__send__(:calculate_cpu, 1, 200.0)).to(eq(0.0))
    end

    it 'scales the tick delta by CLK_TCK and the sub-second interval, rounded to one decimal' do
      allow(Time).to(receive(:now).and_return(Time.at(0), Time.at(0.3)))
      monitor.__send__(:calculate_cpu, 1, 100.0)
      # delta 10 ticks / 100 CLK_TCK / 0.3s * 100 = 33.333...% -> 33.3 (a Float, not 33 or 33.33).
      expect(monitor.__send__(:calculate_cpu, 1, 110.0)).to(be(33.3))
    end

    it 'uses the CLK_TCK fallback of 100 when getconf fails' do
      allow(Open3).to(receive(:capture2).with('getconf', 'CLK_TCK').and_raise(StandardError))
      allow(Time).to(receive(:now).and_return(Time.at(0), Time.at(1)))
      monitor.__send__(:calculate_cpu, 1, 100.0)
      # 100 ticks / 100 / 1s * 100
      expect(monitor.__send__(:calculate_cpu, 1, 200.0)).to(eq(100.0))
    end
  end

  describe '#process_stats ps fallback path' do
    before do
      allow(File).to(receive(:exist?).and_return(false))
      allow(Open3).to(
        receive(:capture2).with('ps', '-o', '%cpu,rss', '-p', '123')
                .and_return(["%CPU   RSS\n  12.3   1268\n", nil])
      )
      # A header row and two thread rows (3 newlines) => 2 threads.
      allow(Open3).to(receive(:capture2).with('ps', '-M', '-p', '123').and_return(["USER PID\nu 1\nv 2\n", nil]))
    end

    it 'parses a multi-space ps row and counts ps -M rows minus the header' do
      expect(monitor.process_stats(123)).to(eq(['12.3', '1.24 MB', 1268.0, 2]))
    end

    it 'reports the RSS as a Float (be is type-strict)' do
      expect(monitor.process_stats(123).fetch(2)).to(be(1268.0))
    end

    it 'floors the thread count at zero for an empty ps -M result' do
      allow(Open3).to(receive(:capture2).with('ps', '-M', '-p', '123').and_return(['', nil]))
      expect(monitor.process_stats(123).fetch(3)).to(eq(0))
    end

    it 'defaults the thread count to 1 when ps -M raises' do
      allow(Open3).to(receive(:capture2).with('ps', '-M', '-p', '123').and_raise(StandardError))
      expect(monitor.process_stats(123).fetch(3)).to(eq(1))
    end

    it 'returns the N/A tuple when ps has no data row' do
      allow(Open3).to(receive(:capture2).with('ps', '-o', '%cpu,rss', '-p', '123').and_return(["%CPU RSS\n", nil]))
      expect(monitor.process_stats(123)).to(eq(['N/A', 'N/A', 0.0, 0]))
    end

    it 'returns the N/A tuple when the ps command raises' do
      allow(Open3).to(receive(:capture2).with('ps', '-o', '%cpu,rss', '-p', '123').and_raise(StandardError))
      expect(monitor.process_stats(123)).to(eq(['N/A', 'N/A', 0.0, 0]))
    end
  end

  describe '#record_cpu_sample history bounding' do
    let(:limit) { HttpLoader::Harness::ResourceMonitor::CPU_HISTORY_LIMIT }

    it 'keeps exactly CPU_HISTORY_LIMIT entries once that many distinct pids are seen' do
      limit.times { |pid| monitor.__send__(:record_cpu_sample, pid, 1.0, Time.at(0)) }
      expect(monitor.instance_variable_get(:@cpu_prev).size).to(eq(limit))
    end

    it 'never exceeds CPU_HISTORY_LIMIT as more pids arrive' do
      (limit + 50).times { |pid| monitor.__send__(:record_cpu_sample, pid, 1.0, Time.at(0)) }
      expect(monitor.instance_variable_get(:@cpu_prev).size).to(eq(limit))
    end

    it 'returns nil on the first sighting of a pid' do
      expect(monitor.__send__(:record_cpu_sample, 7, 10.0, Time.at(0)).nil?).to(be(true))
    end

    it 'returns the previous sample for a repeated pid' do
      monitor.__send__(:record_cpu_sample, 7, 10.0, Time.at(0))
      expect(
        monitor.__send__(
          :record_cpu_sample,
          7,
          20.0,
          Time.at(1)
        )
      ).to(have_attributes(ticks: 10.0, time: Time.at(0)))
    end
  end
end
