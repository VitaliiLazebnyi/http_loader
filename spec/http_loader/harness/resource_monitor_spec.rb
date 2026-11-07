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

    it 'returns 0.0 when no time has elapsed since the previous sample' do
      allow(Time).to(receive(:now).and_return(Time.at(0)))
      monitor.__send__(:calculate_cpu, 1, 100.0)
      expect(monitor.__send__(:calculate_cpu, 1, 200.0)).to(eq(0.0))
    end

    it 'scales the tick delta by CLK_TCK and the sub-second interval, rounded to one decimal' do
      allow(Time).to(receive(:now).and_return(Time.at(0), Time.at(0.3)))
      monitor.__send__(:calculate_cpu, 1, 100.0)
      # delta 10 ticks / 100 CLK_TCK / 0.3s * 100 = 33.333...% -> 33.3 (a Float, not 33 or 33.33).
      expect(monitor.__send__(:calculate_cpu, 1, 110.0)).to(eql(33.3))
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

    it 'reports the RSS as a Float (eql is type-strict)' do
      expect(monitor.process_stats(123).fetch(2)).to(eql(1268.0))
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

  describe '#count_established_connections' do
    it 'returns zero for a nil pid' do
      expect(monitor.count_established_connections(nil)).to(eq(0))
    end

    context 'with a Linux /proc/pid/fd directory' do
      before do
        allow(File).to(receive(:directory?).with('/proc/123/fd').and_return(true))
        allow(File).to(receive(:exist?).with(%r{\A/proc/123/net/tcp6?\z}).and_return(true))
        allow(File).to(
          receive(:read).with('/proc/123/net/tcp').and_return(
            "  sl local rem st ... inode\n  " \
            "0: 0100007F:1F90 0100007F:C000 01 00:00 00 00 0 0 555 1\n  " \
            "1: 0100007F:1F91 00000000:0000 0A 00:00 00 00 0 0 999 1\n"
          )
        )
        allow(File).to(
          receive(:read).with('/proc/123/net/tcp6').and_return(
            "  sl local rem st ... inode\n  0: 0100007F:1F90 0100007F:C000 01 00:00 00 00 0 0 777 1\n"
          )
        )
        allow(Dir).to(receive(:glob).with('/proc/123/fd/*').and_return(%w[/proc/123/fd/1 /proc/123/fd/2]))
        allow(File).to(receive(:readlink).with('/proc/123/fd/1').and_return('socket:[555]'))
        allow(File).to(receive(:readlink).with('/proc/123/fd/2').and_return('socket:[777]'))
      end

      it 'counts the socket fds whose inode is ESTABLISHED in net/tcp or net/tcp6' do
        expect(monitor.count_established_connections(123)).to(eq(2))
      end

      it 'does not count a listening socket' do
        allow(File).to(receive(:readlink).with('/proc/123/fd/2').and_return('socket:[999]'))
        expect(monitor.count_established_connections(123)).to(eq(1))
      end

      it 'reads only the net files that exist (tcp6 absent) rather than failing' do
        allow(File).to(receive(:exist?).with('/proc/123/net/tcp6').and_return(false))
        expect(monitor.count_established_connections(123)).to(eq(1))
      end

      it 'finds no connections when neither net file exists' do
        allow(File).to(receive(:exist?).with(%r{\A/proc/123/net/tcp6?\z}).and_return(false))
        expect(monitor.count_established_connections(123)).to(eq(0))
      end
    end

    it 'counts only (ESTABLISHED) lines via lsof when /proc/pid/fd is absent' do
      allow(File).to(receive(:directory?).with('/proc/123/fd').and_return(false))
      lsof = "COMMAND PID\nruby 123 TCP *:8080 (ESTABLISHED)\nruby 123 TCP *:9 (LISTEN)\n" \
             "ruby 123 TCP *:7 (ESTABLISHED)\n"
      allow(Open3).to(receive(:capture2).with('lsof', '-p', '123', '-n', '-P').and_return([lsof, nil]))
      expect(monitor.count_established_connections(123)).to(eq(2))
    end

    it 'rescues any error and returns zero' do
      allow(File).to(receive(:directory?).with('/proc/123/fd').and_raise(StandardError))
      expect(monitor.count_established_connections(123)).to(eq(0))
    end
  end

  describe '#established_inodes (private)' do
    before do
      allow(File).to(receive(:exist?).with('/proc/9/net/tcp').and_return(true))
      allow(File).to(receive(:exist?).with('/proc/9/net/tcp6').and_return(false))
      allow(File).to(
        receive(:read).with('/proc/9/net/tcp').and_return(
          "  sl local rem st ... inode\n  " \
          "0: 0100007F:1F90 0100007F:C000 01 00:00 00 00 0 0 555 1\n  " \
          "1: 0100007F:1F91 00000000:0000 0A 00:00 00 00 0 0 999 1\n"
        )
      )
    end

    it 'collects state-01 inodes from tcp, skipping non-ESTABLISHED rows and a missing proto file' do
      expect(monitor.__send__(:established_inodes, 9)).to(eq(['555']))
    end

    it 'merges inodes from both proto files, in tcp-then-tcp6 order, when both are present' do
      allow(File).to(receive(:exist?).with('/proc/9/net/tcp6').and_return(true))
      allow(File).to(
        receive(:read).with('/proc/9/net/tcp6').and_return(
          "  sl local rem st ... inode\n  0: ::1:1F90 ::1:C000 01 00:00 00 00 0 0 777 1\n"
        )
      )
      expect(monitor.__send__(:established_inodes, 9)).to(eq(%w[555 777]))
    end
  end

  describe '#socket_inode (private)' do
    it 'extracts the inode from a bare socket symlink target' do
      allow(File).to(receive(:readlink).with('/proc/9/fd/3').and_return('socket:[12345]'))
      expect(monitor.__send__(:socket_inode, '/proc/9/fd/3')).to(eq('12345'))
    end

    it 'returns nil for a non-socket descriptor target' do
      allow(File).to(receive(:readlink).with('/proc/9/fd/4').and_return(File::NULL))
      expect(monitor.__send__(:socket_inode, '/proc/9/fd/4').nil?).to(be(true))
    end

    it 'anchors the match, rejecting a socket:[n] fragment embedded in a longer target' do
      allow(File).to(receive(:readlink).with('/proc/9/fd/5').and_return('anon_inode:socket:[7]x'))
      expect(monitor.__send__(:socket_inode, '/proc/9/fd/5').nil?).to(be(true))
    end
  end

  describe '#fd_socket_inodes (private)' do
    it 'maps socket fds to inodes, dropping non-sockets and descriptors that vanish mid-walk' do
      allow(Dir).to(receive(:glob).with('/proc/9/fd/*').and_return(%w[/proc/9/fd/1 /proc/9/fd/2 /proc/9/fd/3]))
      allow(File).to(receive(:readlink).with('/proc/9/fd/1').and_return('socket:[100]'))
      allow(File).to(receive(:readlink).with('/proc/9/fd/2').and_return(File::NULL))
      allow(File).to(receive(:readlink).with('/proc/9/fd/3').and_raise(StandardError))
      expect(monitor.__send__(:fd_socket_inodes, 9)).to(eq(['100']))
    end
  end

  describe '#count_linux_connections (private)' do
    it 'counts only the fd inodes that appear in the established set' do
      allow(monitor).to(receive(:established_inodes).with(9).and_return(%w[100 300]))
      allow(monitor).to(receive(:fd_socket_inodes).with(9).and_return(%w[100 200 300]))
      expect(monitor.__send__(:count_linux_connections, 9)).to(eq(2))
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
