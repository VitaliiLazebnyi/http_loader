# Contributing to http_loader

Thanks for your interest in contributing! Bug reports and pull requests are welcome on
GitHub at <https://github.com/VitaliiLazebnyi/http_loader>.

## Getting started

The repository develops on the Ruby in `.ruby-version` (4.0.9); Ruby 3.3 and newer are
supported.

```bash
bundle install
git config core.hooksPath .githooks   # optional: run the fast gates before every commit
```

## Before opening a pull request

Run the verification suite. Every gate is enforced in CI and fails the build:

```bash
bundle exec rake
```

That runs, in order:

| Task | Gate |
| --- | --- |
| `rake spec` | RSpec; 100% line **and** branch coverage (with `CI=1`), no pending/skipped/focused examples |
| `rake rubocop` | RuboCop with all plugins (`.rubocop.yml`); no todo file, no inline directives |
| `rake suppressions` | no inline suppression anywhere (`script/forbidden_suppressions.sh`, see below) |
| `rake typecheck` | Tapioca regenerates the gem RBIs, then `srb tc` must report no errors (`lib/` is `typed: strong`) |
| `rake yard` | YARD must report 100% documented |
| `rake reek` / `rake flay` | no code smell (`.reek.yml`) and no structural duplication (Flay mass 24) |
| `rake audit` | bundler-audit: no dependency with a known vulnerability |

Not part of the default task, but also enforced in CI:

```bash
bundle exec rake mutant     # mutation testing; every mutation must be killed (see .mutant.yml)
bundle exec rake outdated   # every gem at its newest release, except the documented holds
gem build http_loader.gemspec
```

Mutant parses the code with the `parser` gem, whose newest release only has a grammar for
Ruby 3.3; run it on Ruby 3.3.13 (CI does) to avoid the `parser/current` warning. The AST,
and therefore the mutations, are identical on newer Rubies. Mutation runs are slow; while
iterating, run one subject at a time, e.g. `bundle exec mutant run 'HttpLoader::Client::Pacing*'`.

The Docker image is linted and scanned in CI as well:

```bash
docker build -t http_loader:ci .     # hadolint-clean Dockerfile, pinned base digest
# Trivy scans the built image; the build fails on any fixable HIGH/CRITICAL CVE.
```

## Rules

- **No inline suppressions.** Nothing may silence a linter, scanner, type checker, warning
  or test in place: no `rubocop:disable`, `:nocov:`, `:reek:`, `mutant:disable`,
  `gitleaks:allow`, `nosec`, `hadolint ignore`, `skip`/`pending`/`focus`, `$VERBOSE = nil`,
  `T.unsafe`, `# typed: false`/`ignore` in `lib/`, and so on. Fix the cause. A rule that
  genuinely cannot apply to a file is configured narrowly in the tool's own configuration
  file, with the reason written next to it (see `.reek.yml`). `script/forbidden_suppressions.sh`
  enforces this and runs in CI and in the pre-commit hook.
  - `T.cast`/`T.must` are **not** suppressions: `lib/` is `# typed: strong`, which requires
    them, and they are checked at runtime by sorbet-runtime. `T.unsafe` (which disables
    checking) is forbidden.
  - The sole configured warning opt-out is `Warning[:experimental] = false` at the CLI and
    spec entry points, for the `IO::Buffer` experimental-feature notice that the async fiber
    scheduler triggers. Deprecation and performance warnings stay on.
- **No warnings.** Tests run with `-W:deprecated`, and every workflow ends
  with a "Warning gate" job (`script/warning_gate.sh`) that fails the run when the log of any
  job contains a warning or a deprecation notice.
- **Behavior is specified.** Every behavioral fix needs a regression spec, and every
  surviving mutant needs a test that kills it. Prefer a real test over everything else; when a
  mutation cannot change observable behavior, prefer simpler code that removes it (e.g. a
  redundant `.utc`/`Float()`/leading `::`, or a `type_alias` constant for an inline generic).
  Only a mutation that is *provably* equivalent — no runtime test can tell it apart, such as a
  Sorbet-only assertion or an OpenSSL/`getconf`/`/proc` API that accepts interchangeable
  inputs — may carry a narrow, per-case ignore in `.mutant.yml`, each with a comment stating
  why it is equivalent. Never a broad or blanket ignore, and never an inline `mutant:disable`.
- `lib/` is `# typed: strong`. Add missing external constants to `sorbet/rbi/custom/*.rbi`
  rather than loosening the typed sigil.
- Update `CHANGELOG.md` for user-visible changes.

## Dependencies

Every gem, GitHub Action (pinned to a SHA), and the Docker base image (pinned to a digest)
is kept at its newest release. A deliberate hold is documented in `script/outdated_holds.yml`
with the exact upstream constraint that blocks it, and `rake outdated` fails for any other
outdated gem (or a hold that is no longer needed). Dependabot opens weekly update PRs.
