# Defect Log

Document all historically encountered violations, network edge cases, or memory-leak profiles strictly referenced via an alphanumeric BUG ID logically linked to its original Architectural Requirement (e.g. `REQ-NET-001`).

## Resolved

- **BUG-QUAL-001 (REQ-QUAL-002 / REQ-QUAL-003)** — CI was red: RuboCop reported offenses and `srb tc --typed strong` reported type errors. All lint offenses fixed and Sorbet made green (including a prism RBI shim); the CI gates now pass.
- **BUG-CLI-001 (REQ-CLI-023)** — No numeric validation existed; plausible inputs (`--max_concurrent_connections=0`, negative timings/jitter, malformed `--url`, non-numeric values) hung or crashed. `Config#validate!` now fast-fails with a clean `Configuration Error`.
- **BUG-CLI-002 (REQ-CLI-017)** — Credentialed proxy URLs raised `URI::InvalidURIError`. Proxy entries are now parsed tolerantly.
- **BUG-CLI-003 (REQ-CLI-014)** — `--track_status_codes` silently required `--verbose`. Status tracking now uses an always-on log channel.
- **BUG-NET-001 (REQ-NET-002)** — The `thread_limit` telemetry metric counted a token no code emitted. `ThreadError`/`EAGAIN` are now classified as `ERROR_THREADLIMIT`.
- **BUG-SRV-001 (REQ-SRV-002)** — The harness redirect and the client Logger wrote the same log files concurrently, corrupting telemetry reads. The Logger is now the sole writer of `client.log`/`client.err`.

See `CHANGELOG.md` for the full list of fixes.

*No currently active unresolved defects.*
