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
      extend T::Helpers

      # Mixed into ProcessManager; declaring an Object ancestor resolves `sleep` (Kernel) under `typed: strong`
      # on `self`, which keeps it stubbable in the specs.
      requires_ancestor { Object }

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
