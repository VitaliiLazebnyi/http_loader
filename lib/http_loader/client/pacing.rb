# typed: strong
# frozen_string_literal: true

require 'sorbet-runtime'
require 'time'

# Primary namespace for the load testing framework.
module HttpLoader
  class Client
    # Shared connection-pacing arithmetic mixed into the client engine and the per-protocol
    # sessions: jittered sleep intervals and keep-alive budget bookkeeping. Keeping it in one
    # place means a single definition is specified and mutation-tested, rather than three
    # copies drifting apart.
    module Pacing
      extend T::Sig
      extend T::Helpers

      # Mixed only into objects that carry Kernel (the client engine and the sessions), so the
      # private Kernel helpers (`rand`) resolve on `self` under `typed: strong`.
      requires_ancestor { Kernel }

      # Applies randomization jitter to a base sleep interval: the interval is spread by
      # +/- (base * jitter) and floored at 0. A jitter of zero yields a zero spread, so the
      # base is returned unchanged.
      #
      # @param base_seconds [Float] the base sleep interval
      # @param jitter [Float] the jitter factor (0 disables the spread)
      # @return [Float] the jittered, non-negative interval
      sig { params(base_seconds: Float, jitter: Float).returns(Float) }
      def jittered_interval(base_seconds, jitter)
        variance = base_seconds * jitter
        [0.0, base_seconds + rand(-variance..variance)].max
      end

      # Seconds left before a keep-alive deadline, or nil when the lifetime is unbounded
      # (`timeout <= 0`). Used to cap each heartbeat sleep so a connection never overruns its
      # deadline by up to a full (jittered) interval.
      #
      # @param timeout [Float] the total keep-alive budget in seconds (0 means unbounded)
      # @param start_time [Time] the connection's spawn timestamp
      # @return [Float, nil] remaining seconds, or nil if unbounded
      sig { params(timeout: Float, start_time: Time).returns(T.nilable(Float)) }
      def budget_remaining(timeout, start_time)
        return nil unless timeout > 0.0

        timeout - (Time.now.to_f - start_time.to_f)
      end

      # Caps a computed sleep so it never sleeps past the remaining keep-alive budget.
      #
      # @param base [Float] the desired sleep duration
      # @param remaining [Float, nil] remaining budget, or nil if unbounded
      # @return [Float] the capped sleep duration
      sig { params(base: Float, remaining: T.nilable(Float)).returns(Float) }
      def cap_to_budget(base, remaining)
        return base unless remaining

        [base, remaining].min
      end
    end
  end
end
