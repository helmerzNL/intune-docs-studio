# App baseline and beta release design

## Scope and approved decisions

Adopt the applicable parts of the supplied App-Guidance project baseline and
promotion runbook for Intune Docs Studio, a Windows PowerShell 7 application
with a localhost dashboard and downloadable ZIP distribution.

The owner approved:

- `beta` becomes the integration and GitHub default branch.
- Feature pull requests target `beta`.
- `main` is the stable line and accepts only promotions from this repository's
  `beta`, using a merge commit.
- Promotions happen only when the owner requests them.
- `VERSION` starts at `0.1.0`. Feature pull requests do not change it.
- The pipeline raises the version on stable promotion, patch by default, with
  `version:minor` and `version:major` labels selecting larger increments.
- Protect `main` with pull requests and required checks where supported by the
  repository's GitHub plan.
- Distribute beta and stable ZIPs, not container images.

This work does not promote or publish the existing Azure DevOps publishing and
PowerShell runtime changes. Preserve that uncommitted work. Bootstrap the remote
`beta` branch from the current remote `main`, not from a mixed local working tree.
Prepare adoption on the existing feature branch without merging it into `main`.

## Canonical guidance

Add a root `AGENTS.md` containing the repository-specific development, testing,
runtime, data ownership, branch, versioning, and release rules. Add thin
`CLAUDE.md` and `.github/copilot-instructions.md` pointers, without duplicating
rules. Follow the app's documented promotion procedure and link the supplied
upstream App-Guidance runbook as its source.

Record a requirement/control matrix for applicable baseline rules. Distinguish
automated controls, review requirements, deferred work, and non-applicable rules.
Do not label a review-only rule as automatically enforced. Do not copy the
Flux76-wide merge authorization into this differently owned repository: routine
PR merging is not part of this adoption task, and stable promotion remains
owner-requested.

No client-specific skill or MCP configuration is being introduced. If introduced
later, its supported-client parity and tracked configuration examples require a
corresponding guard. Use `.github/github-app.yml` for Copilot app repository
configuration if configuration is necessary; the instruction pointer remains a
separate client entry point.

## Versioning and build metadata

`VERSION` contains strict `MAJOR.MINOR.PATCH`; the initial committed value is
`0.1.0`. Bootstrap this file once; subsequent feature PRs changing it fail with
an exact corrective instruction.

Protect this repository's actual runtime/build/CI paths, including root entry
scripts, `lib`, `web`, developer automation, tests, and workflows. Markdown/text
documentation-only changes do not raise a version. Stable promotions containing
protected changes raise it once; documentation-only promotions do not invent a
runtime release. Reject conflicting version labels rather than guessing.

The release pipeline is serialized without cancelling active runs. It checks out
the intended stable promotion, increments and pushes the version before
publishing, and fails explicitly if pushing fails or the expected branch head
has moved. Never overwrite an existing version tag or release.

Beta builds carry the current version and commit identity without editing
`VERSION`. Package metadata records version, channel, and source commit. The
dashboard and console report the same version/channel; beta is visible beside
the name and in the browser title. Stable has no beta badge. Provide a
read-only `/api/version` response. A development checkout defaults to the beta
channel unless explicitly packaged as stable.

## Continuous integration and local checks

Use Windows CI with PowerShell 7, a pinned Pester version, Git, and Node.js.
Run the existing Git/export/runtime Pester tests, dashboard Node tests,
PowerShell parsing, and package validation. No real Intune tenant credentials
are required for CI; keep the distinction between local integration coverage
and unverified live Azure DevOps/Intune authentication explicit.

Add checks for:

- PRs into `main` have head `beta` in the same repository.
- Feature PRs cannot change `VERSION` after bootstrap.
- Version and package metadata are valid and consistent.
- Required agent entry files point at the canonical instructions, without
  duplicated policy prose.
- Applicable baseline controls and their evidence are recorded honestly.
- Stable/beta identity and release preconditions cannot silently drift.

Keep local pre-commit validation fast and use the same lightweight guidance
checker in the hook and CI. Provide an explicit, opt-in hook setup command;
do not replace an existing user's hook silently. Full tests and ZIP building
belong in CI.

A failure message names the failing rule and the remediation. Tests exercise
behavior and failures, not just the presence of configuration strings.

## Channels and release publication

A successful push to `beta` produces a beta ZIP CI artifact named with its
version and commit identity. It creates no stable tag and no GitHub Release.
Packaging uses an explicit product payload so tests, hooks, workflows, agent
instructions, repository metadata, and developer scripts do not leak into
customer ZIPs.

Before a stable promotion, review notes in `docs/releases/vX.Y.Z.md` for the
version the pipeline will select. The notes describe all changes since the
previous stable release, user-visible effects, update instructions, dependency
or runtime changes, data implications, and unverified external integrations.
Validate the notes before changing the version or publishing.

