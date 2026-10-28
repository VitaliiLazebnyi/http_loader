# typed: strong
# frozen_string_literal: true

require 'sorbet-runtime'
require 'fileutils'
require 'time'
require 'async'
require 'async/queue'

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
        @log_queue = T.let(Async::Queue.new, Async::Queue)
        @logger_task = T.let(nil, Object)
      end

      # Prepares the filesystem by creating necessary log files and clearing previous logs.
      #
      # @return [void]
      sig { void }
      def setup_files!
        FileUtils.mkdir_p(@log_dir)
        # The Logger is the sole writer of these two files (the harness captures the
        # child's raw stdout/stderr into separate `client.stdout.log`/`client.stderr.log`),
        # so truncating here is safe and does not race a second file descriptor.
        File.write(File.join(@log_dir, 'client.err'), '')
        File.write(File.join(@log_dir, 'client.log'), '')
      end

      # Spins up an async listener mapping log queues to the underlying file descriptors.
      #
      # @param task [Async::Task] the orchestration asynchronous task
      # @return [Async::Task] the running logger task yielding IO operations
      sig { params(task: Async::Task).returns(Async::Task) }
      def run_task(task)
        @logger_task = task.async do
          File.open(File.join(@log_dir, 'client.log'), 'a') do |log|
            File.open(File.join(@log_dir, 'client.err'), 'a') do |err|
              poll_queue(log, err)
            end
          end
        end
        T.cast(@logger_task, Async::Task)
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

      # Enqueues an informational message to `client.log` unconditionally, independent of
      # verbosity. Used for opt-in channels such as `--track_status_codes`, which the user
      # explicitly requested and which must therefore not be silently coupled to `--verbose`.
      #
      # @param message [String] the formatted payload message
      # @return [void]
      sig { params(message: String).void }
      def status(message)
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

      # Consumes the queue with a fiber-aware blocking dequeue: while the queue is empty it
      # yields to the reactor (no busy-poll, no wakeup latency) and is unwound cleanly by
      # Async::Task#stop when the engine shuts down.
      #
      # @param log [File] descriptor targeting the info/debug log
      # @param err [File] descriptor targeting the error log
      # @return [void]
      sig { params(log: File, err: File).void }
      def poll_queue(log, err)
        loop do
          write_msg(T.cast(@log_queue.dequeue, T::Array[T.any(Symbol, String)]), log, err)
        end
      end

      # Drains whatever remains in the queue synchronously at shutdown. `dequeue` returns
      # immediately while items are present, and the `empty?` guard prevents it from
      # blocking once the queue is exhausted (the reactor is no longer running here).
      #
      # @param log [File] descriptor targeting the info/debug log
      # @param err [File] descriptor targeting the error log
      # @return [void]
      sig { params(log: File, err: File).void }
      def drain_queue(log, err)
        until T.cast(@log_queue.empty?, T::Boolean)
          msg = T.cast(@log_queue.dequeue, T::Array[T.any(Symbol, String)])
          write_msg(msg, log, err)
        end
      end

      # Evaluates payload structure formatting raw string to physical IO devices.
      #
      # @param msg [Array<T.any(Symbol, String)>] the log level tuple targeting IO
      # @param log [File] descriptor targeting the info/debug log
      # @param err [File] descriptor targeting the error log
      # @return [void]
      sig { params(msg: T::Array[T.any(Symbol, String)], log: File, err: File).void }
      def write_msg(msg, log, err)
        target, content = msg
        target = T.cast(target, Symbol)
        content_str = T.cast(content, String)
        if target == :info
          log.puts content_str
          log.flush
        elsif target == :error
          err.puts content_str
          err.flush
        end
      end
    end
  end
end
