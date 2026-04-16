# typed: strong
# frozen_string_literal: true

require 'sorbet-runtime'
require 'fileutils'
require 'time'

# Primary namespace for the load testing framework.
module HttpLoader
  class Client
    # Handles asynchronous file logging to prevent blocking main connections.
    class Logger
      extend T::Sig

      # Initializes a new Logger instance, creating internal queues for asynchronous work.
      #
      # @param verbose [Boolean] enables verbose terminal logging
      # @return [void]
      sig { params(verbose: T::Boolean).void }
      def initialize(verbose)
        @verbose = verbose
        @log_dir = T.let(File.expand_path('../../../logs', __dir__), String)
        @log_queue = T.let(Queue.new, Queue)
        @logger_task = T.let(nil, T.nilable(T.untyped))
      end

      # Prepares the filesystem by creating necessary log files and clearing previous logs.
      #
      # @return [void]
      sig { void }
      def setup_files!
        FileUtils.mkdir_p(@log_dir)
        File.write(File.join(@log_dir, 'client.err'), '')
        File.write(File.join(@log_dir, 'client.log'), '') if @verbose
      end

      # Spins up an async listener mapping log queues to the underlying file descriptors.
      #
      # @param task [Async::Task] the orchestration asynchronous task
      # @return [Async::Task] the running logger task yielding IO operations
      sig { params(task: T.untyped).returns(T.untyped) }
      def run_task(task)
        @logger_task = task.async do
          File.open(File.join(@log_dir, 'client.log'), 'a') do |log|
            File.open(File.join(@log_dir, 'client.err'), 'a') do |err|
              poll_queue(task, log, err)
            end
          end
        end
      end

      # Safely drains remaining log entries to disk synchronously when engine exits.
      #
      # @return [void]
      sig { void }
      def flush_synchronously!
        File.open(File.join(@log_dir, 'client.log'), 'a') do |log|
          File.open(File.join(@log_dir, 'client.err'), 'a') do |err|
            drain_queue(log, err)
          end
        end
      rescue StandardError
        nil
      end

      # Enqueues general informative messages to the async log queue if verbose flag is toggled.
      #
      # @param message [String] the formatted payload message
      # @return [void]
      sig { params(message: String).void }
      def info(message)
        return unless @verbose

        @log_queue << [:info, "[#{Time.now.utc.iso8601}] #{message}"]
      end

      # Enqueues error messages immediately irrespective of verbosity configuration.
      #
      # @param message [String] the formatted payload message
      # @return [void]
      sig { params(message: String).void }
      def error(message)
        @log_queue << [:error, "[#{Time.now.utc.iso8601}] #{message}"]
      end

      private

      # Consumes queue actively via block polling using async sleeping paradigms.
      #
      # @param task [Async::Task] the orchestrator bound task
      # @param log [File] descriptor targeting the info/debug log
      # @param err [File] descriptor targeting the error log
      # @return [void]
      sig { params(task: T.untyped, log: File, err: File).void }
      def poll_queue(task, log, err)
        loop do
          msg = fetch_message(task)
          next unless msg
          break if msg == :terminate

          write_msg(msg, log, err)
        end
      end

      # Continuously forces buffer evaluation synchronously without yielding runtime.
      #
      # @param log [File] descriptor targeting the info/debug log
      # @param err [File] descriptor targeting the error log
      # @return [void]
      sig { params(log: File, err: File).void }
      def drain_queue(log, err)
        loop do
          msg = begin
            @log_queue.pop(true)
          rescue ThreadError
            nil
          end
          break unless msg && msg != :terminate

          write_msg(msg, log, err)
        end
      end

      # Tries popping elements off execution queues non-blockingly, sleeping async if empty.
      #
      # @param task [Async::Task] the async orchestrator task
      # @return [Array, Symbol, nil] the payload tuple, termination symbol, or nil
      sig { params(task: T.untyped).returns(T.untyped) }
      def fetch_message(task)
        @log_queue.pop(true)
      rescue ThreadError
        task.sleep(0.05)
        nil
      end

      # Evaluates payload structure formatting raw string to physical IO devices.
      #
      # @param msg [Array] the log level tuple targeting IO
      # @param log [File] descriptor targeting the info/debug log
      # @param err [File] descriptor targeting the error log
      # @return [void]
      sig { params(msg: T::Array[T.untyped], log: File, err: File).void }
      def write_msg(msg, log, err)
        target, content = msg
        if target == :info
          log.puts content
          log.flush
        elsif target == :error
          err.puts content
          err.flush
        end
      end
    end
  end
end
