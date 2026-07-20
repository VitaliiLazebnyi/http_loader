# typed: strong
# frozen_string_literal: true

require 'sorbet-runtime'
require 'rbconfig'
require 'socket'
require 'shellwords'

# Primary namespace for the load testing framework.
module HttpLoader
  class Harness
    # Manages child process lifecycles natively and checks status dynamically.
    class ProcessManager
      extend T::Sig

      # Absolute path to the CLI entrypoint, resolved independently of the current
      # working directory so the harness works when invoked from anywhere.
      BIN_PATH = T.let(File.expand_path('../../../bin/http_loader', __dir__), String)

      # Seconds to wait for the spawned server to accept TCP connections before giving up.
      SERVER_BOOT_TIMEOUT = 15.0

      sig { returns(T.nilable(Integer)) }
      attr_reader :server_pid, :client_pid

      # Allocates a new supervisor manager evaluating local child architectures natively.
      #
      # @param config [HttpLoader::Harness::Config] strongly typed harness runtime configurations
      # @return [void]
      sig { params(config: HttpLoader::Harness::Config).void }
      def initialize(config)
        @config = config
        @server_pid = T.let(nil, T.nilable(Integer))
        @client_pid = T.let(nil, T.nilable(Integer))
        @log_dir = T.let(File.expand_path('../../../logs', __dir__), String)
      end

      # Unilaterally forks background OS processes wiring explicit file descriptor capture bounds natively.
      #
      # @return [void]
      sig { void }
      def spawn_processes
        FileUtils.mkdir_p(@log_dir)
        spawn_server unless @config.target_urls.any?
        spawn_client
      end

      # Sweeps and securely terminates attached children, escalating SIGINT -> SIGKILL
      # and reaping each child so no zombies or leaked sockets/threads survive the harness.
      #
      # @return [void]
      sig { void }
      def cleanup
        terminate(@server_pid)
        terminate(@client_pid)
      end

      # Resolves active PID statuses ensuring both mapped logic ends remain alive actively.
      #
      # @return [Boolean] true flag implying fatal termination of tracked underlying routines
      sig { returns(T::Boolean) }
      def missing_process?
        return true if @client_pid && dead?(@client_pid)
        return true if @server_pid && dead?(@server_pid)

        false
      end

      private

      # Escalating, reaping terminator for a single child PID.
      #
      # @param pid [Integer, nil] the target process id
      # @return [void]
      sig { params(pid: T.nilable(Integer)).void }
      def terminate(pid)
        return unless pid

        signal_quietly('INT', pid)
        return if reaped?(pid, deadline: 3.0)

        signal_quietly('KILL', pid)
        reaped?(pid, deadline: 2.0)
      end

      # Polls `waitpid(WNOHANG)` until the child is reaped or the deadline passes.
      #
      # @param pid [Integer] the process id
      # @param deadline [Float] seconds to wait
      # @return [Boolean] true if the child was reaped
      sig { params(pid: Integer, deadline: Float).returns(T::Boolean) }
      def reaped?(pid, deadline:)
        stop_at = Time.now + deadline
        while Time.now < stop_at
          return true if Process.waitpid(pid, Process::WNOHANG)

          sleep(0.05)
        end
        false
      rescue Errno::ECHILD, Errno::ESRCH
        true
      end

      # Sends a signal, swallowing "already gone" errors.
      #
      # @param sig [String] the signal name
      # @param pid [Integer] the target process id
      # @return [void]
      sig { params(sig: String, pid: Integer).void }
      def signal_quietly(sig, pid)
        Process.kill(sig, pid)
      rescue StandardError
        nil
      end

      # Triggers Ruby's async native wrapper bindings spawning local HTTP1 endpoints natively via falcon bounds.
      #
      # @return [void]
      sig { void }
      def spawn_server
        args = ['server']
        args << '--https' if @config.use_https
        @server_pid = spawn_child(args, 'server.log', 'server.err')
        puts "[Harness] Started server with PID #{@server_pid}"
        wait_for_server
      end

      # Synthesizes child client threads pushing dynamic option mapping strictly. The client's
      # own Logger owns `client.log`/`client.err`; the child's raw stdout/stderr are captured
      # into separate files so no two file descriptors race over the same log.
      #
      # @return [void]
      sig { void }
      def spawn_client
        extra = @config.client_args.empty? ? ["--connections_count=#{@config.connections}"] : @config.client_args
        @client_pid = spawn_child(['client', *extra], 'client.stdout.log', 'client.stderr.log')
        puts "[Harness] Started client with PID #{@client_pid}"
      end

      # Spawns `bin/http_loader <args>` redirecting streams. The command is assembled with
      # the resolved interpreter and the absolute BIN_PATH (never a CWD-relative path), and
      # Shellwords.join safely escapes every token before the single-string spawn.
      #
      # @param args [Array<String>] subcommand and flags
      # @param out_file [String] basename for captured stdout
      # @param err_file [String] basename for captured stderr
      # @return [Integer] the spawned pid
      sig { params(args: T::Array[String], out_file: String, err_file: String).returns(Integer) }
      def spawn_child(args, out_file, err_file)
        command = Shellwords.join([RbConfig.ruby, BIN_PATH] + args)
        Process.spawn(command, out: File.join(@log_dir, out_file), err: File.join(@log_dir, err_file))
      end

      # Waits until the spawned server accepts TCP connections, replacing a fixed sleep
      # with a bounded readiness poll so the client never fires into a not-yet-bound port.
      #
      # @return [void]
      sig { void }
      def wait_for_server
        port = @config.use_https ? 8443 : 8080
        stop_at = Time.now + SERVER_BOOT_TIMEOUT
        while Time.now < stop_at
          return if port_open?(port)
          break if @server_pid && dead?(@server_pid)

          sleep(0.1)
        end
        warn "[Harness] Warning: server did not become ready on port #{port} within #{SERVER_BOOT_TIMEOUT}s."
      end

      # Probes a local TCP port; a successful accept is a valid readiness proxy even for HTTPS.
      #
      # @param port [Integer] the port to probe
      # @return [Boolean] true if a TCP connection succeeds
      sig { params(port: Integer).returns(T::Boolean) }
      def port_open?(port)
        sock = T.let(TCPSocket.new('127.0.0.1', port), TCPSocket)
        sock.close
        true
      rescue StandardError
        false
      end

      # Low-level POSIX call checking SIG status mapping logic externally.
      #
      # @param pid [Integer] system explicit PID string mapping
      # @return [Boolean] evaluation declaring mortality manually
      sig { params(pid: Integer).returns(T::Boolean) }
      def dead?(pid)
        Process.getpgid(pid)
        false
      rescue Errno::ESRCH
        true
      end
    end
  end
end
