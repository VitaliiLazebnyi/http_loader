# typed: false
# frozen_string_literal: true

require 'spec_helper'
require 'http_loader/harness/resource_monitor'

RSpec.describe HttpLoader::Harness::ResourceMonitor do
  let(:monitor) { described_class.new }

  # getconf is resolved eagerly at construction; stub both constants (overridable per example).
  def stub_getconf(page: "4096\n", clk: "100\n")
    allow(Open3).to receive(:capture2).with('getconf', 'PAGE_SIZE').and_return([page, nil])
    allow(Open3).to receive(:capture2).with('getconf', 'CLK_TCK').and_return([clk, nil])
  end

  before { stub_getconf }

  describe '#process_stats routing' do
    before { allow(monitor).to receive_messages(native_linux_stats: :native, fallback_ps_stats: :fallback) }

    it 'returns the EXTERNAL tuple for a nil pid without touching /proc' do
      expect(monitor.process_stats(nil)).to eq(['EXTERNAL', 'EXTERNAL', 0.0, 0])
      expect(monitor).not_to have_received(:native_linux_stats)
    end

    it 'uses native /proc stats only when both stat and statm exist' do
      allow(File).to receive(:exist?).with('/proc/5/stat').and_return(true)
      allow(File).to receive(:exist?).with('/proc/5/statm').and_return(true)
      expect(monitor.process_stats(5)).to eq(:native)
    end

    it 'falls back to ps (with the pid) when statm is missing (stat present)' do
      allow(File).to receive(:exist?).with('/proc/5/stat').and_return(true)
      allow(File).to receive(:exist?).with('/proc/5/statm').and_return(false)
      expect(monitor.process_stats(5)).to eq(:fallback)
      expect(monitor).to have_received(:fallback_ps_stats).with(5)
    end

    it 'falls back to ps (with the pid) when stat is missing (statm present)' do
      allow(File).to receive(:exist?).with('/proc/5/stat').and_return(false)
      allow(File).to receive(:exist?).with('/proc/5/statm').and_return(true)
      expect(monitor.process_stats(5)).to eq(:fallback)
      expect(monitor).to have_received(:fallback_ps_stats).with(5)
    end

    it 'falls back to ps (with the pid) when native stats raise' do
      allow(File).to receive(:exist?).and_return(true)
      allow(monitor).to receive(:native_linux_stats).and_raise(StandardError)
      expect(monitor.process_stats(5)).to eq(:fallback)
      expect(monitor).to have_received(:fallback_ps_stats).with(5)
    end
  end

  describe '#process_stats native /proc path' do
    # field 14/15 (utime/stime) are 100/200; comm has a space + parens to exercise the robust parse.
    def stat_line(pid: 123, utime: 100, stime: 200)
      "#{pid} (Web Content) S 1 1 1 0 -1 0 0 0 0 0 #{utime} #{stime} 0 0 20 0 4 0 1 1 2560 1\n"
    end

    before do
      allow(File).to receive(:exist?).with('/proc/123/stat').and_return(true)
      allow(File).to receive(:exist?).with('/proc/123/statm').and_return(true)
      allow(File).to receive(:read).with('/proc/123/stat').and_return(stat_line)
      allow(File).to receive(:read).with('/proc/123/statm').and_return("10240 317 1 1 1 1 1\n")
      allow(File).to receive(:read).with('/proc/123/status').and_return("Threads:   42\n")
    end

    it 'reads a multi-space, multi-digit thread count from /proc/pid/status' do
      expect(monitor.process_stats(123)[3]).to eq(42)
    end

    it 'defaults the thread count to 1 when status has no Threads line' do
      allow(File).to receive(:read).with('/proc/123/status').and_return("No threads here\n")
      expect(monitor.process_stats(123)[3]).to eq(1)
    end

    it 'formats RSS as pages*page_size to two decimal MB and reports the raw KB float' do
      # statm pages 317 * 4096 B / 1024 = 1268.0 KB; /1024 = 1.23828125 MB -> 1.24.
      stats = monitor.process_stats(123)
      expect(stats[1]).to eq('1.24 MB')
      expect(stats[2]).to eq(1268.0)
    end

    it 'honours a non-default page size from getconf' do
      stub_getconf(page: "8192\n")
      expect(described_class.new.process_stats(123)[2]).to eq(2536.0) # 317 * 8192 / 1024
    end

    it 'reports 0.0 CPU on the first sample and the CLK_TCK/interval-scaled delta on the second' do
      now = Time.now
      allow(Time).to receive(:now).and_return(now)
      expect(monitor.process_stats(123)[0]).to eq('0.0')

      allow(Time).to receive(:now).and_return(now + 2.0)
      allow(File).to receive(:read).with('/proc/123/stat').and_return(stat_line(utime: 150, stime: 300))
      # delta (50 + 100) ticks / 100 CLK_TCK / 2s * 100 = 75.0%.
      expect(monitor.process_stats(123)[0]).to eq('75.0')
    end

    it 'keeps per-pid CPU history separate (no cross-pid tick crediting)' do
      now = Time.now
      allow(Time).to receive(:now).and_return(now)
      monitor.process_stats(123)
      allow(File).to receive(:exist?).with('/proc/456/stat').and_return(true)
      allow(File).to receive(:exist?).with('/proc/456/statm').and_return(true)
      allow(File).to receive(:read).with('/proc/456/stat').and_return(stat_line(pid: 456, utime: 900, stime: 900))
      allow(File).to receive(:read).with('/proc/456/statm').and_return("10240 317 1 1 1 1 1\n")
      allow(File).to receive(:read).with('/proc/456/status').and_return("Threads:   1\n")
      allow(Time).to receive(:now).and_return(now + 2.0)
      expect(monitor.process_stats(456)[0]).to eq('0.0') # 456's first sample, not a delta vs 123
    end

    it 'uses the default page size (4096) when getconf returns zero or raises' do
      stub_getconf(page: "0\n")
      expect(described_class.new.process_stats(123)[2]).to eq(1268.0)
      allow(Open3).to receive(:capture2).with('getconf', 'PAGE_SIZE').and_raise(StandardError)
      expect(described_class.new.process_stats(123)[2]).to eq(1268.0)
    end
  end

  describe '#calculate_cpu' do
    it 'returns 0.0 on the first observation of a pid' do
      expect(monitor.send(:calculate_cpu, 1, 100.0)).to eq(0.0)
    end

    it 'tracks each pid independently (a different pid is a first observation, not a cross-pid delta)' do
      now = Time.now
      allow(Time).to receive(:now).and_return(now, now + 1.0)
      monitor.send(:calculate_cpu, 1, 100.0) # pid 1: first sample
      expect(monitor.send(:calculate_cpu, 2, 500.0)).to eq(0.0) # pid 2: its own first sample => 0.0
    end

    it 'returns 0.0 when no time has elapsed since the previous sample' do
      now = Time.now
      allow(Time).to receive(:now).and_return(now)
      monitor.send(:calculate_cpu, 1, 100.0)
      expect(monitor.send(:calculate_cpu, 1, 200.0)).to eq(0.0)
    end

    it 'scales the tick delta by CLK_TCK and the sub-second interval, rounded to one decimal' do
      now = Time.now
      allow(Time).to receive(:now).and_return(now, now + 0.3)
      monitor.send(:calculate_cpu, 1, 100.0)
      # delta 10 ticks / 100 CLK_TCK / 0.3s * 100 = 33.333...% -> 33.3 (a Float, not 33 or 33.33).
      expect(monitor.send(:calculate_cpu, 1, 110.0)).to eq(33.3).and be_a(Float)
    end

    it 'uses the CLK_TCK fallback of 100 when getconf fails' do
      allow(Open3).to receive(:capture2).with('getconf', 'PAGE_SIZE').and_return(["4096\n", nil])
      allow(Open3).to receive(:capture2).with('getconf', 'CLK_TCK').and_raise(StandardError)
      fresh = described_class.new
      now = Time.now
      allow(Time).to receive(:now).and_return(now, now + 1.0)
      fresh.send(:calculate_cpu, 1, 100.0)
      expect(fresh.send(:calculate_cpu, 1, 200.0)).to eq(100.0) # 100 ticks / 100 / 1s * 100
    end
  end

  describe '#process_stats ps fallback path' do
    before { allow(File).to receive(:exist?).and_return(false) }

    it 'parses a multi-space ps row and counts ps -M rows minus the header' do
      allow(Open3).to receive(:capture2).with('ps', '-o', '%cpu,rss', '-p', '123')
                                        .and_return(["%CPU   RSS\n  12.3   1268\n", nil])
      # Header row + two thread rows (3 newlines) => 2 threads.
      allow(Open3).to receive(:capture2).with('ps', '-M', '-p', '123').and_return(["USER PID\nu 1\nv 2\n", nil])
      stats = monitor.process_stats(123)
      expect(stats[0]).to eq('12.3')
      expect(stats[1]).to eq('1.24 MB')
      expect(stats[2]).to eq(1268.0).and be_a(Float)
      expect(stats[3]).to eq(2)
    end

    it 'floors the thread count at zero for an empty ps -M result' do
      allow(Open3).to receive(:capture2).with('ps', '-o', '%cpu,rss', '-p', '123')
                                        .and_return(["%CPU RSS\n 1.0 1024\n", nil])
      allow(Open3).to receive(:capture2).with('ps', '-M', '-p', '123').and_return(['', nil])
      expect(monitor.process_stats(123)[3]).to eq(0)
    end

    it 'defaults the thread count to 1 when ps -M raises' do
      allow(Open3).to receive(:capture2).with('ps', '-o', '%cpu,rss', '-p', '123')
                                        .and_return(["%CPU RSS\n 1.0 1024\n", nil])
      allow(Open3).to receive(:capture2).with('ps', '-M', '-p', '123').and_raise(StandardError)
      expect(monitor.process_stats(123)[3]).to eq(1)
    end

    it 'returns the N/A tuple when ps has no data row' do
      allow(Open3).to receive(:capture2).with('ps', '-o', '%cpu,rss', '-p', '123').and_return(["%CPU RSS\n", nil])
      expect(monitor.process_stats(123)).to eq(['N/A', 'N/A', 0.0, 0])
    end

    it 'returns the N/A tuple when the ps command raises' do
      allow(Open3).to receive(:capture2).with('ps', '-o', '%cpu,rss', '-p', '123').and_raise(StandardError)
      expect(monitor.process_stats(123)).to eq(['N/A', 'N/A', 0.0, 0])
    end
  end

  describe '#count_established_connections' do
    it 'returns zero for a nil pid' do
      expect(monitor.count_established_connections(nil)).to eq(0)
    end

    it 'counts ESTABLISHED socket fds on Linux, intersecting net/tcp and net/tcp6 inodes' do
      allow(File).to receive(:directory?).with('/proc/123/fd').and_return(true)
      allow(File).to receive(:exist?).with('/proc/123/net/tcp').and_return(true)
      allow(File).to receive(:exist?).with('/proc/123/net/tcp6').and_return(true)
      allow(File).to receive(:readlines).with('/proc/123/net/tcp').and_return(
        [
          "  sl local rem st ... inode\n",
          "  0: 0100007F:1F90 0100007F:C000 01 00:00 00 00 0 0 555 1\n", # ESTABLISHED (st 01)
          "  1: 0100007F:1F91 00000000:0000 0A 00:00 00 00 0 0 999 1\n"  # LISTEN (st 0A)
        ]
      )
      allow(File).to receive(:readlines).with('/proc/123/net/tcp6').and_return(
        ["  sl local rem st ... inode\n", "  0: 0100007F:1F90 0100007F:C000 01 00:00 00 00 0 0 777 1\n"] # ESTABLISHED inode 777
      )
      allow(Dir).to receive(:glob).with('/proc/123/fd/*')
                                  .and_return(%w[/proc/123/fd/1 /proc/123/fd/2 /proc/123/fd/3 /proc/123/fd/4 /proc/123/fd/5])
      allow(File).to receive(:readlink).with('/proc/123/fd/1').and_return('socket:[555]') # established tcp
      allow(File).to receive(:readlink).with('/proc/123/fd/2').and_return('socket:[999]') # listening tcp inode
      allow(File).to receive(:readlink).with('/proc/123/fd/3').and_return(File::NULL) # non-socket
      allow(File).to receive(:readlink).with('/proc/123/fd/4').and_return('socket:[777]') # established tcp6
      allow(File).to receive(:readlink).with('/proc/123/fd/5').and_raise(StandardError) # rescued => false
      expect(monitor.count_established_connections(123)).to eq(2)
    end

    it 'reads only the net files that exist (tcp present, tcp6 absent) rather than failing' do
      allow(File).to receive(:directory?).with('/proc/123/fd').and_return(true)
      allow(File).to receive(:exist?).with('/proc/123/net/tcp').and_return(true)
      allow(File).to receive(:exist?).with('/proc/123/net/tcp6').and_return(false)
      allow(File).to receive(:readlines).with('/proc/123/net/tcp').and_return(
        ["  sl local rem st ... inode\n", "  0: 0100007F:1F90 0100007F:C000 01 00:00 00 00 0 0 555 1\n"]
      )
      allow(Dir).to receive(:glob).with('/proc/123/fd/*').and_return(['/proc/123/fd/1'])
      allow(File).to receive(:readlink).with('/proc/123/fd/1').and_return('socket:[555]')
      expect(monitor.count_established_connections(123)).to eq(1)
    end

    it 'finds no connections when neither net file exists' do
      allow(File).to receive(:directory?).with('/proc/123/fd').and_return(true)
      allow(File).to receive(:exist?).with('/proc/123/net/tcp').and_return(false)
      allow(File).to receive(:exist?).with('/proc/123/net/tcp6').and_return(false)
      allow(Dir).to receive(:glob).with('/proc/123/fd/*').and_return(['/proc/123/fd/1'])
      allow(File).to receive(:readlink).with('/proc/123/fd/1').and_return('socket:[555]')
      expect(monitor.count_established_connections(123)).to eq(0)
    end

    it 'counts only (ESTABLISHED) lines via lsof when /proc/pid/fd is absent' do
      allow(File).to receive(:directory?).with('/proc/123/fd').and_return(false)
      lsof = "COMMAND PID\nruby 123 TCP *:8080 (ESTABLISHED)\nruby 123 TCP *:9 (LISTEN)\n" \
             "ruby 123 TCP *:7 (ESTABLISHED)\n"
      allow(Open3).to receive(:capture2).with('lsof', '-p', '123', '-n', '-P').and_return([lsof, nil])
      expect(monitor.count_established_connections(123)).to eq(2)
    end

    it 'rescues any error and returns zero' do
      allow(File).to receive(:directory?).with('/proc/123/fd').and_raise(StandardError)
      expect(monitor.count_established_connections(123)).to eq(0)
    end
  end

  describe '#established_inodes (private)' do
    it 'collects state-01 inodes from tcp, skipping non-ESTABLISHED rows and a missing proto file' do
      allow(File).to receive(:exist?).with('/proc/9/net/tcp').and_return(true)
      allow(File).to receive(:exist?).with('/proc/9/net/tcp6').and_return(false)
      allow(File).to receive(:readlines).with('/proc/9/net/tcp').and_return(
        [
          "  sl local rem st ... inode\n",
          "  0: 0100007F:1F90 0100007F:C000 01 00:00 00 00 0 0 555 1\n", # ESTABLISHED (st 01)
          "  1: 0100007F:1F91 00000000:0000 0A 00:00 00 00 0 0 999 1\n"  # LISTEN (st 0A) -> skipped
        ]
      )
      expect(monitor.send(:established_inodes, 9)).to eq(['555'])
    end

    it 'merges inodes from both proto files, in tcp-then-tcp6 order, when both are present' do
      allow(File).to receive(:exist?).with('/proc/9/net/tcp').and_return(true)
      allow(File).to receive(:exist?).with('/proc/9/net/tcp6').and_return(true)
      allow(File).to receive(:readlines).with('/proc/9/net/tcp').and_return(
        ["  sl local rem st ... inode\n", "  0: 0100007F:1F90 0100007F:C000 01 00:00 00 00 0 0 555 1\n"]
      )
      allow(File).to receive(:readlines).with('/proc/9/net/tcp6').and_return(
        ["  sl local rem st ... inode\n", "  0: ::1:1F90 ::1:C000 01 00:00 00 00 0 0 777 1\n"]
      )
      expect(monitor.send(:established_inodes, 9)).to eq(%w[555 777])
    end
  end

  describe '#socket_inode (private)' do
    it 'extracts the inode from a bare socket symlink target' do
      allow(File).to receive(:readlink).with('/proc/9/fd/3').and_return('socket:[12345]')
      expect(monitor.send(:socket_inode, '/proc/9/fd/3')).to eq('12345')
    end

    it 'returns nil for a non-socket descriptor target' do
      allow(File).to receive(:readlink).with('/proc/9/fd/4').and_return(File::NULL)
      expect(monitor.send(:socket_inode, '/proc/9/fd/4')).to be_nil
    end

    it 'anchors the match, rejecting a socket:[n] fragment embedded in a longer target' do
      allow(File).to receive(:readlink).with('/proc/9/fd/5').and_return('anon_inode:socket:[7]x')
      expect(monitor.send(:socket_inode, '/proc/9/fd/5')).to be_nil
    end
  end

  describe '#fd_socket_inodes (private)' do
    it 'maps socket fds to inodes, dropping non-sockets and descriptors that vanish mid-walk' do
      allow(Dir).to receive(:glob).with('/proc/9/fd/*').and_return(%w[/proc/9/fd/1 /proc/9/fd/2 /proc/9/fd/3])
      allow(File).to receive(:readlink).with('/proc/9/fd/1').and_return('socket:[100]')
      allow(File).to receive(:readlink).with('/proc/9/fd/2').and_return(File::NULL)   # non-socket -> dropped
      allow(File).to receive(:readlink).with('/proc/9/fd/3').and_raise(StandardError) # vanished -> rescued, dropped
      expect(monitor.send(:fd_socket_inodes, 9)).to eq(['100'])
    end
  end

  describe '#count_linux_connections (private)' do
    it 'counts only the fd inodes that appear in the established set' do
      allow(monitor).to receive(:established_inodes).with(9).and_return(%w[100 300])
      allow(monitor).to receive(:fd_socket_inodes).with(9).and_return(%w[100 200 300])
      expect(monitor.send(:count_linux_connections, 9)).to eq(2) # 100 and 300 established; 200 is not
    end
  end

  describe '#record_cpu_sample history bounding' do
    it 'keeps exactly CPU_HISTORY_LIMIT entries once that many distinct pids are seen' do
      described_class::CPU_HISTORY_LIMIT.times { |pid| monitor.send(:record_cpu_sample, pid, 1.0, Time.now) }
      expect(monitor.instance_variable_get(:@cpu_prev).size).to eq(described_class::CPU_HISTORY_LIMIT)
    end

    it 'never exceeds CPU_HISTORY_LIMIT as more pids arrive' do
      (described_class::CPU_HISTORY_LIMIT + 50).times { |pid| monitor.send(:record_cpu_sample, pid, 1.0, Time.now) }
      expect(monitor.instance_variable_get(:@cpu_prev).size).to eq(described_class::CPU_HISTORY_LIMIT)
    end

    it 'returns the previous sample for a repeated pid and nil on first sighting' do
      t = Time.now
      expect(monitor.send(:record_cpu_sample, 7, 10.0, t)).to be_nil
      expect(monitor.send(:record_cpu_sample, 7, 20.0, t)).to eq(ticks: 10.0, time: t)
    end
  end
end
