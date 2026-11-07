# typed: strong
# frozen_string_literal: true

# Copyright (c) 2026 Vitalii Lazebnyi

require 'ipaddr'
require 'rbconfig'
require 'shellwords'
require 'socket'
require 'sorbet-runtime'
require_relative 'process_control'

# Primary namespace for the load testing framework.
module HttpLoader
  class Harness
    # Manages child process lifecycles natively and checks status dynamically.
    class ProcessManager
      extend T::Sig

      # Absolute path to the CLI entrypoint, resolved independently of the current
      # working directory so the harness works when invoked from anywhere.
      BIN_PATH = T.let(File.expand_path('../../../bin/http_loader', __dir__), String)
      public_constant :BIN_PATH

      # Seconds between two probes of the spawned server's port.
      SERVER_POLL_INTERVAL = 0.1
      private_constant :SERVER_POLL_INTERVAL

      # How many times to probe the spawned server's port before giving up (after 15 seconds).
      SERVER_POLLS = 150
      private_constant :SERVER_POLLS

      # The IPv4 loopback address (INADDR_LOOPBACK) the readiness probe connects to.
      LOOPBACK = T.let(IPAddr.new(Socket::INADDR_LOOPBACK, Socket::AF_INET).to_s, String)
      private_constant :LOOPBACK

      # Map of spawned child role (:server / :client) to its OS pid. A static type.
      Pids = T.type_alias { T::Hash[Symbol, Integer] }
      private_constant :Pids

      # Probes a local TCP port; a successful accept is a valid readiness proxy even for HTTPS.
      #
      # @param port [Integer] the port to probe
      # @return [Boolean] true if a TCP connection succeeds
      sig { params(port: Integer).returns(T::Boolean) }
      def self.port_open?(port)
        TCPSocket.new(LOOPBACK, port).close
        true
      rescue StandardError
        false
      end

      # Whether a started process has exited.
      #
      # @param pid [Integer, nil] the process, or nil when it was not started
      # @return [Boolean] true for a started process that is gone
      sig { params(pid: T.nilable(Integer)).returns(T::Boolean) }
      def self.dead?(pid)
        pid ? ProcessControl.dead?(pid) : false
      end

      # Allocates a new supervisor manager evaluating local child architectures natively. The spawned
      # child pids live in a single map (empty until a child is spawned) rather than two nil ivars, so
      # the initial "no pid yet" state is the absence of a key rather than a typed-nil literal.
      #
      # @param config [HttpLoader::Harness::Config] strongly typed harness runtime configurations
      # @return [void]
      sig { params(config: HttpLoader::Harness::Config).void }
      def initialize(config)
        @config = config
        @pids = T.let({}, Pids)
        @log_dir = T.let(File.expand_path('../../../logs', __dir__), String)
      end

      # The spawned server's pid, or nil before the server is spawned.
      #
      # @return [Integer, nil] the server child pid
      sig { returns(T.nilable(Integer)) }
      def server_pid
        @pids[:server]
      end

      # The spawned client's pid, or nil before the client is spawned.
      #
      # @return [Integer, nil] the client child pid
      sig { returns(T.nilable(Integer)) }
      def client_pid
        @pids[:client]
      end

      # Unilaterally forks background OS processes wiring explicit file descriptor capture bounds natively.
      #
      # @return [void]
      sig { void }
      def spawn_processes
        FileUtils.mkdir_p(@log_dir)
        spawn_server if @config.target_urls.none?
        spawn_client
      end

      # Sweeps and securely terminates attached children, escalating SIGINT -> SIGKILL
      # and reaping each child so no zombies or leaked sockets/threads survive the harness.
      #
      # @return [void]
      sig { void }
      def cleanup
        ProcessControl.terminate(server_pid)
        ProcessControl.terminate(client_pid)
      end

      # Resolves active PID statuses ensuring both mapped logic ends remain alive actively.
      #
      # @return [Boolean] true flag implying fatal termination of tracked underlying routines
      sig { returns(T::Boolean) }
      def missing_process?
        [client_pid, server_pid].any? { |pid| ProcessManager.dead?(pid) }
      end

      private

      # Triggers Ruby's async native wrapper bindings spawning local HTTP1 endpoints natively via falcon bounds.
      #
      # @return [void]
      sig { void }
      def spawn_server
        args = ['server']
        args << '--https' if @config.use_https
        @pids[:server] = spawn_child(args, 'server.log', 'server.err')
        puts("[Harness] Started server with PID #{server_pid}")
        wait_for_server
      end

      # Synthesizes child client threads pushing dynamic option mapping strictly. The client's
      # own Logger owns `client.log`/`client.err`; the child's raw stdout/stderr are captured
      # into separate files so no two file descriptors race over the same log.
      #
      # @return [void]
      sig { void }
      def spawn_client
        client_args = @config.client_args
        extra = client_args.empty? ? ["--connections_count=#{@config.connections}"] : client_args
        @pids[:client] = spawn_child(['client'] + extra, 'client.stdout.log', 'client.stderr.log')
        puts("[Harness] Started client with PID #{client_pid}")
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
        return if server_ready?(port)

        timeout = SERVER_POLLS * SERVER_POLL_INTERVAL
        warn("[Harness] Warning: server did not become ready on port #{port} within #{timeout}s.")
      end

      # Polls the server's port every SERVER_POLL_INTERVAL, SERVER_POLLS times.
      #
      # @param port [Integer] the port of the server
      # @return [Boolean] true once the port accepts a connection; false on the timeout or the server's exit
      sig { params(port: Integer).returns(T::Boolean) }
      def server_ready?(port)
        SERVER_POLLS.times do
          return true if ProcessManager.port_open?(port)
          return false if ProcessManager.dead?(server_pid)

          sleep(SERVER_POLL_INTERVAL)
        end
        false
      end
    end
  end
end
