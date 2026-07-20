# typed: false
# frozen_string_literal: true

require 'spec_helper'
require 'http_loader/harness/resource_monitor'

RSpec.describe HttpLoader::Harness::ResourceMonitor do
  let(:monitor) { described_class.new }

  # Default getconf stubs (array form). PAGE_SIZE 4096, CLK_TCK 100.
  def stub_getconf(page: "4096\n", clk: "100\n")
    allow(Open3).to receive(:capture2).with('getconf', 'PAGE_SIZE').and_return([page, nil])
    allow(Open3).to receive(:capture2).with('getconf', 'CLK_TCK').and_return([clk, nil])
  end

  describe '#process_stats' do
    it 'returns EXTERNAL values when pid is nil' do
      expect(monitor.process_stats(nil)).to eq(['EXTERNAL', 'EXTERNAL', 0.0, 0])
    end

    context 'with the ps fallback (no /proc)' do
      before { allow(File).to receive(:exist?).and_return(false) }

      it 'returns N/A on ps command error' do
        allow(Open3).to receive(:capture2).with('ps', '-o', '%cpu,rss', '-p', '123').and_raise(StandardError)
        expect(monitor.process_stats(123)).to eq(['N/A', 'N/A', 0.0, 0])
      end

      it 'returns N/A when ps yields fewer than two lines' do
        allow(Open3).to receive(:capture2).with('ps', '-o', '%cpu,rss', '-p', '123').and_return(["%CPU  RSS\n", nil])
        expect(monitor.process_stats(123)).to eq(['N/A', 'N/A', 0.0, 0])
      end

      it 'parses a successful ps result and counts threads via ps -M' do
        allow(Open3).to receive(:capture2).with('ps', '-o', '%cpu,rss', '-p', '123')
                                          .and_return(["%CPU   RSS\n 12.3 20480\n", nil])
        allow(Open3).to receive(:capture2).with('ps', '-M', '-p', '123').and_return(["USER PID\nu 123\n", nil])
        expect(monitor.process_stats(123)).to eq(['12.3', '20.0 MB', 20_480.0, 1])
      end

      it 'defaults the thread count to 1 when ps -M fails' do
        allow(Open3).to receive(:capture2).with('ps', '-o', '%cpu,rss', '-p', '123')
                                          .and_return(["%CPU   RSS\n 12.3 20480\n", nil])
        allow(Open3).to receive(:capture2).with('ps', '-M', '-p', '123').and_raise(StandardError)
        expect(monitor.process_stats(123)).to eq(['12.3', '20.0 MB', 20_480.0, 1])
      end

      it 'falls back to ps when native_linux_stats raises' do
        allow(File).to receive(:exist?).and_return(true)
        allow(monitor).to receive(:native_linux_stats).and_raise(StandardError)
        allow(Open3).to receive(:capture2).with('ps', '-o', '%cpu,rss', '-p', '123').and_return(["h\n", nil])
        expect(monitor.process_stats(123)).to eq(['N/A', 'N/A', 0.0, 0])
      end
    end

    context 'with native /proc stats' do
      # comm deliberately contains a space + parens to exercise the robust stat parse (M-16).
      let(:proc_stat) { "123 (Web Content) S 1 1 1 0 -1 0 0 0 0 0 100 200 0 0 20 0 4 0 12345 12345 2560 1\n" }

      before do
        allow(File).to receive(:exist?).with('/proc/123/stat').and_return(true)
        allow(File).to receive(:exist?).with('/proc/123/statm').and_return(true)
        allow(File).to receive(:read).with('/proc/123/stat').and_return(proc_stat)
        allow(File).to receive(:read).with('/proc/123/statm').and_return("10240 2560 1 1 1 1 1\n")
        allow(File).to receive(:read).with('/proc/123/status').and_return("Threads:\t4\n")
        stub_getconf(page: "8192\n")
      end

      it 'reads the thread count from /proc/pid/status' do
        expect(monitor.process_stats(123)[3]).to eq(4)
      end

      it 'computes RSS from pages * page_size (2560 * 8192 = 20 MB)' do
        expect(monitor.process_stats(123)[1]).to eq('20.0 MB')
      end

      it 'reports 0.0 CPU on the first sample and a real delta on the second' do
        time = Time.now.utc
        allow(Time).to receive(:now).and_return(time)
        expect(monitor.process_stats(123)[0]).to eq('0.0')

        allow(Time).to receive(:now).and_return(time + 1.0)
        # utime/stime advance 100->150, 200->250: +100 ticks / 100 CLK_TCK / 1s = 100%.
        allow(File).to receive(:read).with('/proc/123/stat')
                                     .and_return("123 (Web Content) S 1 1 1 0 -1 0 0 0 0 0 150 250 0 0 20 0 4 0 1 1 2560 1\n")
        expect(monitor.process_stats(123)[0]).to eq('100.0')
      end

      it 'returns 0.0 CPU when time_diff is not positive' do
        time = Time.now.utc
        allow(Time).to receive(:now).and_return(time)
        monitor.process_stats(123)
        expect(monitor.process_stats(123)[0]).to eq('0.0')
      end

      it 'defaults the thread count to 1 when status lacks a Threads line' do
        allow(File).to receive(:read).with('/proc/123/status').and_return("No Threads Here\n")
        expect(monitor.process_stats(123)[3]).to eq(1)
      end

      it 'falls back to the default page size when getconf returns zero' do
        stub_getconf(page: "0\n")
        expect(monitor.process_stats(123)[1]).to eq('10.0 MB') # 2560 * 4096 = 10 MB
      end

      it 'falls back to the default page size when getconf raises' do
        allow(Open3).to receive(:capture2).with('getconf', 'PAGE_SIZE').and_raise(StandardError)
        allow(Open3).to receive(:capture2).with('getconf', 'CLK_TCK').and_return(["100\n", nil])
        expect(monitor.process_stats(123)[1]).to eq('10.0 MB')
      end
    end
  end

  describe '#count_established_connections' do
    it 'returns zero when pid is nil' do
      expect(monitor.count_established_connections(nil)).to eq(0)
    end

    it 'counts only anchored (ESTABLISHED) tokens via lsof' do
      lsof = "COMMAND PID USER FD TYPE DEVICE SIZE/OFF NODE NAME\n" \
             "ruby 123 u 4u IPv4 0t0 TCP *:8080 (ESTABLISHED)\n" \
             "ruby 123 u 5u IPv4 0t0 TCP *:9 (LISTEN)\n"
      allow(File).to receive(:directory?).with('/proc/123/fd').and_return(false)
      allow(Open3).to receive(:capture2).with('lsof', '-p', '123', '-n', '-P').and_return([lsof, nil])
      expect(monitor.count_established_connections(123)).to eq(1)
    end

    it 'counts only ESTABLISHED socket fds on Linux, intersecting net/tcp inodes' do
      allow(File).to receive(:directory?).with('/proc/123/fd').and_return(true)
      allow(File).to receive(:exist?).with('/proc/123/net/tcp').and_return(true)
      allow(File).to receive(:exist?).with('/proc/123/net/tcp6').and_return(false)
      allow(File).to receive(:readlines).with('/proc/123/net/tcp').and_return([
                                                                                "  sl local rem st ... inode\n",
                                                                                "  0: 0100007F:1F90 0100007F:C000 01 00:00 00 00 0 0 555 1\n",
                                                                                "  1: 0100007F:1F91 00000000:0000 0A 00:00 00 00 0 0 999 1\n"
                                                                              ])
      allow(Dir).to receive(:glob).with('/proc/123/fd/*')
                                  .and_return(['/proc/123/fd/1', '/proc/123/fd/2', '/proc/123/fd/3', '/proc/123/fd/4'])
      allow(File).to receive(:readlink).with('/proc/123/fd/1').and_return('socket:[555]') # established
      allow(File).to receive(:readlink).with('/proc/123/fd/2').and_return('socket:[999]') # listening
      allow(File).to receive(:readlink).with('/proc/123/fd/3').and_return(File::NULL)     # non-socket
      allow(File).to receive(:readlink).with('/proc/123/fd/4').and_raise(StandardError) # rescued -> false
      expect(monitor.count_established_connections(123)).to eq(1)
    end

    it 'rescues StandardError and returns zero' do
      allow(File).to receive(:directory?).with('/proc/123/fd').and_raise(StandardError)
      expect(monitor.count_established_connections(123)).to eq(0)
    end
  end

  describe 'cpu-history bounding' do
    it 'never grows the per-pid history beyond the cap' do
      (described_class::CPU_HISTORY_LIMIT + 50).times { |pid| monitor.send(:calculate_cpu, pid, 1.0) }
      expect(monitor.instance_variable_get(:@cpu_prev).size).to be <= described_class::CPU_HISTORY_LIMIT
    end
  end
end
