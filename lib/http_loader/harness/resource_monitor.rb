# typed: strong
# frozen_string_literal: true

require 'sorbet-runtime'
require 'open3'

# Primary namespace for the load testing framework.
module HttpLoader
  class Harness
    # Monitors CPU, memory, and established connections for running processes.
    class ResourceMonitor
      extend T::Sig

      # Upper bound on the per-PID CPU-history map (defensive; the harness tracks 2 PIDs).
      CPU_HISTORY_LIMIT = 128

      # Connects system resource metrics trackers mapping natively OS limits.
      #
      # @return [void]
      sig { void }
      def initialize
        @cpu_prev = T.let({}, T::Hash[Integer, T::Hash[Symbol, T.untyped]])
        @page_size = T.let(nil, T.nilable(Integer))
        @clock_tick = T.let(nil, T.nilable(Integer))
      end

      # Generates fully mapped array structure containing instantaneous memory, threads, and cpu overhead natively.
      #
      # @param pid [Integer, nil] mapped external system trace identifier
      # @return [Array<String, String, Float, Integer>] combined telemetry matrix structurally evaluating overhead
      sig { params(pid: T.nilable(Integer)).returns([String, String, Float, Integer]) }
      def process_stats(pid)
        return ['EXTERNAL', 'EXTERNAL', 0.0, 0] if pid.nil?

        if File.exist?("/proc/#{pid}/stat") && File.exist?("/proc/#{pid}/statm")
          native_linux_stats(pid)
        else
          fallback_ps_stats(pid)
        end
      rescue StandardError
        fallback_ps_stats(T.must(pid))
      end

      # Aggregates physical network sockets representing valid ESTABLISHED system patterns cleanly without collision.
      #
      # @param pid [Integer, nil] OS map matching tracking subsystem explicitly
      # @return [Integer] sum total connected target bound structures natively
      sig { params(pid: T.nilable(Integer)).returns(Integer) }
      def count_established_connections(pid)
        return 0 if pid.nil?

        if File.directory?("/proc/#{pid}/fd")
          count_linux_connections(pid)
        else
          count_lsof_connections(pid)
        end
      rescue StandardError
        0
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
        rss_pages = T.must(File.read("/proc/#{pid}/statm").split[1]).to_i
        (rss_pages * page_size) / 1024.0
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
        calculate_cpu(pid, T.must(tail[11]).to_f + T.must(tail[12]).to_f)
      end

      # Scrapes raw `/proc/$PID/status` natively extracting precise context thread sizes directly via regex bindings.
      #
      # @param pid [Integer] process index executed explicitly
      # @return [Integer] count describing parallel subsystem bindings organically
      sig { params(pid: Integer).returns(Integer) }
      def read_threads(pid)
        File.read("/proc/#{pid}/status").match(/Threads:\s+(\d+)/)&.[](1)&.to_i || 1
      end

      # Discovers OS bound kernel limits specifically regarding internal RAM memory boundary allocations universally.
      #
      # @return [Integer] memory integer sizing parameter bound physically
      sig { returns(Integer) }
      def page_size
        @page_size ||= query_getconf('PAGE_SIZE', 4096)
      end

      # Resolves the kernel clock tick (`sysconf(_SC_CLK_TCK)`) once, memoizing the
      # immutable value. The `/proc/<pid>/stat` jiffy fields are counted in these ticks,
      # so assuming a literal 100 mis-scales CPU% on kernels where `CLK_TCK != 100`.
      #
      # @return [Integer] the number of clock ticks per second (fallback 100)
      sig { returns(Integer) }
      def clock_tick
        @clock_tick ||= query_getconf('CLK_TCK', 100)
      end

      # Queries an immutable `getconf` system constant, falling back on any failure.
      #
      # @param name [String] the getconf variable name
      # @param fallback [Integer] the value to use when getconf is unavailable or invalid
      # @return [Integer] the resolved positive integer, or the fallback
      sig { params(name: String, fallback: Integer).returns(Integer) }
      def query_getconf(name, fallback)
        out, _s = Open3.capture2('getconf', name)
        out.to_i.positive? ? out.to_i : fallback
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
        now = Time.now.utc
        prev = record_cpu_sample(pid, total_ticks, now)
        return 0.0 unless prev

        time_diff = now - T.cast(prev[:time], Time)
        return 0.0 unless time_diff > 0.0

        (((total_ticks - T.cast(prev[:ticks], Float)) / clock_tick) / time_diff * 100).round(1).to_f
      end

      # Stores the latest tick/time sample for a PID and returns the previous one (or nil).
      # Bounds the history so it cannot grow without limit if the monitor is ever reused
      # across many PIDs (this app only tracks the server + client, so it never trips).
      #
      # @param pid [Integer] tracked process id
      # @param total_ticks [Float] current cumulative jiffies
      # @param now [Time] sample timestamp
      # @return [Hash, nil] the previous sample, or nil on the first observation
      sig { params(pid: Integer, total_ticks: Float, now: Time).returns(T.nilable(T::Hash[Symbol, T.untyped])) }
      def record_cpu_sample(pid, total_ticks, now)
        prev = @cpu_prev[pid]
        @cpu_prev[pid] = { ticks: total_ticks, time: now }
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
        lines = out.strip.split("\n")
        return ['N/A', 'N/A', 0.0, 0] if lines.size < 2

        cpu, rss_kb_str = T.must(lines[1]).strip.split(/\s+/)
        rss_kb_val = T.must(rss_kb_str).to_f

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
        [out.strip.split("\n").size - 1, 0].max
      rescue StandardError
        1
      end

      # Counts only ESTABLISHED TCP sockets on Linux, matching the macOS `lsof` path.
      # A bare `socket:[` prefix would over-count listening/UNIX/UDP sockets, so we
      # intersect the process's socket fds with the inodes of ESTABLISHED entries in
      # `/proc/<pid>/net/tcp[6]` (state `01`).
      #
      # @param pid [Integer] physical identifier dynamically mapped logically
      # @return [Integer] count of established TCP connections
      sig { params(pid: Integer).returns(Integer) }
      def count_linux_connections(pid)
        established = established_inodes(pid)
        Dir.glob("/proc/#{pid}/fd/*").count do |fd_path|
          match = File.readlink(fd_path).match(/\Asocket:\[(\d+)\]\z/)
          match ? established.include?(T.must(match[1])) : false
        rescue StandardError
          false
        end
      end

      # Collects the socket inodes of ESTABLISHED TCP (IPv4 + IPv6) connections owned
      # by the process, parsed from `/proc/<pid>/net/tcp` and `net/tcp6`.
      #
      # @param pid [Integer] tracked process identifier
      # @return [Array<String>] inode strings of ESTABLISHED sockets
      sig { params(pid: Integer).returns(T::Array[String]) }
      def established_inodes(pid)
        %w[tcp tcp6].flat_map do |proto|
          path = "/proc/#{pid}/net/#{proto}"
          next [] unless File.exist?(path)

          File.readlines(path).drop(1).filter_map do |line|
            cols = line.split
            cols[9] if cols[3] == '01'
          end
        end
      end

      # Leverages legacy UNIX tooling safely generating mapped logic structures universally.
      #
      # @param pid [Integer] ID
      # @return [Integer] connections count actively evaluated
      sig { params(pid: Integer).returns(Integer) }
      def count_lsof_connections(pid)
        out, _s = Open3.capture2('lsof', '-p', pid.to_s, '-n', '-P')
        out.scan('(ESTABLISHED)').count
      end
    end
  end
end
