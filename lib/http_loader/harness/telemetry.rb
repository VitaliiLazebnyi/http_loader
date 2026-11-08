# typed: strong
# frozen_string_literal: true

# Copyright (c) 2026 Vitalii Lazebnyi

require 'json'
require 'sorbet-runtime'
require_relative 'error_tally'

# Primary namespace for the load testing framework.
module HttpLoader
  class Harness
    # Tracks a run (its start, its peak connection count and the client's errors), reports bottlenecks while it
    # runs and exports the JSON report at its end.
    class Telemetry
      extend T::Sig

      sig { returns(Integer) }
      attr_reader :peak_connections

      # The bottleneck messages of the error metrics that occurred.
      #
      # @param counts [Hash{Symbol => Integer}] the count of every error metric
      # @return [Array<String>] one message per metric with a positive count
      sig { params(counts: ErrorTally::Counts).returns(T::Array[String]) }
      def self.bottleneck_messages(counts)
        counts.filter_map do |name, count|
          format(ErrorTally::METRICS.fetch(name).bottleneck, count: count) if count.positive?
        end
      end

      # @param log_dir [String] the directory of the client logs
      # @param export_json [String, nil] where to write the JSON report, or nil for none
      # @return [void]
      sig { params(log_dir: String, export_json: T.nilable(String)).void }
      def initialize(log_dir, export_json)
        @export_json = export_json
        @errors = T.let(ErrorTally.new(log_dir), ErrorTally)
        # Only elapsed-second deltas are taken from the start (`Time#-` is instant-based), so the Time's zone
        # never surfaces -- no `.utc`.
        @started = T.let(Time.now, Time)
        @peak_connections = T.let(0, Integer)
      end

      # Restarts the run's clock: the duration counts from now.
      #
      # @return [void]
      sig { void }
      def restart
        @started = Time.now
      end

      # @return [Float] the seconds since the run's start
      sig { returns(Float) }
      def elapsed
        Time.now - @started
      end

      # Records a connection count, keeping the peak.
      #
      # @param connections [Integer] the established connections of the client now
      # @return [void]
      sig { params(connections: Integer).void }
      def observe(connections)
        @peak_connections = [@peak_connections, connections].max
      end

      # Writes the JSON report, when a path was given.
      #
      # @return [void]
      sig { void }
      def export
        path = @export_json
        return unless path

        File.write(path, JSON.generate(payload))
        puts("[Harness] Telemetry JSON securely sinked to #{path}.")
      end

      # Prints the bottlenecks the client logged so far, if any.
      #
      # @return [void]
      sig { void }
      def report_bottlenecks
        messages = Telemetry.bottleneck_messages(@errors.counts)
        puts(format('   => BOTTLENECK ACTIVE: %<messages>s', messages: messages.join(' | '))) if messages.any?
      rescue StandardError
        nil
      end

      private

      # The JSON report: the peak connections, the duration and the error counts.
      #
      # @return [Hash{Symbol => Object}] the report
      sig { returns(T::Hash[Symbol, Object]) }
      def payload
        counts = @errors.counts
        {
          peak_connections: @peak_connections,
          test_duration_seconds: elapsed.round(2),
          errors: {
            emfile: counts.fetch(:emfile),
            eaddrnotavail: counts.fetch(:eaddr_count),
            thread_limit: counts.fetch(:thread_errors)
          }
        }
      end
    end
  end
end
