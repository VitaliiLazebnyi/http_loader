# typed: strict

module Parser
  module Source
    class Comment
      sig { returns(String) }
      def text; end
    end
  end
end

module RuboCop
  module AST
    class ProcessedSource
      sig { returns(T::Array[::Parser::Source::Comment]) }
      def comments; end
    end
  end

  module Cop
    module AutoCorrector
    end

    class Corrector
      sig { params(node: T.untyped, new_text: String).void }
      def replace(node, new_text); end
    end

    class Base
      sig { returns(::RuboCop::AST::ProcessedSource) }
      def processed_source; end

      sig do
        params(
          node: T.untyped,
          blk: T.nilable(T.proc.params(corrector: ::RuboCop::Cop::Corrector).void)
        ).void
      end
      def add_offense(node, &blk); end
    end
  end
end
