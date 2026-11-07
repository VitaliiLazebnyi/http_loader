#!/usr/bin/env bash
# Fails when a tracked file silences a linter, scanner, type checker, warning or test, or weakens typing.
# Inline suppressions are forbidden everywhere in this repository (see CONTRIBUTING.md): fix the cause.
# Markdown files are skipped because they document the rules.
set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/.."

# This script names the patterns, so it is not scanned for them.
files=$(git ls-files -z -- . ':(exclude)*.md' ':(exclude)script/forbidden_suppressions.sh' \
  ':(exclude)sorbet/rbi/gems' | tr '\0' '\n')

status=0
check() {
  local description=$1 pattern=$2 scope=${3:-.}
  local hits
  hits=$(printf '%s\n' "${files}" | grep -E "^${scope}" | xargs -r grep -nEH -e "${pattern}" -- || true)
  if [[ -n ${hits} ]]; then
    printf 'Forbidden (%s):\n%s\n\n' "${description}" "${hits}"
    status=1
  fi
}

check 'RuboCop directive' 'rubocop:(disable|enable|todo)'
check 'Reek suppression' ':reek:'
check 'SimpleCov exclusion' ':nocov:|nocov_token|(add_filter|skip)\b.*(lib|exe)\b'
check 'mutant suppression' 'mutant:disable'
check 'YARD exclusion' ':nodoc:|@!visibility +private|@private'
check 'gitleaks allow' 'gitleaks:allow'
check 'zizmor ignore' 'zizmor: ?ignore'
check 'shellcheck directive' 'shellcheck +(disable|source=/dev/null)'
check 'yamllint directive' 'yamllint (disable|enable)'
check 'editorconfig-checker directive' 'editorconfig-checker-(disable|enable)'
check 'taplo directive' 'taplo:'
check 'hadolint directive' 'hadolint +(ignore|global)'
check 'markdownlint directive' 'markdownlint-(disable|enable|capture|restore|configure-file)'
check 'typos directive' 'typos: ?(ignore|off|disable)|spellchecker: ?(disable|ignore)'
check 'LGTM/CodeQL suppression' 'lgtm\[|codeql\[|codeql-disable|lgtm: ?ignore'
check 'nosec / noqa' 'nosec|noqa'
check 'warning silencing' '[$]VERBOSE *= *(nil|false)|Warning\.ignore|Warning\[:[a-z_]+\] *= *false|silence_warnings'
check 'warning silencing' '[$]stderr *= *File::NULL|RUBYOPT=[^ ]*-W0|-W0\b|-W:no-'
check 'real network access in specs' 'allow_net_connect!|WebMock\.disable!' 'spec/'
skipped='(xit|xspecify|xexample|xdescribe|xcontext|fit|fspecify|fexample|fdescribe|fcontext|skip|pending)'
check 'skipped or focused test' "^[[:space:]]*${skipped}([[:space:]]|\\()" '(spec|script)/'
check 'skipped or focused test' 'focus: *true|, *:focus|, *(skip|pending): ' '(spec|script)/'
# lib/ is `typed: strong`. T.cast stays allowed there: it is the runtime-checked boundary where OptionParser's
# untyped values and the parsed option hashes enter typed code.
check 'Sorbet escape hatch' 'T\.(unsafe|bind|untyped)\b|T::Sig::WithoutRuntime' '(lib|bin)/'
check 'Sorbet sigil weaker than strong' 'typed: *(ignore|false|true|strict)\b' 'lib/'
check 'Sorbet escape hatch' 'T\.unsafe\b|typed: *ignore' '(spec|sorbet)/'
check 'Sorbet sigil weaker than true' 'typed: *(false|ignore)' '(script|spec)/'

exit "${status}"
