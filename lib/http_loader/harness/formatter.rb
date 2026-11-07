# typed: strong
# frozen_string_literal: true

# Copyright (c) 2026 Vitalii Lazebnyi

require 'sorbet-runtime'
require_relative 'connection_counter'
require_relative 'process_stats'

# Primary namespace for the load testing framework.
module HttpLoader
  class Harness
    # Formatter handles printing load test statistics dynamically and robustly.
    module Formatter
      extend T::Sig
      extend T::Helpers

      # Mixed only into Harness; declaring that ancestor lets the bare `config`/`monitor`/`pm` and
      # `puts`/`format` calls below resolve under `typed: strong` on `self` directly, so there is no
      # `Kernel.`/`harness.` receiver to mutate into a behaviourally identical self form.
      requires_ancestor { HttpLoader::Harness }

      # One row of the metrics table: time, connections, then CPU, memory and memory per connection of the
      # server and of the client.
      ROW_FORMAT = '%<t>-10s | %<ac>-11s | %<sc>-16s | %<sm>-14s | %<sk>-14s | %<cc>-16s | %<cm>-14s | %<ck>-14s'
      private_constant :ROW_FORMAT

      # The columns of ROW_FORMAT, in order.
      COLUMNS = %i[t ac sc sm sk cc cm ck].freeze
      private_constant :COLUMNS

      # The column headings of the metrics table.
      HEADINGS = [
        'Time (UTC)',
        'Real Conns',
        'Srv CPU/Thrds',
        'Srv Mem',
        'Srv Mem/Conn',
        'Cli CPU/Thrds',
        'Cli Mem',
        'Cli Mem/Conn'
      ].freeze
      private_constant :HEADINGS

      # One row of the metrics table.
      #
      # @param cells [Array<Object>] the value of every column, in order
      # @return [String] the row
      sig { params(cells: T::Array[Object]).returns(String) }
      def self.row(cells)
        format(ROW_FORMAT, COLUMNS.zip(cells).to_h)
      end

      # @return [String] the time column of a row: the current UTC time
      sig { returns(String) }
      def self.clock
        Time.now.utc.strftime('%H:%M:%S')
      end

      # Prints an initial banner announcing URL and mode configurations.
      #
      # @return [void]
      sig { void }
      def print_startup_banner
        puts("[Harness] Starting test with #{config.connections} connections to #{startup_target_msg}")
      end

      # Yields formatted message describing targeted context
      #
      # @return [String] formatted descriptor based on URLs count
      sig { returns(String) }
      def startup_target_msg
        first, *others = config.target_urls
        return "**MULTIPLE TARGETS** (#{others.size + 1} URLs)." if others.any?
        return "**EXTERNAL URL** #{first}." if first

        config.use_https ? '**HTTPS**.' : '**HTTP**.'
      end

      # Outputs the top layer header frame for the metrics table.
      #
      # @return [void]
      sig { void }
      def print_table_header
        rule = '-' * 125
        puts('[Harness] Monitoring resources (Press Ctrl+C to stop)...', rule, Formatter.row(HEADINGS), rule)
      end

      # Prints one row of the metrics table.
      #
      # @param cells [Array<Object>] the value of every column, in order
      # @return [void]
      sig { params(cells: T::Array[Object]).void }
      def log_table_row(cells)
        puts(Formatter.row(cells))
      end

      # Prints the row of the server and the client.
      #
      # @param active [Integer] the established connections of the client
      # @param client [ProcessStats] the stats of the client
      # @return [void]
      sig { params(active: Integer, client: ProcessStats).void }
      def print_combined_stats(active, client)
        log_table_row([Formatter.clock, active, *server_columns, *client.columns(active)])
      end

      # The server's columns of a row: its load, memory and memory per connection.
      #
      # @return [Array<String>] the columns
      sig { returns(T::Array[String]) }
      def server_columns
        pid = pm.server_pid
        monitor.process_stats(pid).columns(ConnectionCounter.count(pid))
      end

      # Samples the client.
      #
      # @return [Array(Integer, ProcessStats)] its established connections and its stats
      sig { returns([Integer, ProcessStats]) }
      def extract_client_stats
        pid = pm.client_pid
        stats = monitor.process_stats(pid)
        [ConnectionCounter.count(pid), stats]
      end
    end
  end
end
