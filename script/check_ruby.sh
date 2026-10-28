#!/usr/bin/env bash
# Prints the active Ruby and fails unless it is exactly the expected version.
# Usage: script/check_ruby.sh [expected-version]   (defaults to the contents of .ruby-version)
set -euo pipefail

expected="${1:-$(tr -d '[:space:]' < "$(dirname "$0")/../.ruby-version")}"
ruby -v
actual="$(ruby -e 'print RUBY_VERSION')"
if [ "$actual" != "$expected" ]; then
  echo "Expected Ruby ${expected} but running ${actual}" >&2
  exit 1
fi
