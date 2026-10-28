#!/usr/bin/env bash
# Fails when a tracked file silences a linter, scanner, type checker, warning or test, or weakens
# typing. Inline suppressions are forbidden everywhere in this repository (see CONTRIBUTING.md):
# fix the cause. Markdown files are skipped because they document the rules.
set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/.."

# This script and the workflow files that call it name the patterns, so they are not scanned.
files=$(git ls-files -z -- . ':(exclude)*.md' ':(exclude)script/forbidden_suppressions.sh' \
  ':(exclude)sorbet/rbi/gems' \
  | tr '\0' '\n')

status=0
check() {
  local description=$1 pattern=$2 scope=${3:-.} ignore=${4:-}
  local hits
  hits=$(printf '%s\n' "$files" | grep -E "^${scope}" | xargs -r grep -nEH -e "$pattern" -- || true)
  [ -n "$ignore" ] && hits=$(printf '%s\n' "$hits" | grep -vE -e "$ignore" || true)
  if [ -n "$hits" ]; then
    printf 'Forbidden (%s):\n%s\n\n' "$description" "$hits"
    status=1
  fi
}

check 'RuboCop directive' 'rubocop:(disable|enable|todo)'
check 'Reek suppression' ':reek:'
check 'SimpleCov exclusion' ':nocov:'
check 'mutant suppression' 'mutant:disable'
check 'gitleaks allow' 'gitleaks:allow'
check 'zizmor ignore' 'zizmor: ?ignore'
check 'shellcheck disable' 'shellcheck +disable'
check 'hadolint ignore' 'hadolint +ignore'
check 'nosec' 'nosec'
# Blanket warning silencing. The IO::Buffer experimental-feature category is opted out via
# `Warning[:experimental] = false` at the entry points (documented in CONTRIBUTING); any blanket
# silencer is forbidden, as is turning off every category.
check 'warning silencing' '[$]VERBOSE *= *nil|Warning\.ignore|silence_warnings|[$]stderr *= *File::NULL|Warning\[:all\] *= *false'
# The lone exception to "skip" is SimpleCov's `skip '/spec/'` coverage filter in spec_helper.rb
# (the non-deprecated replacement for add_filter); it is not an RSpec example skip.
check 'skipped or focused test' '^[[:space:]]*(xit|xdescribe|xcontext|fit|fdescribe|fcontext|skip|pending)([[:space:]]|\()|focus: *true|, *:focus|, *(skip|pending): ' '(spec|script)/' "spec/spec_helper.rb:[0-9]+:[[:space:]]*skip '/spec/'"
check 'Sorbet escape hatch' 'T\.unsafe\b|typed: *(false|ignore)' 'lib/'

exit "$status"
