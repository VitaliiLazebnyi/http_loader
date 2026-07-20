# Changelog

All notable changes to this project are documented in this file. The format is based
on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and this project adheres
to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added
- **Native numeric parameter validation (REQ-CLI-023).** `Client::Config#validate!` and
  `Harness::Config#validate!` reject out-of-bounds numeric flags (e.g. `--connections_count=0`,
  negative timing/jitter values) with a clean `Configuration Error` instead of hanging or
  crashing with an uncaught backtrace.
- Shared best-effort `RLIMIT_NOFILE` bump applied by the standalone client as well as the harness.
- Bounded TCP readiness poll for the spawned server, replacing a fixed `sleep`.
- Always-on status channel so `--track_status_codes` no longer silently requires `--verbose`.

### Fixed
- CI gates: RuboCop offenses and Sorbet `--typed strong` errors now pass (added a prism RBI shim).
- Credentialed proxy URLs (`user:pass@host`) are parsed tolerantly instead of raising.
- Malformed / hostless `--url` values fail fast with a clear error.
- `/proc/<pid>/stat` CPU parsing is robust to process names containing spaces/parens.
- Linux connection counting now counts only ESTABLISHED sockets, matching the macOS path.
- Dynamic `CLK_TCK`/page-size resolution; anchored `(ESTABLISHED)` lsof matching.
- Harness cleanup reaps children and escalates SIGINT → SIGKILL; child processes are spawned
  by absolute path so the harness works from any working directory.
- Log files are written by a single writer, preventing interleaved/truncated telemetry reads.
- The `thread_limit` telemetry metric is now live (emitted for `ThreadError`/`EAGAIN`).

## [0.1.0]

### Added
- Initial release: asynchronous high-concurrency HTTP/HTTPS load-testing client, mock server,
  and orchestration harness with resource/telemetry monitoring.
