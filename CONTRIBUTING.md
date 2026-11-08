# Contributing to http_loader

Bug reports and pull requests are welcome on GitHub at <https://github.com/VitaliiLazebnyi/http_loader>.

## Getting started

The repository develops on the Ruby in `.ruby-version` (4.0.9); Ruby 3.3 and newer are supported.

```bash
bundle install
git config core.hooksPath .githooks   # run the fast gates before every commit
```

## Before opening a pull request

Run every check of CI locally, with the same settings and the same pinned tools:

```bash
script/check
```

It runs each of the following with every Ruby warning enabled (`RUBYOPT=-w -W:deprecated -W:performance`), and fails
on any finding and on any warning in the output of any of them:

- `bundle exec rake`, which runs, in order:
  - `rake spec`: RSpec with 100% line **and** branch coverage; any example that writes unasserted output to stdout or
    stderr fails, and Sorbet's runtime signature checks stay on (only an RSpec double may stand in for a typed
    collaborator);
  - `rake rubocop`: RuboCop with **every** cop enabled (`EnabledByDefault`), including those of rubocop-md,
    -packaging, -performance, -rake, -rspec, -sorbet, -thread_safety and -yard; `.rubocop.yml` gives the reason for
    each of the few cops that cannot apply; no todo file;
  - `rake suppressions`: no inline suppression anywhere (`script/forbidden_suppressions.sh`, see below);
  - `rake typecheck`: Tapioca generates the gem RBIs, then `srb tc` reports no errors; `lib/` is `# typed: strong`,
    the scripts and spec support modules `# typed: strict`, the specs `# typed: true` (with Sorbet's RSpec support);
  - `rake yard`: YARD reports 100% documented, private methods included, without warnings;
  - `rake reek`, `rake flay`, `rake flog`, `rake debride`: no code smell (Reek's default configuration, every
    detector), no structural duplication (Flay's default mass, 16), no method with a Flog score above 20, and no
    method without a caller, in `lib/`, `bin/`, `script/` and the `Rakefile`;
  - `rake audit`: bundler-audit: no dependency with a known vulnerability;
- `rake outdated`: every gem at its newest release, except the holds in `script/outdated_holds.yml`;
- `gem build --strict` and the executable itself;
- `rake mutant`: mutation testing on Ruby 3.3.13; every mutation must be killed (`.mutant.yml`);
- `script/lint.sh`: the linters and scanners of every other file type, each at its strictest setting, installed at
  pinned versions by `script/install_tools.sh` (`tools/`):
  - [actionlint](https://github.com/rhysd/actionlint), with ShellCheck on every `run:` block, and
    [zizmor](https://github.com/zizmorcore/zizmor) with its pedantic persona and online audits: the workflows;
  - [ShellCheck](https://www.shellcheck.net/) with every optional check and [shfmt](https://github.com/mvdan/sh):
    every shell script;
  - [yamllint](https://github.com/adrienverge/yamllint) with every rule, strict (`.yamllint.yml`);
  - [markdownlint-cli2](https://github.com/DavidAnson/markdownlint-cli2) with every rule (`.markdownlint-cli2.yaml`);
  - [Taplo](https://taplo.tamasfe.dev/): the TOML files;
  - [typos](https://github.com/crate-ci/typos): the spelling of every tracked file (`_typos.toml`);
  - [hadolint](https://github.com/hadolint/hadolint): the Dockerfile, failing on every finding down to style level
    (`.hadolint.yaml`);
  - [editorconfig-checker](https://github.com/editorconfig-checker/editorconfig-checker): every tracked file against
    `.editorconfig`;
  - [gitleaks](https://github.com/gitleaks/gitleaks): the full git history, for committed secrets;
  - [OSV-Scanner](https://github.com/google/osv-scanner): every committed lockfile (the gems, and the npm and PyPI
    linters of `tools/`), failing on any known vulnerability of any severity;
  - `npm audit` at its lowest threshold (`low`), and `npm audit signatures`: the npm linters of `tools/`.

CI runs the same checks, the RSpec suite on every supported Ruby, the Docker image build with a Trivy scan that fails
on any fixable vulnerability of any severity, and the GitHub services: CodeQL, the OpenSSF Scorecard of this
repository, and dependency review on pull requests. Dependency review fails on a vulnerable (of any severity) or
denied dependency, and `script/scorecard_check` fails on any added dependency whose OpenSSF Scorecard is below 3,
unless `.github/dependency-review.yml` allows that exact package version at that score with a written reason. Every
job runs behind [Harden-Runner](https://github.com/step-security/harden-runner), which blocks any network access
outside the endpoints its workflow lists.

Mutation testing is the one gate that does not run on the Ruby of `.ruby-version`: the newest Mutant and Unparser load
the `parser` gem's `parser/current`, which only has grammars up to Ruby 3.3 and warns on any newer Ruby.
`script/check` runs it on Ruby 3.3.13 (through [mise](https://mise.jdx.dev/) when another Ruby is active). While
iterating, run one subject at a time, e.g. `bundle exec mutant run 'HttpLoader::Client::Pacing*'`.

With `-w`, the newest releases of a few dependencies warn about their own code. `script/upstream_warnings.rb` (loaded
through `RUBYOPT`, and by `spec/spec_helper.rb`) drops exactly those warnings, each matched by gem version, file and
message; every other warning is printed and fails the build.

## Rules

- **No inline suppressions.** Nothing may silence a linter, scanner, type checker, warning or test in place: no
  `rubocop:disable`, `:nocov:`, `:reek:`, `mutant:disable`, `:nodoc:`, `gitleaks:allow`, `nosec`,
  `markdownlint-disable`, `yamllint disable`, `hadolint ignore`, `T.unsafe`/`T.bind`/`T.untyped` in `lib/`,
  `$VERBOSE = nil`, `Warning[:category] = false`, `skip`/`pending`/`focus`, and so on. Fix the cause. A rule that
  cannot apply to a file is configured narrowly in the tool's configuration file, with the reason written next to it.
  `T.cast` and `T.must` are not suppressions: they are checked at runtime by sorbet-runtime.
- **No warnings.** Every Ruby command runs with all warnings enabled, and the specs fail on any output they do not
  assert. Every workflow ends with a "Warning gate" job (`script/warning_gate.sh`) that fails the run when the log of
  any job contains a warning or a deprecation notice; `script/check` applies the same check to its own output.
- **Behavior is specified.** Every behavioral fix needs a regression spec, and every surviving mutant needs a test that
  kills it (or, when the mutation cannot change observable behavior, simpler code).
- **Dependencies are current.** `rake outdated` fails for any gem that is not at its newest release, unless
  `script/outdated_holds.yml` names it together with the upstream constraint that blocks the update.
- `lib/` is `# typed: strong`. Add missing external constants to `sorbet/rbi/custom/*.rbi` rather than loosening the
  typed sigil.
- Record requirements in `REQUIREMENTS.md`, defects in `BUGS.md` and user-visible changes in `CHANGELOG.md`.
