# typed: strong
# frozen_string_literal: true

# Copyright (c) 2026 Vitalii Lazebnyi

require 'open3'
require 'sorbet-runtime'
require_relative 'process_stats'

# Primary namespace for the load testing framework.
module HttpLoader
  class Harness
    # Monitors the CPU, memory and threads of running processes: from `/proc` on Linux, from `ps` elsewhere.
    class ResourceMonitor
      extend T::Sig

      # Upper bound on the per-PID CPU-history map (defensive; the harness tracks 2 PIDs).
      CPU_HISTORY_LIMIT = 128
      public_constant :CPU_HISTORY_LIMIT

      # The stats of a process the harness did not start.
      EXTERNAL = ProcessStats.new(cpu: 'EXTERNAL', memory: 'EXTERNAL', kilobytes: 0.0, threads: 0, external: true)
      public_constant :EXTERNAL

      # The stats of a process neither `/proc` nor `ps` could read.
      UNKNOWN = ProcessStats.new(cpu: 'N/A', memory: 'N/A', kilobytes: 0.0, threads: 0)
      public_constant :UNKNOWN

      # One CPU observation of a process: its cumulative jiffies and when they were read.
      class CpuSample < T::Struct
        extend T::Sig

        const :ticks, Float
        const :time, Time

        # The CPU usage between an earlier sample and this one.
        #
        # @param previous [CpuSample] the earlier sample of the same process
        # @param clock_tick [Integer] the jiffies per second (CLK_TCK)
        # @return [Float] the usage in percent, rounded to one decimal; 0.0 when no time has passed
        sig { params(previous: CpuSample, clock_tick: Integer).returns(Float) }
        def percent_since(previous, clock_tick)
          elapsed = time - previous.time
          return 0.0 if elapsed <= 0.0

          # `Numeric#round(1)` is statically typed `T.any(Integer, Float)`; the result is a Float at
          # runtime, and `T.cast` narrows it for the type checker.
          T.cast((((ticks - previous.ticks) / clock_tick) / elapsed * 100).round(1), Float)
        end
      end
      public_constant :CpuSample

      # Per-PID CPU sampling history (the previous observation of each process). A static type.
      CpuHistory = T.type_alias { T::Hash[Integer, CpuSample] }
      private_constant :CpuHistory

      # Queries an immutable `getconf` system constant, falling back on any failure (the jiffy
      # fields in `/proc/<pid>/stat` are counted in CLK_TCK ticks, so assuming a literal 100
      # scales CPU% wrongly on kernels where `CLK_TCK != 100`).
      #
      # @param name [String] the getconf variable name
      # @param fallback [Integer] the value to use when getconf is unavailable or invalid
      # @return [Integer] the resolved positive integer, or the fallback
      sig { params(name: String, fallback: Integer).returns(Integer) }
      def self.getconf(name, fallback)
        out, _status = Open3.capture2('getconf', name)
        value = Integer(out, 10)
        value.positive? ? value : fallback
      rescue StandardError
        fallback
      end

      # The stats of a process from `ps`. `ps` reports `%cpu` as a decaying average over the process lifetime,
      # whereas the `/proc` path computes the usage since the previous sample, so the two CPU figures mean
      # slightly different things.
      #
      # @param pid [Integer] the process
      # @return [ProcessStats] its stats, or UNKNOWN when `ps` has no row for it
      sig { params(pid: Integer).returns(ProcessStats) }
      def self.ps_stats(pid)
        out, _status = Open3.capture2('ps', '-o', '%cpu,rss', '-p', pid.to_s)
        # A header-only (or empty) ps result has no data row, so `fetch(1)` raises and the rescue
        # below returns UNKNOWN -- no separate size guard needed.
        cpu, rss = out.lines.fetch(1).split
        ProcessStats.measured(T.must(cpu), Float(T.must(rss)), ps_threads(pid))
      rescue StandardError
        UNKNOWN
      end

      # Resolves the immutable kernel constants once (falling back on any getconf failure), so they are
      # never nil and the `/proc` paths read them straight off the instance.
      #
      # @return [void]
      sig { void }
      def initialize
        @cpu_prev = T.let({}, CpuHistory)
        @page_size = T.let(ResourceMonitor.getconf('PAGE_SIZE', 4096), Integer)
        @clock_tick = T.let(ResourceMonitor.getconf('CLK_TCK', 100), Integer)
      end

      # The current stats of a process: from `/proc` when it has them, else from `ps`.
      #
      # @param pid [Integer, nil] the process, or nil for an external one
      # @return [ProcessStats] its stats; EXTERNAL for nil
      sig { params(pid: T.nilable(Integer)).returns(ProcessStats) }
      def process_stats(pid)
        return EXTERNAL unless pid

        native_stats(pid) || ResourceMonitor.ps_stats(pid)
      end

      # The thread count of a process from `ps -M`, which prints one header row plus one row per thread.
      #
      # @param pid [Integer] the process
      # @return [Integer] the thread count (0 for an empty result), or 1 when `ps` fails
      sig { params(pid: Integer).returns(Integer) }
      def self.ps_threads(pid)
        out, _status = Open3.capture2('ps', '-M', '-p', pid.to_s)
        [out.count("\n") - 1, 0].max
      rescue StandardError
        1
      end

      private_class_method :ps_threads

      private

      # The stats of a process from `/proc`.
      #
      # @param pid [Integer] the process
      # @return [ProcessStats, nil] its stats, or nil when `/proc` has no (complete) entry for it
      sig { params(pid: Integer).returns(T.nilable(ProcessStats)) }
      def native_stats(pid)
        return unless File.exist?("/proc/#{pid}/stat") && File.exist?("/proc/#{pid}/statm")

        ProcessStats.measured(read_cpu_perc(pid).to_s, read_rss_kb(pid), read_threads(pid))
      rescue StandardError
        nil
      end

      # The resident memory of a process from `/proc/<pid>/statm` (in pages).
      #
      # @param pid [Integer] the process
      # @return [Float] the resident memory in kilobytes
      sig { params(pid: Integer).returns(Float) }
      def read_rss_kb(pid)
        rss_pages = File.read("/proc/#{pid}/statm").split.fetch(1)
        (Integer(rss_pages, 10) * @page_size) / 1024.0
      end

      # The CPU usage of a process since its previous sample, from `/proc/<pid>/stat`.
      #
      # @param pid [Integer] the process
      # @return [Float] the usage in percent
      sig { params(pid: Integer).returns(Float) }
      def read_cpu_perc(pid)
        # Field 2 (comm) is parenthesised and may itself contain spaces or parens
        # (e.g. "(Web Content)"), so a naive split shifts every later field. Split
        # after the final ')': utime and stime are then fields 11 and 12.
        fields = File.read("/proc/#{pid}/stat").rpartition(')').last.split
        calculate_cpu(pid, Float(fields.fetch(11)) + Float(fields.fetch(12)))
      end

      # The thread count of a process from `/proc/<pid>/status`.
      #
      # @param pid [Integer] the process
      # @return [Integer] the thread count, or 1 when the file has none
      sig { params(pid: Integer).returns(Integer) }
      def read_threads(pid)
        threads = File.read("/proc/#{pid}/status")[/Threads:\s+(\d+)/, 1]
        threads ? Integer(threads, 10) : 1
      end

      # Records a CPU sample of a process and computes the usage since the previous one.
      #
      # @param pid [Integer] the process
      # @param total_ticks [Float] its cumulative jiffies
      # @return [Float] the usage in percent; 0.0 on the first sample
      sig { params(pid: Integer, total_ticks: Float).returns(Float) }
      def calculate_cpu(pid, total_ticks)
        sample = CpuSample.new(ticks: total_ticks, time: Time.now)
        previous = record_cpu_sample(pid, sample)
        previous ? sample.percent_since(previous, @clock_tick) : 0.0
      end

      # Stores the latest sample of a PID and returns the previous one (or nil).
      # Bounds the history so it cannot grow without limit if the monitor is ever reused
      # across many PIDs (this app only tracks the server + client, so it never trips).
      #
      # @param pid [Integer] tracked process id
      # @param sample [CpuSample] the new sample
      # @return [CpuSample, nil] the previous sample, or nil on the first observation
      sig { params(pid: Integer, sample: CpuSample).returns(T.nilable(CpuSample)) }
      def record_cpu_sample(pid, sample)
        previous = @cpu_prev[pid]
        @cpu_prev[pid] = sample
        @cpu_prev.shift if @cpu_prev.size > CPU_HISTORY_LIMIT
        previous
      end
    end
  end
end
