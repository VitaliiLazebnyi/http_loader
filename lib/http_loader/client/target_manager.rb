# typed: strong
# frozen_string_literal: true

# Copyright (c) 2026 Vitalii Lazebnyi

require 'openssl'
require 'socket'
require 'sorbet-runtime'
require 'uri'

# Primary namespace for the load testing framework.
module HttpLoader
  class Client
    # Manages URI contexts, IPs, proxies, and HTTPS resolution.
    class TargetManager
      extend T::Sig

      # The keyword options passed to Net::HTTP.start (timeouts, resolved address, TLS, proxy, bind address).
      HttpArgs = T.type_alias { T::Hash[Symbol, Object] }
      public_constant :HttpArgs

      # A parsed proxy pool entry. A typed value object (rather than a Hash) so each field is
      # read as a method, which keeps the field accesses out of reach of index-vs-fetch mutations.
      class ProxyEndpoint < T::Struct
        extend T::Sig

        const :host, String
        const :port, Integer
        const :user, T.nilable(String)
        const :pass, T.nilable(String)

        # The Net::HTTP start options of the proxy; the credentials only when the entry has them.
        #
        # @return [Hash{Symbol => Object}] the proxy options
        sig { returns(HttpArgs) }
        def http_args
          T.cast({ proxy_address: host, proxy_port: port, proxy_user: user, proxy_pass: pass }.compact, HttpArgs)
        end
      end

      # A resolved endpoint: its parsed URI plus the Net::HTTP start options for it.
      class Target < T::Struct
        const :uri, URI::Generic
        const :http_args, HttpArgs
      end

      # The resolved endpoints, one per target URL. A static type, checked by `srb tc`.
      TargetList = T.type_alias { T::Array[Target] }
      private_constant :TargetList

      # Matches `[scheme://][user[:pass]@]host[:port]` tolerantly, including credentialed
      # proxies that `URI.parse` rejects under the bundled `uri` gem.
      PROXY_RE = %r{\A(?:\w+://)?(?:(?<user>[^:@/]+)(?::(?<pass>[^@/]*))?@)?(?<host>[^:/@]+)(?::(?<port>\d+))?}
      private_constant :PROXY_RE

      # Tolerantly parses a proxy pool entry into its components. `URI.parse` rejects
      # credentialed proxy URLs (raw `:`/`@` in the userinfo) under the bundled `uri`
      # gem, so a single regex extracts optional scheme, credentials, host, and port
      # without ever raising on a well-formed `user:pass@host:port` entry.
      #
      # @param entry [String] a raw proxy pool entry
      # @return [ProxyEndpoint] the extracted host, port, user, and pass
      sig { params(entry: String).returns(ProxyEndpoint) }
      def self.parse_proxy(entry)
        # PROXY_RE's `host` group is not optional, so a successful match always captures a host;
        # testing `match` alone is equivalent to also testing `match[:host]`.
        match = PROXY_RE.match(entry)
        raise(ArgumentError, "Invalid --proxy_pool entry: #{entry.inspect}") unless match

        host, port, user, pass = match.values_at(:host, :port, :user, :pass)
        ProxyEndpoint.new(host: T.must(host), port: Integer(port || '80'), user: user, pass: pass)
      end

      # Pre-queries native operating system DNS to capture IPv4 IP maps proactively.
      #
      # @param uri [URI::Generic] the formulated host domain specifier
      # @return [String, nil] pure textual Internet protocol network target coordinates
      sig { params(uri: URI::Generic).returns(T.nilable(String)) }
      def self.resolve_ip(uri)
        addresses = T.cast(Addrinfo.getaddrinfo(T.must(uri.host), uri.port, nil, :STREAM), T::Array[Addrinfo])
        address = addresses.find(&:ipv4?) || addresses.first
        T.cast(address&.ip_address, T.nilable(String))
      rescue SocketError
        nil
      end

      # The TLS options of an HTTPS target, which accept any certificate; none for plain HTTP.
      #
      # @param uri [URI::Generic] the target
      # @return [Hash{Symbol => Object}] the TLS options
      sig { params(uri: URI::Generic).returns(HttpArgs) }
      def self.secure_opts(uri)
        uri.scheme == 'https' ? { use_ssl: true, verify_mode: OpenSSL::SSL::VERIFY_NONE } : {}
      end

      # The element of a non-empty list for a worker, round-robin.
      #
      # @param list [Array<String>] the list
      # @param client_index [Integer] the worker index
      # @return [String] the worker's element
      sig { params(list: T::Array[String], client_index: Integer).returns(String) }
      def self.round_robin(list, client_index)
        list.fetch(client_index % list.size)
      end

      # Initializes the TargetManager tracking connection URI configurations.
      #
      # @param config [Config] configuration object from parsing orchestrator
      # @return [void]
      sig { params(config: Config).void }
      def initialize(config)
        @config = config
        @target_contexts = T.let(build_target_contexts, TargetList)
      end

      # Yields a formatted terminal label classifying protocol usage logic.
      #
      # @return [String] text representation denoting HTTP or HTTPS routing logic
      sig { returns(String) }
      def protocol_label
        count = @config.target_urls.size
        if count > 1
          "MULTIPLE TARGETS (#{count})"
        elsif count == 1
          "EXTERNAL #{T.must(@target_contexts.first).uri.scheme&.upcase}"
        else
          @config.use_https ? 'HTTPS' : 'HTTP'
        end
      end

      # Retrieves specific connection settings distributing nodes evenly using deterministic boundaries.
      #
      # @param client_index [Integer] integer value unique per generated fiber worker
      # @return [Target] the endpoint this worker connects to
      sig { params(client_index: Integer).returns(Target) }
      def context_for(client_index)
        @target_contexts.fetch(client_index % @target_contexts.size)
      end

      # The Net::HTTP start options of a worker: the target's, plus the worker's bind address and proxy.
      #
      # @param client_index [Integer] fiber worker ID enabling round-robin balancing
      # @param args [Hash] the start options of the worker's target
      # @return [Hash] the start options with the worker's bind address and proxy
      sig { params(client_index: Integer, args: HttpArgs).returns(HttpArgs) }
      def http_opts_for(client_index, args)
        args.merge(bind_opts(client_index), proxy_opts(client_index))
      end

      private

      # The bind address of a worker, round-robin over `--bind_ips`; none when the list is empty.
      #
      # @param client_index [Integer] the worker index
      # @return [Hash{Symbol => Object}] the bind option
      sig { params(client_index: Integer).returns(HttpArgs) }
      def bind_opts(client_index)
        ips = @config.bind_ips
        ips.empty? ? {} : { local_host: TargetManager.round_robin(ips, client_index) }
      end

      # The proxy of a worker, round-robin over `--proxy_pool`; none when the pool is empty.
      #
      # @param client_index [Integer] the worker index
      # @return [Hash{Symbol => Object}] the proxy options
      sig { params(client_index: Integer).returns(HttpArgs) }
      def proxy_opts(client_index)
        pool = @config.proxy_pool
        pool.empty? ? {} : TargetManager.parse_proxy(TargetManager.round_robin(pool, client_index)).http_args
      end

      # Resolves every target URL (or the local server when there is none) once, up front.
      #
      # @return [Array<Target>] one resolved endpoint per target URL
      sig { returns(TargetList) }
      def build_target_contexts
        urls = @config.target_urls
        (urls.empty? ? [nil] : urls).map { |url| target(parse_uri(url)) }
      end

      # The resolved endpoint of a URI: its address, read timeout and TLS options. Net::HTTP never retries a
      # request on its own (`max_retries: 0`), so every request the tool counts is sent once.
      #
      # @param uri [URI::Generic] the target
      # @return [Target] the endpoint
      sig { params(uri: URI::Generic).returns(Target) }
      def target(uri)
        timeout = @config.read_timeout
        args = T.let(
          { read_timeout: (timeout if timeout > 0.0), max_retries: 0, ipaddr: TargetManager.resolve_ip(uri) },
          HttpArgs
        )
        Target.new(uri: uri, http_args: args.merge(TargetManager.secure_opts(uri)))
      end

      # Resolves unmapped domain string patterns against standardized URI protocol libraries.
      #
      # @param url [String, nil] textual endpoint target
      # @return [URI::Generic] instantiated parsed reference object
      sig { params(url: T.nilable(String)).returns(URI::Generic) }
      def parse_uri(url)
        uri =
          if url
            URI(url)
          else
            @config.use_https ? URI('https://localhost:8443') : URI('http://localhost:8080')
          end
        raise(ArgumentError, "Invalid --url (missing host): #{url.inspect}") if uri.host.to_s.empty?

        uri
      end
    end
  end
end
