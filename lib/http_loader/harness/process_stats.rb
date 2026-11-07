# typed: strong
# frozen_string_literal: true

# Copyright (c) 2026 Vitalii Lazebnyi

require 'sorbet-runtime'

# Primary namespace for the load testing framework.
module HttpLoader
  class Harness
    # The resource usage of a process at one point in time, as the metrics table shows it.
    class ProcessStats < T::Struct
      extend T::Sig

      # The CPU usage in percent, or a placeholder.
      const :cpu, String
      # The resident memory, formatted (e.g. "1.5 MB"), or a placeholder.
      const :memory, String
      # The resident memory in kilobytes.
      const :kilobytes, Float
      const :threads, Integer
      # Whether the process is external (not started by the harness), so nothing about it is known.
      const :external, T::Boolean, default: false

      # The stats measured for a process.
      #
      # @param cpu [String] the CPU usage in percent
      # @param kilobytes [Float] the resident memory in kilobytes
      # @param threads [Integer] the number of threads
      # @return [ProcessStats] the stats, with the memory formatted in megabytes
      sig { params(cpu: String, kilobytes: Float, threads: Integer).returns(ProcessStats) }
      def self.measured(cpu, kilobytes, threads)
        new(cpu: cpu, memory: "#{(kilobytes / 1024.0).round(2)} MB", kilobytes: kilobytes, threads: threads)
      end

      # The CPU usage and the thread count, e.g. "12.5% / 8".
      #
      # @return [String] the load column
      sig { returns(String) }
      def load
        "#{cpu}% / #{threads}"
      end

      # The resident memory per connection.
      #
      # @param connections [Integer] the established connections of the process
      # @return [String] e.g. "12.5 KB"; "N/A" without connections, "EXTERNAL" for an external process
      sig { params(connections: Integer).returns(String) }
      def per_connection(connections)
        return 'EXTERNAL' if external
        return 'N/A' unless connections.positive?

        "#{(kilobytes / connections).round(2)} KB"
      end

      # The three metrics-table columns of the process: load, memory and memory per connection.
      #
      # @param connections [Integer] the established connections of the process
      # @return [Array<String>] the columns
      sig { params(connections: Integer).returns(T::Array[String]) }
      def columns(connections)
        [load, memory, per_connection(connections)]
      end
    end
  end
end
