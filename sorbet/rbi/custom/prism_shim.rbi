# typed: true
# frozen_string_literal: true

# Shim for a dangling reference in the gem-shipped `prism-1.9.0/rbi/prism.rbi`,
# which annotates `Prism.lex_compat` as returning `Prism::LexCompat::Result` but
# never ships a definition for `Prism::LexCompat`. Sorbet auto-loads that RBI via
# bundler discovery (it is not suppressible through `--ignore=vendor/`), so without
# this shim `srb tc` fails with a 5002 "Unable to resolve constant `LexCompat`".
module Prism
  class LexCompat
    class Result; end
  end
end
