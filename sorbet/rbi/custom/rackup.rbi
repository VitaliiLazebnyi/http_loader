# typed: strict
module Rackup
  module Handler
    class Falcon
      sig { params(app: Object, options: T.untyped, block: T.nilable(T.proc.params(arg0: T.untyped).void)).void }
      def self.run(app, **options, &block); end
    end
  end
end
