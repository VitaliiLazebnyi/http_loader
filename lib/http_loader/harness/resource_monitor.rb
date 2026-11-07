# typed: strong
# frozen_string_literal: true

# Copyright (c) 2026 Vitalii Lazebnyi

require 'open3'
require 'sorbet-runtime'
require_relative 'connection_counter'

# Primary namespace for the load testing framework.
module HttpLoader
  class Harness
    # Monitors CPU, memory, and established connections for running processes.
    class ResourceMonitor
      extend T::Sig
      include ConnectionCounter

      # Upper bound on the per-PID CPU-history map (defensive; the harness tracks 2 PIDs).
      CPU_HISTORY_LIMIT = 128
      public_constant :CPU_HISTORY_LIMIT

      # One CPU observation of a process: its cumulative jiffies and when they were read.
      class CpuSample < T::Struct
        const :ticks, Float
        const :time, Time
      end
      private_constant :CpuSample

      # Per-PID CPU sampling history (the previous observation of each process). A static type.
      CpuHistory = T.type_alias { T::Hash[Integer, CpuSample] }
      private_constant :CpuHistory

      # Connects system resource metrics trackers mapping natively OS limits. The immutable kernel
      # constants are resolved once here (falling back on any getconf failure) rather than lazily,
      # so they are never nil and the `/proc` paths read them straight off the instance.
      #
      # @return [void]
      sig { void }
      def initialize
        @cpu_prev = T.let({}, CpuHistory)
        @page_size = T.let(query_getconf('PAGE_SIZE', 4096), Integer)
        @clock_tick = T.let(query_getconf('CLK_TCK', 100), Integer)
      end

      # Generates fully mapped array structure containing instantaneous memory, threads, and cpu overhead natively.
      #
      # @param pid [Integer, nil] mapped external system trace identifier
      # @return [Array<String, String, Float, Integer>] combined telemetry matrix structurally evaluating overhead
      sig { params(pid: T.nilable(Integer)).returns([String, String, Float, Integer]) }
      def process_stats(pid)
        return ['EXTERNAL', 'EXTERNAL', 0.0, 0] if pid.nil?
        return fallback_ps_stats(pid) unless File.exist?("/proc/#{pid}/stat") && File.exist?("/proc/#{pid}/statm")

        # Only the native `/proc` parse can raise (a since-exited pid, a short read); `fallback_ps_stats`
        # rescues internally, so scoping the rescue to the native path keeps the ps fallback's pid argument
        # observable rather than re-supplied by a broad method-level rescue.
        begin
          native_linux_stats(pid)
        rescue StandardError
          fallback_ps_stats(pid)
        end
      end

      private

      # Reads extremely fast native `/proc/` structures uniquely optimized against Linux kernel metrics organically.
      #
      # @param pid [Integer] targeted local subsystem identifier explicitly queried
      # @return [Array<String, String, Float, Integer>] Linux optimal explicit mapping payload explicitly formatted
      sig { params(pid: Integer).returns([String, String, Float, Integer]) }
      def native_linux_stats(pid)
        rss_kb = read_rss_kb(pid)
        cpu_perc = read_cpu_perc(pid)
        [cpu_perc.to_s, "#{(rss_kb / 1024.0).round(2)} MB", rss_kb, read_threads(pid)]
      end

      # Pulls explicit paging metric memory utilization representing unswapped allocation statically.
      #
      # @param pid [Integer] system explicit tracked application structure
      # @return [Float] calculated unbuffered resident kilobyte limits accurately
      sig { params(pid: Integer).returns(Float) }
      def read_rss_kb(pid)
        rss_field = T.must(File.read("/proc/#{pid}/statm").split[1])
        (Integer(rss_field, 10) * @page_size) / 1024.0
      end

      # Maps current elapsed execution loops into relative temporal performance representations accurately.
      #
      # @param pid [Integer] physical subsystem integer map
      # @return [Float] percentage scale explicitly normalized natively
      sig { params(pid: Integer).returns(Float) }
      def read_cpu_perc(pid)
        raw = File.read("/proc/#{pid}/stat")
        # Field 2 (comm) is parenthesised and may itself contain spaces or parens
        # (e.g. "(Web Content)"), so a naive split shifts every later field. Slice
        # after the final ')' and re-base: utime/stime become indices [11]/[12].
        tail = T.must(raw[(T.must(raw.rindex(')')) + 1)..]).split
        calculate_cpu(pid, Float(T.must(tail[11])) + Float(T.must(tail[12])))
      end

      # Scrapes raw `/proc/$PID/status` natively extracting precise context thread sizes directly via regex bindings.
      #
      # @param pid [Integer] process index executed explicitly
      # @return [Integer] count describing parallel subsystem bindings organically
      sig { params(pid: Integer).returns(Integer) }
      def read_threads(pid)
        threads = File.read("/proc/#{pid}/status")[/Threads:\s+(\d+)/, 1]
        threads ? Integer(threads, 10) : 1
      end

      # Queries an immutable `getconf` system constant, falling back on any failure (the jiffy
      # fields in `/proc/<pid>/stat` are counted in CLK_TCK ticks, so assuming a literal 100
      # scales CPU% wrongly on kernels where `CLK_TCK != 100`).
      #
      # @param name [String] the getconf variable name
      # @param fallback [Integer] the value to use when getconf is unavailable or invalid
      # @return [Integer] the resolved positive integer, or the fallback
      sig { params(name: String, fallback: Integer).returns(Integer) }
      def query_getconf(name, fallback)
        out, _s = Open3.capture2('getconf', name)
        value = Integer(out, 10)
        value.positive? ? value : fallback
      rescue StandardError
        fallback
      end

      # Performs numerical differentials tracking performance deviations over discrete timelines.
      #
      # @param pid [Integer] specific tracked executable index bound to the process.
      # @param total_ticks [Float] sum evaluation counting unscaled processing metric counts effectively
      # @return [Float] finalized percentage representing consumption exactly.
      sig { params(pid: Integer, total_ticks: Float).returns(Float) }
      def calculate_cpu(pid, total_ticks)
        now = Time.now
        prev = record_cpu_sample(pid, total_ticks, now)
        return 0.0 unless prev

        time_diff = now - prev.time
        return 0.0 if time_diff <= 0.0

        # `Numeric#round(1)` is statically typed `T.any(Integer, Float)`; the result is a Float at
        # runtime but the type checker needs narrowing. Binding the formula to a local keeps every
        # arithmetic mutation observable, then `T.cast` narrows the return (its runtime-noop coercion
        # is covered by the documented `cast` ignore rather than a coercion mutant can silently drop).
        pct = (((total_ticks - prev.ticks) / @clock_tick) / time_diff * 100).round(1)
        T.cast(pct, Float)
      end

      # Stores the latest tick/time sample for a PID and returns the previous one (or nil).
      # Bounds the history so it cannot grow without limit if the monitor is ever reused
      # across many PIDs (this app only tracks the server + client, so it never trips).
      #
      # @param pid [Integer] tracked process id
      # @param total_ticks [Float] current cumulative jiffies
      # @param now [Time] sample timestamp
      # @return [CpuSample, nil] the previous sample, or nil on the first observation
      sig { params(pid: Integer, total_ticks: Float, now: Time).returns(T.nilable(CpuSample)) }
      def record_cpu_sample(pid, total_ticks, now)
        prev = @cpu_prev[pid]
        @cpu_prev[pid] = CpuSample.new(ticks: total_ticks, time: now)
        @cpu_prev.shift if @cpu_prev.size > CPU_HISTORY_LIMIT
        prev
      end

      # Evaluates older fallback UNIX command line execution structures safely yielding basic analysis outputs.
      #
      # @param pid [Integer] tracked internal map universally evaluated.
      # @return [Array<String, String, Float, Integer>] subset output simulating mapped natively structures dynamically.
      # NOTE: `ps` reports `%cpu` as a decaying recent average over the process lifetime,
      # whereas the /proc path computes an instantaneous delta between ticks. The two CPU
      # figures therefore mean slightly different things across platforms.
      sig { params(pid: Integer).returns([String, String, Float, Integer]) }
      def fallback_ps_stats(pid)
        out, _s = Open3.capture2('ps', '-o', '%cpu,rss', '-p', pid.to_s)
        # A header-only (or empty) ps result has no data row, so `fetch(1)` raises and the rescue
        # below returns the N/A tuple -- no separate size guard needed.
        cpu, rss_kb_str = out.lines.fetch(1).split
        rss_kb_val = Float(T.must(rss_kb_str))

        [T.must(cpu), "#{(rss_kb_val / 1024.0).round(2)} MB", rss_kb_val, fallback_threads_count(pid)]
      rescue StandardError
        ['N/A', 'N/A', 0.0, 0]
      end

      # Inspects process lists securely filtering exact instances cleanly.
      #
      # @param pid [Integer] target
      # @return [Integer] thread size safely
      sig { params(pid: Integer).returns(Integer) }
      def fallback_threads_count(pid)
        out, _s = Open3.capture2('ps', '-M', '-p', pid.to_s)
        # `ps -M` prints one newline-terminated header row plus one row per thread, so the newline
        # count is (threads + 1); subtract the header and floor at zero for an empty result. Counting
        # newlines (rather than `strip.split("\n")`) avoids a leading/trailing-whitespace-sensitive
        # parse whose result `split("\n")` would collapse identically anyway.
        [out.count("\n") - 1, 0].max
      rescue StandardError
        1
      end
    end
  end
end
