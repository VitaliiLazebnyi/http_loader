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

      # Per-PID CPU sampling history (tick/time of the previous observation). A static type.
      CpuHistory = T.type_alias { T::Hash[Integer, T::Hash[Symbol, T.untyped]] }

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
        rss_field = T.must(File.read("/proc/#{pid}/statm").split[1])
        (rss_field.to_i * @page_size) / 1024.0
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

      # Queries an immutable `getconf` system constant, falling back on any failure (the jiffy
      # fields in `/proc/<pid>/stat` are counted in CLK_TCK ticks, so assuming a literal 100
      # mis-scales CPU% on kernels where `CLK_TCK != 100`).
      #
      # @param name [String] the getconf variable name
      # @param fallback [Integer] the value to use when getconf is unavailable or invalid
      # @return [Integer] the resolved positive integer, or the fallback
      sig { params(name: String, fallback: Integer).returns(Integer) }
      def query_getconf(name, fallback)
        out, _s = Open3.capture2('getconf', name)
        value = out.to_i
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

        time_diff = now - T.cast(prev[:time], Time)
        return 0.0 unless time_diff > 0.0

        # `Numeric#round(1)` is statically typed `T.any(Integer, Float)`; the result is a Float at
        # runtime but the type checker needs narrowing. Binding the formula to a local keeps every
        # arithmetic mutation observable, then `T.cast` narrows the return (its runtime-noop coercion
        # is covered by the documented `cast` ignore rather than a coercion mutant can silently drop).
        pct = (((total_ticks - T.cast(prev[:ticks], Float)) / @clock_tick) / time_diff * 100).round(1)
        T.cast(pct, Float)
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
        # A header-only (or empty) ps result has no data row, so `fetch(1)` raises and the rescue
        # below returns the N/A tuple -- no separate size guard needed.
        cpu, rss_kb_str = out.lines.fetch(1).split
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
        # `ps -M` prints one newline-terminated header row plus one row per thread, so the newline
        # count is (threads + 1); subtract the header and floor at zero for an empty result. Counting
        # newlines (rather than `strip.split("\n")`) avoids a leading/trailing-whitespace-sensitive
        # parse whose result `split("\n")` would collapse identically anyway.
        [out.count("\n") - 1, 0].max
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
        fd_socket_inodes(pid).count { |inode| established.include?(inode) }
      end

      # Resolves every file descriptor of the process to its socket inode, dropping descriptors
      # that are not sockets (and any that vanish mid-walk: a readlink on a since-closed fd raises
      # and is skipped rather than aborting the whole count).
      #
      # @param pid [Integer] tracked process identifier
      # @return [Array<String>] socket inode strings for the process's socket fds
      sig { params(pid: Integer).returns(T::Array[String]) }
      def fd_socket_inodes(pid)
        Dir.glob("/proc/#{pid}/fd/*").filter_map do |fd_path|
          socket_inode(fd_path)
        rescue StandardError
          nil
        end
      end

      # Extracts the socket inode from a single `/proc/<pid>/fd/<n>` symlink target, or nil when the
      # descriptor is not a socket. The `\A...\z` anchors reject non-socket targets (pipes, files,
      # `socket:[` substrings) so only a bare `socket:[<inode>]` link yields an inode.
      #
      # @param fd_path [String] absolute path of the file-descriptor symlink
      # @return [String, nil] the socket inode, or nil when the target is not a socket link
      sig { params(fd_path: String).returns(T.nilable(String)) }
      def socket_inode(fd_path)
        File.readlink(fd_path).match(/\Asocket:\[(\d+)\]\z/)&.[](1)
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

          # The header row's state column is never '01', so it is filtered out like any other
          # non-ESTABLISHED row; no explicit header drop is needed. Each data row has >= 10
          # whitespace fields, so `fetch` is total.
          File.readlines(path).filter_map do |line|
            cols = line.split
            cols.fetch(9) if cols.fetch(3) == '01'
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
        out.lines.count { |line| line.include?('(ESTABLISHED)') }
      end
    end
  end
end
