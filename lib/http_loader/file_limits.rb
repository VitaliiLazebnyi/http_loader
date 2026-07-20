# typed: strong
# frozen_string_literal: true

require 'sorbet-runtime'

# Primary namespace for the load testing framework.
module HttpLoader
  # Best-effort adjustment of the per-process open-file (RLIMIT_NOFILE) soft limit.
  # Shared by both the harness and the standalone client so a directly-invoked
  # client raises its own ceiling instead of hitting EMFILE at the shell default.
  module FileLimits
    extend T::Sig

    # Raises the RLIMIT_NOFILE soft limit toward `desired` without ever lowering the
    # hard ceiling. A single-value `setrlimit` defaults `max` to the new soft value,
    # which would (a) irreversibly clamp a high/unlimited hard limit down and (b)
    # raise EPERM/EINVAL precisely in the high-connection case it exists for. We clamp
    # the request to the existing hard limit and pass that hard limit through unchanged.
    #
    # @param desired [Integer] the soft limit we would like (typically connections + headroom)
    # @param label [String] log prefix identifying the caller
    # @return [void]
    sig { params(desired: Integer, label: String).void }
    def self.bump!(desired, label: '[http_loader]')
      _cur, max = Process.getrlimit(Process::RLIMIT_NOFILE)
      Process.setrlimit(Process::RLIMIT_NOFILE, [desired, max].min, max)
    rescue StandardError
      # Covers EPERM/EINVAL (unprivileged or above kern.maxfilesperproc) and any
      # platform where RLIMIT_NOFILE is unavailable; the bump is strictly best-effort.
      warn "#{label} Warning: Could not set RLIMIT_NOFILE automatically."
    end
  end
end
