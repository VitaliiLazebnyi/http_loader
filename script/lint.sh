#!/usr/bin/env bash
# Runs the linters and scanners of every file type that is not Ruby, each at its strictest setting, with the
# tools script/install_tools.sh installs (the same pinned versions in CI and locally). Every finding fails.
#
# Usage: script/lint.sh [CHECK...]   (all checks by default)
# Every check runs, also after one failed; each check function stops at its first failing command (`&&`), since
# errexit does not apply inside a function called as the left operand of `||`.
# Checks: suppressions actionlint zizmor shellcheck shfmt yamllint markdownlint typos taplo hadolint editorconfig
# gitleaks osv npmaudit
# zizmor runs its online audits too, so it needs GH_TOKEN (locally, the token of `gh auth token` is used).
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "${root}"
PATH="${root}/tmp/tools/bin:${root}/tmp/tools/venv/bin:${root}/tools/node_modules/.bin:${PATH}"
export PATH

# The tracked files of one kind, one per line.
tracked() {
  git ls-files -- "$@"
}

# The tracked shell scripts, found by their extension or shebang (shfmt's detection).
shell_scripts() {
  git ls-files -z | xargs -0 shfmt --find
}

check_suppressions() { script/forbidden_suppressions.sh; }

# The `run:` blocks of the workflows go through ShellCheck as well, with every optional check.
check_actionlint() { SHELLCHECK_OPTS='--enable=all --severity=style' actionlint; }

check_zizmor() {
  if [[ -z ${GH_TOKEN:-} ]]; then
    GH_TOKEN=$(gh auth token) || return 1
    export GH_TOKEN
  fi
  zizmor --persona pedantic --format plain .github
}

check_shellcheck() {
  local scripts
  scripts=$(shell_scripts)
  xargs shellcheck --enable=all --severity=style <<<"${scripts}"
}

check_shfmt() {
  local scripts
  scripts=$(shell_scripts)
  xargs shfmt --diff --simplify --indent 2 --case-indent --binary-next-line <<<"${scripts}"
}

check_yamllint() {
  local files
  files=$(tracked '*.yml' '*.yaml')
  xargs yamllint --strict <<<"${files}"
}

check_markdownlint() { markdownlint-cli2; }

check_typos() { typos; }

check_taplo() {
  local files
  files=$(tracked '*.toml')
  xargs taplo lint <<<"${files}" && xargs taplo format --check <<<"${files}"
}

# The Dockerfile, at hadolint's lowest failure threshold (style), configured in .hadolint.yaml.
check_hadolint() { hadolint Dockerfile; }

check_editorconfig() { editorconfig-checker; }

check_gitleaks() { gitleaks git --redact --verbose --exit-code 1 .; }

# Every known vulnerability, of any severity, in every lockfile: the gems of both bundles, the npm and PyPI linters.
# OSV-Scanner names a lockfile by its parser when the file name is not the conventional one.
check_osv() {
  osv-scanner scan source --lockfile Gemfile.lock --lockfile Gemfile.lock:typecheck.gemfile.lock \
    --lockfile tools/package-lock.json --lockfile requirements.txt:tools/requirements.txt
}

# npm's own advisory database at its lowest threshold, and the registry signatures and provenance attestations of
# every installed package.
check_npmaudit() {
  npm audit --prefix tools --audit-level=low && npm audit signatures --prefix tools
}

all=(suppressions actionlint zizmor shellcheck shfmt yamllint markdownlint typos taplo hadolint editorconfig gitleaks
  osv npmaudit)
checks=("$@")
[[ ${#checks[@]} -gt 0 ]] || checks=("${all[@]}")

failed=()
for check in "${checks[@]}"; do
  [[ " ${all[*]} " == *" ${check} "* ]] || {
    echo "Unknown check: ${check}" >&2
    exit 2
  }
  echo "==> ${check}"
  "check_${check}" || failed+=("${check}")
done

if [[ ${#failed[@]} -gt 0 ]]; then
  echo "Failed: ${failed[*]}" >&2
  exit 1
fi
echo "All checks passed: ${checks[*]}"
