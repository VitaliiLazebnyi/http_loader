# typed: strong
# frozen_string_literal: true

# Copyright (c) 2026 Vitalii Lazebnyi

require 'sorbet-runtime'

# Primary namespace for the load testing framework.
module HttpLoader
  class Harness
    # Signals and reaps child processes for ProcessManager: a polite INT, a bounded wait, then KILL.
    module ProcessControl
      extend T::Sig

      # Seconds between two checks for the exit of a signalled child.
      POLL_INTERVAL = 0.05
      private_constant :POLL_INTERVAL

      # Escalating, reaping terminator for a single child PID.
      #
      # @param pid [Integer, nil] the target process id
      # @return [void]
      sig { params(pid: T.nilable(Integer)).void }
      def self.terminate(pid)
        return unless pid

        signal_quietly('INT', pid)
        return if reaped?(pid, 3.0)

        signal_quietly('KILL', pid)
        reaped?(pid, 2.0)
      end

      # Whether a process has exited: it no longer has a process group.
      #
      # @param pid [Integer] the process id
      # @return [Boolean] true once the process is gone
      sig { params(pid: Integer).returns(T::Boolean) }
      def self.dead?(pid)
        Process.getpgid(pid)
        false
      rescue Errno::ESRCH
        true
      end

      # Polls `waitpid(WNOHANG)` every POLL_INTERVAL until the child is reaped or the deadline passes.
      #
      # @param pid [Integer] the process id
      # @param deadline [Float] seconds to wait
      # @return [Boolean] true if the child was reaped
      sig { params(pid: Integer, deadline: Float).returns(T::Boolean) }
      def self.reaped?(pid, deadline)
        (deadline / POLL_INTERVAL).ceil.times do
          return true if Process.waitpid(pid, Process::WNOHANG)

          sleep(POLL_INTERVAL)
        end
        false
      rescue Errno::ECHILD, Errno::ESRCH
        true
      end

      # Sends a signal, swallowing "already gone" errors.
      #
      # @param signal [String] the signal name
      # @param pid [Integer] the target process id
      # @return [void]
      sig { params(signal: String, pid: Integer).void }
      def self.signal_quietly(signal, pid)
        Process.kill(signal, pid)
      rescue StandardError
        nil
      end
      private_class_method :reaped?, :signal_quietly
    end
  end
end
