# Intune Docs Studio contributor guidance

This file is the canonical repository policy for contributors and coding agents.
`CLAUDE.md` and `.github/copilot-instructions.md` are entry-point pointers only;
keep repository rules here rather than copying them between client files.

## Project and runtime

Intune Docs Studio is a Windows PowerShell application that runs a localhost
dashboard and generates customer-owned Intune documentation. The supported
runtime is PowerShell 7 or later (`pwsh`); Windows PowerShell 5.1 is not
supported. Do not install or update PowerShell automatically on a user's
machine. Follow the install guidance in `README.md`.

The app binds directly to localhost. Preserve the existing export, Git
publishing, authentication, and runtime behavior unless the task specifically
requires a change and includes tests for it.

## Customer data and credentials

Treat tenant data, generated documentation, manifests, tokens, browser profiles,
and tenant-specific configuration as customer-owned or sensitive. Never commit,
upload, or copy customer data, credentials, access tokens, tenant identifiers,
or active browser-session material into source, CI, issues, release notes, or
test fixtures. Tests and CI must use synthetic fixtures and must not require a
real Intune tenant. Do not recommend backing up credentials or active browser
sessions as application data.

The optional Graph authentication and portal-session flows have distinct
security boundaries. Do not weaken consent, token handling, loopback, or
data-ownership behavior as incidental cleanup.

## Development and verification

Use PowerShell 7 for scripts and tests. Run focused tests for the changed
behavior, then the existing suites when changes affect shared runtime paths:

```powershell
Invoke-Pester .\tests\*.Tests.ps1 -Output Detailed
node --test .\tests\publishing-ui.test.js .\tests\assessment-ui.test.js .\tests\app-shell-ui.test.js
pwsh -NoProfile -File .\scripts\Test-Repository.ps1
```

Before sharing a customer package, validate and build it with:

```powershell
pwsh -NoProfile -File .\Build-Package.ps1
```

Do not add dependencies or silently change the minimum PowerShell version.
Keep local pre-commit validation lightweight; full tests and package builds
belong in CI. The hook is opt-in:

```powershell
pwsh -NoProfile -File .\scripts\Setup-Hooks.ps1
```

Setup must not replace a configured custom hooks path or bypass any existing
non-sample hook in the default Git hooks directory. If it refuses, preserve
the existing hooks and integrate the repository check manually if desired.
The managed hook lives under
`tests/hooks`, which is a tracked development-only path excluded from the
customer package.

## Branches, versions, and releases

`beta` is the integration branch. Feature branches start from and target
`beta`. `main` is the stable line and accepts only a promotion whose head is
`beta` in this same repository; promotions use a merge commit. Do not target
`main` with feature work or use a fork's `beta` branch for promotion.

The initial version is `0.1.0`. Feature pull requests do not change `VERSION`;
after the one-time bootstrap, any feature-PR edit is rejected, including a
numeric increase. The stable-release pipeline owns version increments (patch
by default, or the selected minor/major increment). Policy and workflow checks
are implemented locally; GitHub enforcement is not active until the required
remote protection and credentials are configured and read back.

**Promoting `beta` to `main`** follows App-Guidance's
[`shared/guidelines/promotion-runbook.md`](https://github.com/Flux76HQ/App-Guidance/blob/main/shared/guidelines/promotion-runbook.md);
the steps as applied here are in `docs/promotion-runbook.md`. Per-app choices:
the release notes are `docs/releases/vX.Y.Z.md`; the owner merges the
promotion; the full test command is the set of checks listed in that runbook
under *Checks and operator update*.

**Every release has release notes.** They are written and reviewed before the
promotion merges, in a normal pull request into `beta` that is merged first, and
they cover everything since the previous stable version, not only the last
change. The stable pipeline refuses to release without them.

Stable promotions and releases happen only when the owner requests them.
Never create or publish a stable release on your own, overwrite an existing
version tag or release, or treat a beta build as a stable release. Review
release notes and the promotion procedure before an authorized promotion.
Beta builds are intended as downloadable ZIP artifacts, not container images.
The current remote read-back is recorded in `docs/baseline-adoption.md`; re-read
live settings before claiming branch protection, hosted checks, or release
credentials are active.

## Operator procedures

`docs/operations.md` is the operator guide for stop-before-update, package
identity checks, customer-output separation, and output backup/restore. Follow
it before replacing application files or restoring tenant output. Keep output,
its manifest, and Git history separate from the application installation; do
not back up or restore access tokens or the portal browser profile.

## Standards and adoption limits

The existing authentication code implements OAuth protocol handling without a
dedicated standards-module dependency. This is a documented standards-module
deviation, not a claim of conformance; replacing it is separate work unless a
task touches a defect in that implementation.

The authoritative 111-topic engineering index, conformance template,
validators, and linked reference workflows were not supplied and the upstream
private repository was not accessible for this adoption. Do not claim full
section 18 or 111-topic conformance, invent a replacement topic list, or
fabricate evidence. Record the missing-source gap in the adoption matrix and
request the authoritative materials before completing that follow-up.

The source for this repository's adopted baseline is the supplied
[App-Guidance project baseline and promotion runbook](https://github.com/Flux76/App-Guidance).
The upstream repository is private or unavailable in this task; this link is a
source reference, not a claim that the linked materials were independently
verified.
