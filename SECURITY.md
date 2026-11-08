# Security policy

## Supported versions

Security fixes are applied to the latest released version of `http_loader`.

## Reporting a vulnerability

Please report suspected vulnerabilities privately rather than opening a public issue.

- Preferred: GitHub's **Report a vulnerability** flow under the repository's **Security** tab (private
  vulnerability reporting).
- Alternatively, email <vitalii.lazebnyi.github@gmail.com> with the details.

Include a description of the issue, the affected version and a minimal reproduction if possible. You can expect an
acknowledgement within a few business days. Once a fix is prepared, a patched release is published to RubyGems and
the advisory is disclosed.

## Scope

`http_loader` is a load-testing tool: its client opens as many HTTP connections to the targets it is given as it is
told to, and its mock server listens on a port of the host. Run it only against systems you are allowed to test.

## Supply-chain safeguards

Releases are built by the tag-triggered workflow, from the `release` environment, only after every quality gate
passes; they are signed with the certificate in `certs/` and published to RubyGems through OIDC trusted publishing.
CI runs bundler-audit, OSV-Scanner, `npm audit`, dependency review, gitleaks, CodeQL, zizmor, a Trivy scan of the
Docker image and the OpenSSF Scorecard; every job runs behind a network egress allow list
(`step-security/harden-runner`). Every GitHub Action is pinned to a full commit SHA, every downloaded tool to its
SHA-256, and Dependabot proposes updates after a one-week cooldown.

