# typed: strong
# frozen_string_literal: true

require 'sorbet-runtime'
require 'json'

# Primary namespace for the load testing framework.
module HttpLoader
  class Harness
    # Exports telemetry and logs bottlenecks asynchronously and synchronously at termination.
    class Telemetry
      extend T::Sig

      # The error-token table: metric name => log token. A static type, checked by `srb tc`.
      Tokens = T.type_alias { T::Hash[Symbol, String] }
      # The running per-metric error tallies. A static type, checked by `srb tc`.
      Counts = T.type_alias { T::Hash[Symbol, Integer] }
      # The per-file byte offsets consumed so far. A static type, checked by `srb tc`.
      Offsets = T.type_alias { T::Hash[String, Integer] }

      # Error tokens harvested from the client logs, keyed by the payload metric name.
      ERROR_TOKENS = T.let(
        { emfile: 'ERROR_EMFILE', eaddr_count: 'ERROR_EADDRNOTAVAIL', thread_errors: 'ERROR_THREADLIMIT' }.freeze,
        Tokens
      )

      # Mounts the telemetry sub-engine mapping disk outputs transparently tracking boundaries.
      #
      # @param log_dir [String] physical absolute path targeting output payload maps
      # @param export_json [String, nil] absolute file destination serializing end report dynamically
      # @return [void]
      sig { params(log_dir: String, export_json: T.nilable(String)).void }
      def initialize(log_dir, export_json)
        @log_dir = log_dir
        @export_json = export_json
        @counts = T.let({ emfile: 0, eaddr_count: 0, thread_errors: 0 }, Counts)
        @offsets = T.let({}, Offsets)
      end

      # Serializes a comprehensive analysis payload upon successful OS termination manually.
      #
      # @param peak_connections [Integer] the high watermark metric for total alive states recorded
      # @param start_time [Time] chronological tracking root reference explicitly
      # @return [void]
      sig { params(peak_connections: Integer, start_time: Time).void }
      def export!(peak_connections, start_time)
        return unless @export_json

        accumulate!
        payload = generate_payload(peak_connections, start_time, @counts)
        File.write(@export_json, JSON.generate(payload))
        puts "[Harness] Telemetry JSON securely sinked to #{@export_json}."
      end

      # Verifies local file output queues alerting std-out upon bottleneck OS detections actively.
      #
      # @return [void]
      sig { void }
      def check_bottlenecks!
        accumulate!
        errors = build_bottleneck_messages(@counts)
        puts format('   => BOTTLENECK ACTIVE: %s', errors.join(' | ')) if errors.any?
      rescue StandardError
        nil
      end

      private

      # Formats an agnostic JSON hash representation mapping performance and anomalies universally.
      #
      # @param peak [Integer] logical max connections integer evaluation
      # @param start [Time] process baseline boot parameter mapping
      # @param counts [Hash] dictionary capturing parsed string evaluations tracking OS limits natively
      # @return [Hash] JSON translatable dataset mapping
      sig { params(peak: Integer, start: Time, counts: Counts).returns(T::Hash[Symbol, T.untyped]) }
      def generate_payload(peak, start, counts)
        {
          peak_connections: peak, test_duration_seconds: (Time.now - start).round(2),
          errors: {
            emfile: counts.fetch(:emfile), eaddrnotavail: counts.fetch(:eaddr_count),
            thread_limit: counts.fetch(:thread_errors)
          }
        }
      end

      # Reads only the newly-appended tail of each client log since the previous tick and
      # folds any error tokens into the running totals. This keeps per-tick cost proportional
      # to fresh output rather than re-reading unbounded logs into memory every ~2 seconds.
      #
      # @return [void]
      sig { void }
      def accumulate!
        %w[client.log client.err].each { |name| consume_tail(File.join(@log_dir, name)) }
      end

      # Consumes complete lines appended to a single file since the last offset, tolerating
      # truncation/rotation (offset reset) and never splitting an error token across reads.
      # Reading from the stored offset to EOF keeps each tick's cost proportional to the freshly
      # appended bytes rather than to the (unbounded) log size; when nothing new has been written
      # the read yields an empty string and the offset is left untouched.
      #
      # @param path [String] absolute file path
      # @return [void]
      sig { params(path: String).void }
      def consume_tail(path)
        return unless File.exist?(path)

        size = File.size(path)
        offset = @offsets[path] || 0
        offset = 0 if size < offset
        # `size` as the length caps the read at the current end of file; starting from `offset`
        # that yields exactly the freshly appended bytes. A length-limited `File.read` returns the
        # raw bytes (ASCII-8BIT), so arbitrary log bytes never trip UTF-8 validation, and `nil` at
        # EOF (nothing new appended), which `to_s` folds into the empty string.
        data = File.read(path, size, offset).to_s
        @offsets[path] = offset + tally_complete_lines(data)
      end

      # Tallies error tokens from whole lines only, returning the number of bytes consumed
      # (up to and including the final newline); a trailing partial line is left for next time.
      #
      # @param data [String] freshly read bytes
      # @return [Integer] bytes consumed
      sig { params(data: String).returns(Integer) }
      def tally_complete_lines(data)
        last_nl = data.rindex("\n")
        return 0 unless last_nl

        chunk = T.must(data[0..last_nl])
        ERROR_TOKENS.each { |metric, token| @counts[metric] = @counts.fetch(metric) + chunk.scan(token).size }
        chunk.bytesize
      end

      # Translates generic error logs into explicit formatting tuples suitable for interactive terminals locally.
      #
      # @param counts [Hash] quantitative mapping metrics describing error boundaries natively
      # @return [Array<String>] textual output logs targeting stderr mapped explicitly
      sig { params(counts: Counts).returns(T::Array[String]) }
      def build_bottleneck_messages(counts)
        emfile = counts.fetch(:emfile)
        eaddr = counts.fetch(:eaddr_count)
        threads = counts.fetch(:thread_errors)
        errors = []
        errors << "[OS FDs Limit: #{emfile} EMFILE]" if emfile.positive?
        errors << "[OS Ports Limit: #{eaddr} EADDRNOTAVAIL]" if eaddr.positive?
        errors << "[OS Thread Limit: #{threads} ThreadError]" if threads.positive?
        errors
      end
    end
  end
end
