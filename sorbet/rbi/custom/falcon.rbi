# typed: strict

class IO
  module Endpoint
    sig { params(arguments: T.untyped, options: T.untyped).returns(T.untyped) }
    def self.tcp(*arguments, **options); end

    class SSLEndpoint
      sig { params(endpoint: T.untyped, options: T.untyped).void }
      def initialize(endpoint, **options); end
    end
  end
end

module Protocol
  module Rack
    module Adapter
      sig { params(app: T.untyped).void }
      def initialize(app); end
    end
  end
end

module Async
  module HTTP
    module Protocol
      module HTTP1; end
    end
  end
end

module Falcon
  class Server
    sig do
      params(
        arguments: T.untyped,
        utilization_registry: T.untyped,
        options: T.untyped
      ).void
    end
    def initialize(*arguments, utilization_registry: nil, **options); end

    sig { returns(T.untyped) }
    def run; end
  end

  sig { params(app: T.untyped, options: T.untyped, block: T.proc.params(arg0: T.untyped).void).void }
  def self.run(app, **options, &block); end
end
