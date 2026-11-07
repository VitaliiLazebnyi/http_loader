# Changelog

All notable changes to this project are documented in this file. The format is based on
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and this project adheres to
[Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## Unreleased

### Added

- **Hardened verification suite.** RuboCop (all plugins, no todo), Sorbet via Tapioca-generated RBIs (`lib/` is
  `# typed: strong`), YARD 100%, Reek, Flay, bundler-audit, an "outdated" dependency gate with documented holds,
  mutation testing (Mutant), an inline-suppression scanner, and a warning gate that fails any CI job log containing a
  warning or deprecation. See `CONTRIBUTING.md`. Pinned, least-privilege GitHub Actions workflows; a hadolint-clean
  Dockerfile pinned to the newest `ruby:4.0.9` digest and scanned with Trivy.
- Ruby 3.3+ is now supported (tested on 3.3.13, 3.4.12 and 4.0.9).
- **Native numeric parameter validation (REQ-CLI-023).** `Client::Config#validate!` and `Harness::Config#validate!`
  reject out-of-bounds numeric flags (e.g. `--connections_count=0`, negative timing/jitter values) with a clean
  `Configuration Error` instead of hanging or crashing with an uncaught backtrace.
- Shared best-effort `RLIMIT_NOFILE` bump applied by the standalone client as well as the harness.
- `HttpLoader::CLI` runs the `client`, `server` and `harness` subcommands (`bin/http_loader` only calls it), and
  `CliArgs::ClientOptions` / `CliArgs::HarnessOptions` build type-checked configurations from parsed flags.
- Bounded TCP readiness poll for the spawned server, replacing a fixed `sleep`.
- Always-on status channel so `--track_status_codes` no longer silently requires `--verbose`.

### Changed

- Shared `Client::Pacing` mixin for the jittered-sleep and keep-alive-budget arithmetic that was previously duplicated
  across the client engine and the HTTP/Slowloris sessions.
- Dropped the deprecated `Async::Task#sleep` in favor of the reactor-aware `Kernel#sleep`.
- The mock server sends Rack 3 (lowercase) response header names, as the Rack SPEC requires.
- The CLI drops only Ruby's "IO::Buffer is experimental" notice instead of every experimental-feature warning.
- Dependencies updated to their newest releases (2026-11-07): rack 3.2.8, sorbet and sorbet-runtime 0.6.13645, rubocop
  1.92.2, rubocop-md 3.0.0, RSpec 3.13.x patch releases, Bundler 4.0.24, the `ruby:4.0.9` base image digest, Trivy
  0.76.2, and the pinned `ruby/setup-ruby`, `github/codeql-action` and `zizmorcore/zizmor-action` SHAs.

### Fixed

- Slowloris mode against an HTTPS target raised `TypeError` on its first write: the socket was typed as `IO`, but
  over TLS it is an `OpenSSL::SSL::SSLSocket`.
- CI gates: RuboCop offenses and Sorbet `--typed strong` errors now pass (added a prism RBI shim).
- Credentialed proxy URLs (`user:pass@host`) are parsed tolerantly instead of raising.
- Malformed / hostless `--url` values fail fast with a clear error.
- `/proc/<pid>/stat` CPU parsing is robust to process names containing spaces/parens.
- Linux connection counting now counts only ESTABLISHED sockets, matching the macOS path.
- Dynamic `CLK_TCK`/page-size resolution; anchored `(ESTABLISHED)` lsof matching.
- Harness cleanup reaps children and escalates SIGINT → SIGKILL; child processes are spawned by absolute path so the
  harness works from any working directory.
- Log files are written by a single writer, preventing interleaved/truncated telemetry reads.
- The `thread_limit` telemetry metric is now live (emitted for `ThreadError`/`EAGAIN`).

## 0.1.0

- Initial release: asynchronous high-concurrency HTTP/HTTPS load-testing client, mock server, and orchestration harness
  with resource/telemetry monitoring.
