# typed: strong
# frozen_string_literal: true

# Copyright (c) 2026 Vitalii Lazebnyi

require 'sorbet-runtime'

# Primary namespace for the load testing framework.
module HttpLoader
  class Harness
    # Counts the error tokens the client writes to its logs, reading only what was appended since the previous
    # count. This keeps the cost of every count proportional to fresh output rather than re-reading unbounded
    # logs into memory every ~2 seconds.
    class ErrorTally
      extend T::Sig

      # The running per-metric error tallies. A static type, checked by `srb tc`.
      Counts = T.type_alias { T::Hash[Symbol, Integer] }
      public_constant :Counts

      # An error the client logs: the token of its log lines, and the bottleneck message of a count of them.
      class Metric < T::Struct
        const :token, String
        const :bottleneck, String
      end

      # The errors harvested from the client logs, keyed by the metric name.
      METRICS = T.let(
        {
          emfile: Metric.new(token: 'ERROR_EMFILE', bottleneck: '[OS FDs Limit: %<count>d EMFILE]'),
          eaddr_count: Metric.new(
            token: 'ERROR_EADDRNOTAVAIL',
            bottleneck: '[OS Ports Limit: %<count>d EADDRNOTAVAIL]'
          ),
          thread_errors: Metric.new(token: 'ERROR_THREADLIMIT', bottleneck: '[OS Thread Limit: %<count>d ThreadError]')
        }.freeze,
        T::Hash[Symbol, Metric]
      )
      public_constant :METRICS

      # The client logs, in the log directory.
      LOGS = %w[client.log client.err].freeze
      private_constant :LOGS

      # The whole lines at the start of some bytes: up to and including the last newline.
      #
      # @param data [String] the bytes
      # @return [String, nil] the whole lines, or nil when there is no newline
      sig { params(data: String).returns(T.nilable(String)) }
      def self.complete_lines(data)
        last_newline = data.rindex("\n")
        data[..last_newline] if last_newline
      end

      # The byte offset read up to in every client log. A static type, checked by `srb tc`.
      Offsets = T.type_alias { T::Hash[String, Integer] }
      private_constant :Offsets

      # @param log_dir [String] the directory of the client logs
      # @return [void]
      sig { params(log_dir: String).void }
      def initialize(log_dir)
        @log_dir = log_dir
        @counts = T.let(METRICS.transform_values { 0 }, Counts)
        @offsets = T.let({}, Offsets)
      end

      # Folds the lines appended to the client logs since the previous call into the counts.
      #
      # @return [Hash{Symbol => Integer}] the count of every error token so far
      sig { returns(Counts) }
      def counts
        LOGS.each { |name| consume_tail(File.join(@log_dir, name)) }
        @counts.dup
      end

      private

      # Consumes the complete lines appended to a file since the previous call, tolerating
      # truncation or rotation (the offset resets) and never splitting an error token across reads.
      #
      # @param path [String] the file
      # @return [void]
      sig { params(path: String).void }
      def consume_tail(path)
        return unless File.exist?(path)

        size = File.size(path)
        offset = offset(path, size)
        # `size` as the length caps the read at the current end of file; starting from `offset`
        # that yields exactly the freshly appended bytes. A length-limited `File.read` returns the
        # raw bytes (ASCII-8BIT), so arbitrary log bytes never trip UTF-8 validation, and `nil` at
        # EOF (nothing new appended), which `to_s` folds into the empty string.
        @offsets[path] = offset + tally_complete_lines(File.read(path, size, offset).to_s)
      end

      # Where to continue reading a file: after the previous read, or from the start once the file is shorter
      # than that (truncated or rotated).
      #
      # @param path [String] the file
      # @param size [Integer] its current size
      # @return [Integer] the byte offset
      sig { params(path: String, size: Integer).returns(Integer) }
      def offset(path, size)
        offset = @offsets.fetch(path, 0)
        offset > size ? 0 : offset
      end

      # Tallies error tokens from whole lines only, returning the number of bytes consumed
      # (up to and including the final newline); a trailing partial line is left for next time.
      #
      # @param data [String] freshly read bytes
      # @return [Integer] bytes consumed
      sig { params(data: String).returns(Integer) }
      def tally_complete_lines(data)
        chunk = ErrorTally.complete_lines(data)
        return 0 unless chunk

        tally(chunk)
        chunk.bytesize
      end

      # Adds the error tokens of whole lines to the counts.
      #
      # @param chunk [String] whole lines
      # @return [void]
      sig { params(chunk: String).void }
      def tally(chunk)
        METRICS.each { |name, metric| @counts[name] = @counts.fetch(name) + chunk.scan(metric.token).size }
      end
    end
  end
end
