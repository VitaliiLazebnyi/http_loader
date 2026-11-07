# typed: strong
# frozen_string_literal: true

# Copyright (c) 2026 Vitalii Lazebnyi

require 'fileutils'
require 'sorbet-runtime'
require 'stringio'
require_relative 'file_limits'
require_relative 'harness/config'
require_relative 'harness/formatter'
require_relative 'harness/process_manager'
require_relative 'harness/resource_monitor'
require_relative 'harness/telemetry'

# Primary namespace for the load testing framework.
module HttpLoader
  # Harness orchestrates the entire load testing lifecycle seamlessly and securely.
  class Harness
    extend T::Sig
    include Formatter

    sig { returns(Config) }
    attr_reader :config

    sig { returns(ProcessManager) }
    attr_reader :pm

    sig { returns(ResourceMonitor) }
    attr_reader :monitor

    # Instantiates the orchestration layer configuring monitoring, telemetry, and processes.
    #
    # @param config [Config] orchestration parameters resolving telemetry
    # @return [void]
    sig { params(config: Config).void }
    def initialize(config)
      config.validate
      @config = config
      @telemetry = T.let(Telemetry.new(File.expand_path('../../logs', __dir__), config.export_json), Telemetry)
      @pm = T.let(ProcessManager.new(config), ProcessManager)
      @monitor = T.let(ResourceMonitor.new, ResourceMonitor)
    end

    # Bootstraps the harness pipeline, overrides OS limits natively, and binds interrupts.
    #
    # @return [void]
    sig { void }
    def start
      T.let($stdout, T.any(IO, StringIO)).sync = true
      print_startup_banner
      FileLimits.bump!(@config.connections + 1024, label: '[Harness]')
      run_lifecycle
    end

    private

    # Spawns the processes and monitors them until the run ends, then exports the report and stops them. The
    # interrupt handler is installed before spawning, so an early Ctrl+C still cleans up; cleanup is a guarded
    # no-op while the child PIDs are still unset.
    #
    # @return [void]
    sig { void }
    def run_lifecycle
      trap('INT') { interrupt }
      @pm.spawn_processes
      monitor_resources
    ensure
      @telemetry.export
      @pm.cleanup
    end

    # Stops the processes and exits, on Ctrl+C.
    #
    # @return [void]
    sig { void }
    def interrupt
      puts("\n[Harness] Caught interrupt, cleaning up processes...")
      @pm.cleanup
      exit(0)
    end

    # Prints a row of the metrics table every two seconds until the target duration is reached or a process
    # is missing.
    #
    # @return [void]
    sig { void }
    def monitor_resources
      print_table_header
      @telemetry.restart
      until duration_exceeded? || tick_failed?
        @telemetry.report_bottlenecks
        sleep(2)
      end
    end

    # Validates if the optional global timer constraint has elapsed terminating orchestrator naturally.
    #
    # @return [Boolean] evaluation if runtime duration has violated constraints
    sig { returns(T::Boolean) }
    def duration_exceeded?
      target = @config.target_duration
      return false if target <= 0.0 || @telemetry.elapsed < target

      puts("[Harness] Target duration mathematically reached (#{target}s). auto-shutdown.")
      true
    end

    # Samples the client and prints a row of the metrics table, unless a socket or a process is missing.
    #
    # @return [Boolean] true implying fatal failure requiring immediate test abort
    sig { returns(T::Boolean) }
    def tick_failed?
      active, client = extract_client_stats
      @telemetry.observe(active)
      return true if missing_socket?(active, client) || @pm.missing_process?

      print_combined_stats(active, client)
      false
    end

    # Whether every connection to the external targets dropped after some were established: the row then
    # shows the external server as gone.
    #
    # @param active [Integer] the established connections of the client
    # @param client [ProcessStats] the stats of the client
    # @return [Boolean] true when the external server disconnected
    sig { params(active: Integer, client: ProcessStats).returns(T::Boolean) }
    def missing_socket?(active, client)
      return false if @config.target_urls.none? || @telemetry.peak_connections.zero? || active.nonzero?

      log_table_row([Formatter.clock, active, 'EXTERNAL', 'N/A', 'N/A', "#{client.load}T", client.memory, 'N/A'])
      puts("\n[Harness] \u26A0\uFE0F EXTERNAL SERVER DISCONNECTED!")
      true
    end
  end
end
