#!/usr/bin/env bash
# Installs the pinned linters and scanners that script/lint.sh runs into tmp/tools, for CI and for script/check:
#   - from PyPI (tools/requirements.txt, every file verified against its hash): ShellCheck, shfmt, Taplo, typos,
#     yamllint, zizmor;
#   - from npm (tools/package-lock.json, verified against its integrity hashes): markdownlint-cli2;
#   - from their GitHub releases (each file verified against its published SHA-256 first): actionlint,
#     editorconfig-checker, gitleaks and hadolint.
# Dependabot keeps tools/ current; the release versions below are kept current by hand.
# Usage: script/install_tools.sh   (prints the PATH entries to use)
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
tools="${root}/tmp/tools"
mkdir -p "${tools}/bin" "${tools}/downloads"

system=$(uname -s)
machine=$(uname -m)
platform="${system}-${machine}"
case "${platform}" in
  Linux-x86_64)
    actionlint=(actionlint_1.7.12_linux_amd64.tar.gz
      8aca8db96f1b94770f1b0d72b6dddcb1ebb8123cb3712530b08cc387b349a3d8)
    editorconfig=(editorconfig-checker-linux-amd64.tar.gz
      44efaef3ed14c6ab52eb87481d78e5e5c204796dccf26e2f4598a61ba17f8003)
    gitleaks=(gitleaks_8.30.1_linux_x64.tar.gz
      551f6fc83ea457d62a0d98237cbad105af8d557003051f41f3e7ca7b3f2470eb)
    hadolint=(hadolint-linux-x86_64
      c7187db94eeeeca956519a6af171adc31453941a1e777961f6e680f697c8c507)
    ;;
  Darwin-arm64)
    actionlint=(actionlint_1.7.12_darwin_arm64.tar.gz
      aba9ced2dee8d27fecca3dc7feb1a7f9a52caefa1eb46f3271ea66b6e0e6953f)
    editorconfig=(editorconfig-checker-darwin-all.tar.gz
      ff59f57717d95fc62b8e372c8051dbbb766f7d660942409a85d027b0feb2422c)
    gitleaks=(gitleaks_8.30.1_darwin_arm64.tar.gz
      b40ab0ae55c505963e365f271a8d3846efbc170aa17f2607f13df610a9aeb6a5)
    hadolint=(hadolint-macos-arm64
      5c09f3213f8e40406abe048233d985eebef336d4a6a20021be47fadb6cf480a2)
    ;;
  *)
    echo "script/install_tools.sh has no pinned binaries for ${platform}" >&2
    exit 1
    ;;
esac

# Downloads a release archive, verifies it and extracts one executable from it into tmp/tools/bin.
# Arguments: release URL prefix, archive name, SHA-256, path of the executable inside the archive.
release() {
  local base=$1 archive=$2 sha256=$3 member=$4
  local file="${tools}/downloads/${archive}"
  curl --fail --silent --show-error --location --output "${file}" "${base}/${archive}"
  printf '%s  %s\n' "${sha256}" "${file}" | shasum --algorithm 256 --check --strict --status
  tar -xzf "${file}" -C "${tools}/bin" "${member}"
}

release https://github.com/rhysd/actionlint/releases/download/v1.7.12 "${actionlint[@]}" actionlint
release https://github.com/editorconfig-checker/editorconfig-checker/releases/download/v4.0.2 "${editorconfig[@]}" \
  editorconfig-checker
release https://github.com/gitleaks/gitleaks/releases/download/v8.30.1 "${gitleaks[@]}" gitleaks

# hadolint is released as a bare executable, not an archive.
hadolint_file="${tools}/bin/hadolint"
curl --fail --silent --show-error --location --output "${hadolint_file}" \
  "https://github.com/hadolint/hadolint/releases/download/v2.15.1/${hadolint[0]}"
printf '%s  %s\n' "${hadolint[1]}" "${hadolint_file}" | shasum --algorithm 256 --check --strict --status
chmod +x "${hadolint_file}"

python3 -m venv --clear "${tools}/venv"
"${tools}/venv/bin/pip" install --quiet --disable-pip-version-check --require-hashes --only-binary :all: \
  --requirement "${root}/tools/requirements.txt"

npm ci --prefix "${root}/tools" --silent

printf '%s\n' "${tools}/bin" "${tools}/venv/bin" "${root}/tools/node_modules/.bin"
