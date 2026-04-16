# typed: strict

module Async
  class Task
    sig { void }
    def stop; end

    sig { params(duration: Float).void }
    def sleep(duration); end
  end

  class Semaphore
    sig { params(arguments: T.untyped, parent: T.untyped, options: T.untyped, block: T.nilable(T.proc.returns(T.untyped))).returns(::Async::Task) }
    def async(*arguments, parent: nil, **options, &block); end
  end
end
