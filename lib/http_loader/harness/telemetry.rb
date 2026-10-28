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

      # Error tokens harvested from the client logs, keyed by the payload metric name.
      ERROR_TOKENS = T.let(
        { emfile: 'ERROR_EMFILE', eaddr_count: 'ERROR_EADDRNOTAVAIL', thread_errors: 'ERROR_THREADLIMIT' }.freeze,
        T::Hash[Symbol, String]
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
        @counts = T.let({ emfile: 0, eaddr_count: 0, thread_errors: 0 }, T::Hash[Symbol, Integer])
        @offsets = T.let({}, T::Hash[String, Integer])
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
      sig { params(peak: Integer, start: Time, counts: T::Hash[Symbol, Integer]).returns(T::Hash[Symbol, T.untyped]) }
      def generate_payload(peak, start, counts)
        {
          peak_connections: peak, test_duration_seconds: (Time.now.utc - start).round(2),
          errors: { emfile: counts[:emfile], eaddrnotavail: counts[:eaddr_count], thread_limit: counts[:thread_errors] }
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
      #
      # @param path [String] absolute file path
      # @return [void]
      sig { params(path: String).void }
      def consume_tail(path)
        return unless File.exist?(path)

        size = File.size(path)
        offset = @offsets[path] || 0
        offset = 0 if size < offset
        return if size <= offset

        File.open(path, 'rb') do |file|
          file.seek(offset)
          data = file.read(size - offset).to_s
          @offsets[path] = offset + tally_complete_lines(data)
        end
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
        ERROR_TOKENS.each { |metric, token| @counts[metric] = T.must(@counts[metric]) + chunk.scan(token).size }
        chunk.bytesize
      end

      # Translates generic error logs into explicit formatting tuples suitable for interactive terminals locally.
      #
      # @param counts [Hash] quantitative mapping metrics describing error boundaries natively
      # @return [Array<String>] textual output logs targeting stderr mapped explicitly
      sig { params(counts: T::Hash[Symbol, Integer]).returns(T::Array[String]) }
      def build_bottleneck_messages(counts)
        emfile = T.must(counts[:emfile])
        eaddr = T.must(counts[:eaddr_count])
        threads = T.must(counts[:thread_errors])
        errors = []
        errors << "[OS FDs Limit: #{emfile} EMFILE]" if emfile.positive?
        errors << "[OS Ports Limit: #{eaddr} EADDRNOTAVAIL]" if eaddr.positive?
        errors << "[OS Thread Limit: #{threads} ThreadError]" if threads.positive?
        errors
      end
    end
  end
end
