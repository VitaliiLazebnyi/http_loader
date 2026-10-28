# typed: strong
# frozen_string_literal: true

require 'sorbet-runtime'
require 'uri'
require 'socket'

# Primary namespace for the load testing framework.
module HttpLoader
  class Client
    # Manages URI contexts, IPs, proxies, and HTTPS resolution.
    class TargetManager
      extend T::Sig

      # A parsed proxy pool entry. A typed value object (rather than a Hash) so each field is
      # read as a method, which keeps the field accesses out of reach of index-vs-fetch mutations.
      class ProxyEndpoint < T::Struct
        const :host, String
        const :port, Integer
        const :user, T.nilable(String)
        const :pass, T.nilable(String)
      end

      # Matches `[scheme://][user[:pass]@]host[:port]` tolerantly, including credentialed
      # proxies that `URI.parse` rejects under the bundled `uri` gem.
      PROXY_RE = %r{\A(?:\w+://)?(?:(?<user>[^:@/]+)(?::(?<pass>[^@/]*))?@)?(?<host>[^:/@]+)(?::(?<port>\d+))?}

      # Initializes the TargetManager tracking connection URI configurations.
      #
      # @param config [Config] configuration object from parsing orchestrator
      # @return [void]
      sig { params(config: Config).void }
      def initialize(config)
        @config = config
        @target_contexts = T.let(build_target_contexts, T::Array[T::Hash[Symbol, T.untyped]])
      end

      # Yields a formatted terminal label classifying protocol usage logic.
      #
      # @return [String] text representation denoting HTTP or HTTPS routing logic
      sig { returns(String) }
      def protocol_label
        if @config.target_urls.size > 1
          "MULTIPLE TARGETS (#{@config.target_urls.size})"
        elsif @config.target_urls.size == 1
          "EXTERNAL #{T.cast(T.must(@target_contexts.first)[:uri], URI::Generic).scheme&.upcase}"
        elsif @config.use_https
          'HTTPS'
        else
          'HTTP'
        end
      end

      # Provides access to all active configured endpoint structs array.
      #
      # @return [Array<Hash>] map comprising raw URIs and configurations
      sig { returns(T::Array[T::Hash[Symbol, T.untyped]]) }
      def contexts
        @target_contexts
      end

      # Retrieves specific connection settings distributing nodes evenly using deterministic boundaries.
      #
      # @param client_index [Integer] integer value unique per generated fiber worker
      # @return [Hash] targeted setup config subset
      sig { params(client_index: Integer).returns(T::Hash[Symbol, T.untyped]) }
      def context_for(client_index)
        T.must(@target_contexts[client_index % @target_contexts.size])
      end

      # Applies granular connection level options such as localized IP bindings targeting network stacks natively.
      #
      # @param client_index [Integer] fiber worker ID enabling round-robin balancing
      # @param args [Hash] raw initialization opts generated statically
      # @return [Hash] dynamically mapped object with appended localized directives
      sig { params(client_index: Integer, args: T::Hash[Symbol, T.untyped]).returns(T::Hash[Symbol, T.untyped]) }
      def http_opts_for(client_index, args)
        http_opts = args.dup
        bind_ips = @config.bind_ips
        http_opts[:local_host] = bind_ips[client_index % bind_ips.size] if bind_ips.any?

        apply_proxy!(http_opts, client_index) if @config.proxy_pool.any?
        http_opts
      end

      # Mutates incoming Hash payload injecting fully mapped generic web proxy routing specs.
      #
      # @param opts [Hash] configuration map destination
      # @param client_index [Integer] index driving balanced proxy allocation logic
      # @return [void]
      sig { params(opts: T::Hash[Symbol, T.untyped], client_index: Integer).void }
      def apply_proxy!(opts, client_index)
        pool = @config.proxy_pool
        set_proxy_opts(opts, parse_proxy(T.must(pool[client_index % pool.size])))
      end

      # Tolerantly parses a proxy pool entry into its components. `URI.parse` rejects
      # credentialed proxy URLs (raw `:`/`@` in the userinfo) under the bundled `uri`
      # gem, so a single regex extracts optional scheme, credentials, host, and port
      # without ever raising on a well-formed `user:pass@host:port` entry.
      #
      # @param entry [String] a raw proxy pool entry
      # @return [ProxyEndpoint] the extracted host, port, user, and pass
      sig { params(entry: String).returns(ProxyEndpoint) }
      def parse_proxy(entry)
        # PROXY_RE's `host` group is not optional, so a successful match always captures a host;
        # testing `match` alone is equivalent to also testing `match[:host]`.
        match = PROXY_RE.match(entry)
        raise ArgumentError, "Invalid --proxy_pool entry: #{entry.inspect}" unless match

        ProxyEndpoint.new(
          host: T.must(match[:host]), port: (match[:port] || '80').to_i, user: match[:user], pass: match[:pass]
        )
      end

      # Applies extracted proxy values onto the Net::HTTP options hash.
      #
      # @param opts [Hash] configuration map destination
      # @param proxy [ProxyEndpoint] parsed proxy components
      # @return [void]
      sig { params(opts: T::Hash[Symbol, T.untyped], proxy: ProxyEndpoint).void }
      def set_proxy_opts(opts, proxy)
        opts[:proxy_address] = proxy.host
        opts[:proxy_port] = proxy.port
        opts[:proxy_user] = proxy.user if proxy.user
        opts[:proxy_pass] = proxy.pass if proxy.pass
      end

      private

      # Creates localized cache defining DNS mapped structures minimizing resolution cost later statically.
      #
      # @return [Array<Hash>] cached Array mapping URLs
      sig { returns(T::Array[T::Hash[Symbol, T.untyped]]) }
      def build_target_contexts
        urls = @config.target_urls.any? ? @config.target_urls : [nil]
        urls.map do |url|
          uri = parse_uri(url)
          timeout = @config.read_timeout
          args = { read_timeout: timeout > 0.0 ? timeout : nil }
          args[:ipaddr] = resolve_ip(uri)
          { uri: uri, http_args: secure_opts(uri, args) }
        end
      end

      # Resolves unmapped domain string patterns against standardized URI protocol libraries.
      #
      # @param url [String, nil] textual endpoint target
      # @return [URI::Generic] instantiated parsed reference object
      sig { params(url: T.nilable(String)).returns(URI::Generic) }
      def parse_uri(url)
        uri = if url
                URI(url.to_s)
              else
                @config.use_https ? URI('https://localhost:8443') : URI('http://localhost:8080')
              end
        raise ArgumentError, "Invalid --url (missing host): #{url.inspect}" if uri.host.to_s.empty?

        uri
      end

      # Pre-queries native operating system DNS to capture IPv4 IP maps proactively.
      #
      # @param uri [URI::Generic] the formulated host domain specifier
      # @return [String, nil] pure textual Internet protocol network target coordinates
      sig { params(uri: URI::Generic).returns(T.nilable(String)) }
      def resolve_ip(uri)
        ip_info = T.cast(Addrinfo.getaddrinfo(T.must(uri.host), uri.port, nil, :STREAM), T::Array[Addrinfo])
        T.cast((ip_info.find(&:ipv4?) || ip_info.first)&.ip_address, T.nilable(String))
      rescue SocketError
        nil
      end

      # Merges generic configuration options with SSL overrides ensuring invalid certificates process correctly.
      #
      # @param uri [URI::Generic] parsed URI configuration
      # @param args [Hash] basic configuration mapped state
      # @return [Hash] augmented settings resolving security layers with SSL
      sig { params(uri: URI::Generic, args: T::Hash[Symbol, T.untyped]).returns(T::Hash[Symbol, T.untyped]) }
      def secure_opts(uri, args)
        return args unless uri.scheme == 'https'

        args.merge(use_ssl: true, verify_mode: OpenSSL::SSL::VERIFY_NONE)
      end
    end
  end
end