After the owner-requested promotion merge, the serialized stable workflow:

1. Verifies the promotion and its checks, notes, version increment, and head.
2. Pushes the pipeline-generated version commit.
3. Runs checks and builds the stable ZIP from that exact version commit.
4. Creates the version tag and latest GitHub Release together using
   `gh release create --target <version-commit> --notes-file <reviewed-notes>`,
   attaching the built ZIP without rebuilding it.
5. Merges `main` back into `beta` so the branches share the raised version.

Use narrowly scoped automation permission for the version commit and back-merge
where GitHub can configure it safely. Do not weaken human PR requirements to
make automation pass. Report an unsupported protection/bypass capability as a
blocker rather than silently publishing under weaker rules.

A manually dispatched recovery run targets the same promotion/version commit,
does not increment twice, and never overwrites an existing release. If a
release is already present, report that state explicitly; partial failures
before publication retain enough commit/build evidence for a controlled retry.

Recovery may construct the **first** ZIP/manifest from the exact verified
existing version commit only after authenticated checks confirm the release,
tag, and persisted immutable artifact are absent. It never increments again.
Artifact inventory and prior upload history must be readable and complete;
expired artifacts, evidence of a prior successful upload whose bytes are now
missing, or unverifiable absence block construction. If an artifact exists,
reuse its exact bytes after identity/checksum verification; never rebuild or
replace recorded or published bytes. Recovery-created artifacts are persisted
before publication and remain reusable by subsequent recovery runs.

Versioned beta prereleases are deferred: this design provides continuous beta
ZIP artifacts, not tester releases. If deliberately introduced, use
`vX.Y.Z-beta.N`, reviewed notes, and GitHub prerelease status, never latest.

## GitHub setup and promotion runbook

Create `beta` from remote `main`, then make it the GitHub default. Configure
`main` to require PRs and the same-repository `only-from-beta` check, prohibit
force pushes/deletion and direct human pushes, and retain merge commits for
promotions. Repository-wide squash settings must not force promotion squashes.

Apply required-check settings only after the check names exist. Verify the
effective settings by reading them back. Keep the current worktree/feature
branch intact; changing GitHub's default does not change this session's base.
Verify that future app-created worktrees actually use `beta`, and report a
stale app-side default if it cannot be updated through supported tools.

The local runbook specifies exact test commands, note preparation, open-work
checks, conflict checks, owner approval, merge method, release verification,
back-merge verification, and operator update steps. The pipeline-bump model
overrides the supplied runbook's PR-bump examples: beta does not need to carry a
higher version before promotion.

## Operations, data, and applicability

Document local start/stop, PowerShell installation/update, the health endpoint,
version endpoint, ZIP update procedure, and backup/restore. Use a lightweight
unauthenticated localhost `/api/health` endpoint without account, token, or
tenant data.

Document the runtime components and data locations: selected documentation
output and manifest, optional Git checkout, in-memory authentication, and saved
browser profile. Distinguish recoverable generated output from a Git history
that must be preserved; do not recommend backing up credentials or active
browser sessions as app data.

State that supported deployments bind directly to localhost with no supported
CDN, ingress, or reverse proxy. Document actual request/body/time limits where
known, and identify unbounded or unmeasured behavior rather than fabricating
latency, throughput, availability, or recovery measurements.

Docker storage, container image channels, database schema migrations, native
Apple delivery, web push, crawler policy, sitemap, public-domain HSTS, and
multi-locale catalogues are not applicable to the current app. Do not add these
subsystems to satisfy a generic baseline.

Existing authentication implements protocol handling without a dedicated
OAuth module. Record that deviation and its rationale rather than claiming
the standards-module rule is satisfied. Replacing it is separate work unless
a defect in that implementation is touched.

## Known missing source material

The 111-topic engineering index, conformance template, validators, and linked
reference workflows were not supplied and the upstream private repository is
not accessible. This implementation cannot claim full section 18 conformance.
Record the missing-source gap and request those documents when that follow-up
is undertaken. Do not substitute an invented topic list or fabricated evidence.

## Acceptance

- Both beta and stable metadata/package paths are exercised without real
  customer data; beta labeling disappears for stable.
- Existing export, Git publishing, and PowerShell 7 startup behavior remain
  covered and unchanged except for explicit version/channel presentation.
- Negative tests catch wrong PR targets, unauthorized version edits, missing
  notes, invalid versions, and attempts to reuse a version release.
- ZIP contents are product-only and match the recorded version/commit/channel.
- `beta` and the GitHub default setting are verified remotely; branch protection
  and any automation bypass are verified or explicitly reported as blocked.
- No production promotion, existing-release mutation, automatic dependency
  installation on user machines, or migration of customer output occurs.
