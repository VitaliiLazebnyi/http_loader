# typed: strict
module Rackup
  module Handler
    class Falcon
      sig { params(app: Object, Host: String, Port: Integer, SSLEnable: T::Boolean, ssl_context: Object, block: Object).void }
      def self.run(app, Host: '', Port: 0, SSLEnable: false, ssl_context: nil, &block); end
    end
  end
end
