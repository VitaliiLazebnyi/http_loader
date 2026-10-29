# typed: strong
# frozen_string_literal: true

require 'sorbet-runtime'
require 'fileutils'
require_relative 'file_limits'
require_relative 'harness/config'
require_relative 'harness/resource_monitor'
require_relative 'harness/telemetry'
require_relative 'harness/process_manager'
require_relative 'harness/formatter'

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
      config.validate!
      @config = config
      # Only elapsed-second deltas are taken from @start_time (here, in the monitor loop, and in
      # telemetry), and `Time#-` is instant-based, so the Time's zone never surfaces -- no `.utc`.
      @start_time = T.let(Time.now, Time)
      @peak_connections = T.let(0, Integer)
      log_dir = T.let(File.expand_path('../../logs', __dir__), String)
      @telemetry = T.let(Telemetry.new(log_dir, config.export_json), Telemetry)
      @pm = T.let(ProcessManager.new(config), ProcessManager)
      @monitor = T.let(ResourceMonitor.new, ResourceMonitor)
    end

    # Bootstraps the harness pipeline, overrides OS limits natively, and binds interrupts.
    #
    # @return [void]
    sig { void }
    def start
      T.cast($stdout, IO).sync = true
      print_startup_banner
      bump_file_limits

      run_lifecycle
    end

    private

    # Orchestrates process lifecycle, binding trap behaviors, and triggers active resource monitoring.
    #
    # @return [void]
    sig { void }
    def run_lifecycle
      # Install the trap before spawning so an early Ctrl+C still runs cleanup;
      # cleanup is a guarded no-op while the child PIDs are still unset.
      trap('INT') do
        puts "\n[Harness] Caught interrupt, cleaning up processes..."
        @pm.cleanup
        exit(0)
      end
      @pm.spawn_processes
      monitor_resources
    ensure
      @telemetry.export!(@peak_connections, @start_time)
      @pm.cleanup
    end

    # Blocks the main execution thread actively querying and evaluating subsystem statuses periodically.
    #
    # @return [void]
    sig { void }
    def monitor_resources
      print_table_header
      @start_time = Time.now

      loop do
        break if duration_exceeded?

        tick_result = tick_failed?
        break if tick_result

        @telemetry.check_bottlenecks!
        sleep(2)
      end
    end

    # Validates if the optional global timer constraint has elapsed terminating orchestrator naturally.
    #
    # @return [Boolean] evaluation if runtime duration has violated constraints
    sig { returns(T::Boolean) }
    def duration_exceeded?
      target = @config.target_duration
      elapsed = Time.now - @start_time # Time#- already yields Float seconds (instant-based)
      return false unless target > 0.0 && elapsed >= target

      puts "[Harness] Target duration mathematically reached (#{target}s). auto-shutdown."
      true
    end

    # Evaluates the instantaneous point-in-time statistical frame against failure parameters.
    #
    # @return [Boolean] true implying fatal failure requiring immediate test abort
    sig { returns(T::Boolean) }
    def tick_failed?
      active_c, c_cpu, c_th, c_m = extract_client_stats
      @peak_connections = [@peak_connections, active_c].max

      return true if missing_socket?(active_c, c_cpu, c_th, c_m)
      return true if @pm.missing_process?

      print_combined_stats(active_c, c_cpu, c_th, c_m)
      false
    end

    # Hooks deeply into OS boundaries augmenting `ulimit -n` metrics facilitating bulk HTTP pipelines.
    #
    # @return [void]
    sig { void }
    def bump_file_limits
      FileLimits.bump!(@config.connections + 1024, label: '[Harness]')
    end

    # Diagnostically evaluates sudden connection termination from upstream server endpoints natively.
    #
    # @param active [Integer] active instantaneous sockets
    # @param c_cpu [String] formatted client cpu util
    # @param c_th [Integer] aggregated client thread pools count
    # @param c_m [String] string formatted consumed heap
    # @return [Boolean] flags if logical expectations are broken natively
    sig { params(active: Integer, c_cpu: String, c_th: Integer, c_m: String).returns(T::Boolean) }
    def missing_socket?(active, c_cpu, c_th, c_m)
      return false unless @config.target_urls.any? && @peak_connections > 0.0 && active.zero?

      log_table_row(
        t: Time.now.utc.strftime('%H:%M:%S'), ac: active, sc: 'EXTERNAL', sm: 'N/A',
        sk: 'N/A', cc: "#{c_cpu}% / #{c_th}T", cm: c_m, ck: 'N/A'
      )
      puts "\n[Harness] \u26A0\uFE0F EXTERNAL SERVER DISCONNECTED!"
      true
    end
  end
end
