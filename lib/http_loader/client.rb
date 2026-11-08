# typed: strong
# frozen_string_literal: true

# Copyright (c) 2026 Vitalii Lazebnyi

require 'async'
require 'async/semaphore'
require 'net/http'
require 'openssl'
require 'sorbet-runtime'
require 'time'
require 'uri'
require_relative 'client/config'
require_relative 'client/connection'
require_relative 'client/error_handler'
require_relative 'client/http_session'
require_relative 'client/logger'
require_relative 'client/pacing'
require_relative 'client/slowloris'
require_relative 'client/target_manager'
require_relative 'file_limits'

# Primary namespace for the load testing framework.
module HttpLoader
  # Master client class coordinating connection pools through Async Engine.
  class Client
    extend T::Sig
    include ErrorHandler

    # The protocol a connection speaks once open. A static type, checked by `srb tc`.
    Session = T.type_alias { T.any(HttpSession, Slowloris) }
    private_constant :Session

    sig { returns(HttpLoader::Client::Logger) }
    attr_reader :logger

    # Opens a Net::HTTP connection and yields it.
    #
    # @param uri [URI::Generic] the target
    # @param opts [Hash{Symbol => Object}] the Net::HTTP start options
    # @param block [Proc] receives the open connection
    # @return [void]
    sig { params(uri: URI::Generic, opts: TargetManager::HttpArgs, block: T.proc.params(arg: Net::HTTP).void).void }
    def self.start_http(uri, opts, &block)
      Net::HTTP.start(T.must(uri.host), uri.port, **opts, &block)
    end

    # Initializes a new Client instance.
    #
    # @param config [Config] the strongly typed configuration object
    # @return [void]
    sig { params(config: Config).void }
    def initialize(config)
      config.validate
      @config = config
      @logger = T.let(Logger.new(config.verbose), Logger)
      @target_manager = T.let(TargetManager.new(config), TargetManager)
      @session = T.let(
        config.slowloris_delay > 0.0 ? Slowloris.new(config, @logger) : HttpSession.new(config, @logger),
        Session
      )
    end

    # Starts the load generation engine and applies trap handlers.
    #
    # @return [void]
    sig { void }
    def start
      prepare
      Async { |raw_task| run_engine(T.cast(raw_task, Async::Task)) }
    ensure
      @logger.flush
    end

    private

    # Announces the run, makes Ctrl+C exit, raises the open file limit and empties the log files.
    #
    # @return [void]
    sig { void }
    def prepare
      log_startup_message
      trap('INT') { exit(0) }
      FileLimits.bump!(@config.connections + 1024, label: '[Client]')
      @logger.prepare_files
    end

    # Runs the asynchronous task engine spawning connections.
    #
    # @param task [Async::Task] the async orchestration task
    # @return [void]
    sig { params(task: Async::Task).void }
    def run_engine(task)
      logger_task = @logger.run_task(task)
      spawn_connections(Async::Semaphore.new(@config.max_concurrent_connections, parent: task)).each(&:wait)
      logger_task.stop
    end

    # Spawns one worker task per connection, through the concurrency semaphore, pausing between them by the
    # ramp-up interval. Inside the Async reactor `Kernel#sleep` is fiber-aware (it suspends this fiber and
    # yields to the scheduler), so it paces the ramp without blocking the reactor.
    #
    # @param semaphore [Async::Semaphore] the concurrency cap
    # @return [Array<Async::Task>] the worker tasks
    sig { params(semaphore: Async::Semaphore).returns(T::Array[Async::Task]) }
    def spawn_connections(semaphore)
      ramp = calc_ramp
      Array.new(@config.connections) do |index|
        sleep(ramp) if index.positive? && ramp > 0.0
        semaphore.async { exec_conn(index) }
      end
    end

    # Prints the initialization banner to stdout.
    #
    # @return [void]
    sig { void }
    def log_startup_message
      summary = "#{@config.connections} #{@target_manager.protocol_label} connections"
      @logger.info("Starting #{summary}")
      puts("[Client] Starting #{summary} to targeted urls...")
      puts('[Client] Note: Output of individual pings is suppressed.') unless @config.verbose
    end

    # Calculates the sleep duration required for ramp-up. When both `--ramp_up` and
    # `--connections_per_second` are set, `--ramp_up` takes precedence.
    #
    # @return [Float] the calculated ramp sleep duration
    sig { returns(Float) }
    def calc_ramp
      ramp_up = @config.ramp_up
      rate = @config.connections_per_second
      return ramp_up / @config.connections if ramp_up > 0.0

      rate.positive? ? 1.0 / rate : 0.0
    end

    # Continuously attempts connection runs per fiber worker.
    #
    # @param idx [Integer] the connection identifier
    # @return [void]
    sig { params(idx: Integer).void }
    def exec_conn(idx)
      loop do
        run_session(idx, Time.now)
        break unless @config.reopen_closed_connections

        sleep(Pacing.jittered_interval(@config.reopen_interval, @config.jitter))
      end
    end

    # Runs one connection of a worker, from opening to closing, logging any error.
    #
    # @param idx [Integer] the connection identifier
    # @param started [Time] when the connection is opened
    # @return [void]
    sig { params(idx: Integer, started: Time).void }
    def run_session(idx, started)
      connect(idx, @target_manager.context_for(idx), started)
      @logger.info("[Client #{idx}] Connection gracefully closed.")
    rescue StandardError => error
      handle_err(idx, error)
    end

    # Opens the connection to the worker's target and runs the session on it.
    #
    # @param idx [Integer] the connection identifier
    # @param target [TargetManager::Target] the endpoint the connection goes to
    # @param started [Time] when the connection is opened
    # @return [void]
    sig { params(idx: Integer, target: TargetManager::Target, started: Time).void }
    def connect(idx, target, started)
      uri = target.uri
      Client.start_http(uri, @target_manager.http_opts_for(idx, target.http_args)) do |http|
        @logger.info("[Client #{idx}] Connection established to #{uri.host}.")
        @session.run(Connection.new(index: idx, uri: uri, http: http, started: started))
      end
    end
  end
end
