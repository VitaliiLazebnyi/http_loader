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

      # The queued-message channel => the basename it is appended to. A static type (`srb tc`).
      Channels = T.type_alias { T::Hash[Symbol, String] }
      # Maps a log channel to its on-disk file; an unknown channel maps to nothing and is dropped.
      CHANNELS = T.let({ info: 'client.log', error: 'client.err' }.freeze, Channels)

      # Initializes a new Logger instance, creating internal queues for asynchronous work.
      #
      # @param verbose [Boolean] enables verbose terminal logging
      # @return [void]
      sig { params(verbose: T::Boolean).void }
      def initialize(verbose)
        @verbose = verbose
        @log_dir = T.let(File.expand_path('../../../logs', __dir__), String)
        @log_queue = T.let(Async::Queue.new, Async::Queue)
      end

      # Prepares the filesystem by creating necessary log files and clearing previous logs.
      #
      # @return [void]
      sig { void }
      def setup_files!
        FileUtils.mkdir_p(@log_dir)
        # The Logger is the sole writer of these files (the harness captures the child's raw
        # stdout/stderr into separate `client.stdout.log`/`client.stderr.log`), so creating and
        # truncating here is safe and does not race a second file descriptor.
        CHANNELS.each_value do |name|
          path = File.join(@log_dir, name)
          FileUtils.touch(path)
          File.truncate(path, 0)
        end
      end

      # Spins up an async listener draining the queue to the log files.
      #
      # @param task [Async::Task] the orchestration asynchronous task
      # @return [Async::Task] the running logger task yielding IO operations
      sig { params(task: Async::Task).returns(Async::Task) }
      def run_task(task)
        T.cast(task.async { poll_queue }, Async::Task)
      end

      # Safely drains remaining log entries to disk synchronously when engine exits.
      #
      # @return [void]
      sig { void }
      def flush_synchronously!
        drain_queue
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
      # @return [void]
      sig { void }
      def poll_queue
        loop do
          write_msg(T.cast(@log_queue.dequeue, T::Array[T.any(Symbol, String)]))
        end
      end

      # Drains whatever remains in the queue synchronously at shutdown. `dequeue` returns
      # immediately while items are present, and the `empty?` guard prevents it from
      # blocking once the queue is exhausted (the reactor is no longer running here).
      #
      # @return [void]
      sig { void }
      def drain_queue
        write_msg(T.cast(@log_queue.dequeue, T::Array[T.any(Symbol, String)])) until T.cast(@log_queue.empty?, T::Boolean)
      end

      # Appends one queued message to the file for its channel; an unknown channel is dropped.
      #
      # @param msg [Array<T.any(Symbol, String)>] the log level tuple targeting IO
      # @return [void]
      sig { params(msg: T::Array[T.any(Symbol, String)]).void }
      def write_msg(msg)
        target, content = msg
        file = CHANNELS[T.cast(target, Symbol)]
        File.write(File.join(@log_dir, file), "#{T.cast(content, String)}\n", mode: 'a') if file
      end
    end
  end
end
