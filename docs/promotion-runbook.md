# Owner-requested stable promotion

Stable publication is an explicit owner action. A promotion is a two-parent
merge of this repository's `beta` into `main`; feature changes and beta builds
never publish stable releases. Do not start a promotion unless the owner has
reviewed the proposed changes and requested that exact promotion.

This runbook applies App-Guidance's
[promotion runbook](https://github.com/Flux76HQ/App-Guidance/blob/main/shared/guidelines/promotion-runbook.md)
to this repository. Where the two differ, the stricter rule wins; the places
that are specific to this app are release notes in `docs/releases/`, a ZIP
package instead of container images, and a version number that the pipeline
(not the promotion) increments.

## Who does what

- **A promotion happens when the owner asks for it** — never on an agent's own
  initiative, and not because `beta` has been quiet for a while.
- The agent **prepares** it: checks, release notes and the pull request. The
  **owner merges** the promotion (and the release-notes pull request).
- Merging uses a **merge commit**, never a squash or rebase.

## Release notes come first

Every release has release notes in `docs/releases/vX.Y.Z.md`. The stable release
text is created once when the promotion merges and is not rewritten afterwards,
so the notes must be right **before** the merge.

- The agent writes **both English and Dutch** in that same file as part of
  release preparation. Both versions cover the same changes, update guidance,
  risks and limitations; neither is an abbreviated summary. Review both before
  merging. Keep the required English headings unchanged for pipeline validation,
  then add the equivalent Dutch sections so publication includes both languages.
- A promotion usually spans **several versions that only existed as a beta**. The
  notes describe everything since the previous stable version, grouped by what a
  user notices, not by commit or beta build.
- Besides the sections the pipeline requires (see below), add above them:
  - **Since the previous stable version (vA)** — what changes in total (omit
    for the very first stable release and say so);
  - **Good to know when updating** — behavior that changed on purpose, anything
    to re-check after replacing the application files.
- Make the notes a normal pull request **into `beta`** and merge it **before** the
  promotion, so the promotion carries it. No `VERSION` change: this is
  documentation.
- Write only what is true. Do not describe a release as shipped before the
  workflow has published it, and say plainly what was not verified.

Skeleton for `docs/releases/vX.Y.Z.md` (fill in both languages):

```markdown
# Intune Docs Studio X.Y.Z

[English](#english) | [Nederlands](#nederlands)

## English

## Since the previous stable version (vA)

## Good to know when updating

## Changes and user-visible effects

## Update instructions

## Dependencies and runtime

## Data implications

## Unverified integrations

## Nederlands

## Sinds de vorige stabiele versie (vA)

## Goed om te weten bij het bijwerken

## Wijzigingen en zichtbare gevolgen

## Update-instructies

## Afhankelijkheden en runtime

## Gevolgen voor gegevens

## Niet-geverifieerde integraties
```

## Before requesting the promotion

1. Confirm `beta` is current and its `quality` and `only-from-beta` checks
   succeeded on the exact beta head to be promoted. Resolve open work and
   conflicts before creating the pull request.
2. Prepare `docs/releases/vX.Y.Z.md` for the version selected by the pipeline:
   patch by default, or minor/major only when the promotion PR has exactly one
   of the `version:minor` / `version:major` labels. The notes must have
   nonempty sections for **Changes and user-visible effects**, **Update
   instructions**, **Dependencies and runtime**, **Data implications**, and
   **Unverified integrations**. Describe every user-facing change since the
   last stable version; explicitly say when a category has no change or was
   not verified. Do not write notes that imply a release has shipped.
   If the owner explicitly requests a stable release for a documentation-only
   delta, add `release:required` to that promotion PR before merging. Without
   this opt-in, documentation-only promotions still publish nothing. This label
   does not choose the increment: patch remains the default and the existing
   version labels choose minor/major. Do not use it to bypass a failed release
   or replace an existing tag, release or artifact.
3. Review the rendered English and Dutch notes for equivalent coverage and
   confirm that the selected version/tag is not
   already present. Do not edit `VERSION` in the promotion PR; the pipeline
   creates the only version bump.
4. Merge the same-repository `beta` → `main` pull request using a merge commit.
   Squash/rebase commits do not provide the required two-parent evidence.

## The promotion pull request

Base `main`, head `beta` of this same repository. Title:
`Release vX.Y.Z: promotion from beta to production`, with the version the
pipeline will select. There is no template; the body has these parts, in this
order, because it is what the owner reads before merging:

1. **What this is** — from which version to which, what the merge triggers
   (stable release marked *latest*, ZIP and manifest), and that `beta` merges
   cleanly.
2. **Order** — name the release-notes pull request if it is not merged yet.
3. **What changes for users of the previous stable version** — a short list; the
   full text is in the release notes.
4. **Risks and things to know** — runtime or dependency changes, data and
   output implications, changed limits stated as numbers, and what has **not**
   been verified (for example behavior that needs a real tenant).
5. **Checked** — the checklist below with the real results, including any
   failing test and whether it failed before this release. Do not write
   "green" when it is not.
6. **After merging** — the checks in the next section.

Check before opening it, against the real branches: `VERSION` on `main` and
`beta`; `git fetch origin main beta` then
`git merge-tree --write-tree origin/main origin/beta` shows no conflicts and
`git log origin/beta..origin/main` lists only earlier promotion merges; the
`quality` and `only-from-beta` checks on the **latest** `beta` merge commit are
green; no open pull request into `beta` still belongs in this release; and
`git diff --stat origin/main origin/beta` has been read for anything an
operator must act on.

## After the merge

Check, do not assume:

- release `vX.Y.Z` exists, is **not** a prerelease, is marked *latest*, has the
  ZIP and manifest attached, and its text is the reviewed notes (normalize
  CRLF/LF and surrounding whitespace when comparing the API response; content
  changes still fail verification);
- the version commit carries the `Release-Promotion` trailer and the final
  `main` → `beta` back-merge succeeded;
- if something is missing, use the recovery procedure below; never overwrite an
  existing tag or release.

Then tell the owner what is live and what operators must do (download the
verified ZIP and follow `QUICKSTART.md` / `docs/operations.md`).

### Mistakes this runbook exists to prevent

- **Pushing follow-up work to a branch whose pull request is already merged.**
  Look the pull request up first; if it is merged, restart the branch from the
  latest `beta` and open a new pull request.
- **Release notes that only describe the last change** of a multi-version
  promotion.
- **"Tests pass" with a failing test left out.**
- **Promoting from a `beta` whose last build is red or still running.**

## What the serialized workflow does

The `Stable release` workflow runs on a push to `main` or an explicit recovery
dispatch. A docs-only delta exits successfully with a no-release message unless
the merged promotion PR has the owner-requested `release:required` label.
Runtime, build, test, or workflow changes require a stable release.
The label is read from the validated same-repository promotion PR, not a feature
PR or a workflow input. Explicit releases still require successful beta checks,
complete reviewed release notes, unchanged source `VERSION`, the narrow
credential, current branch heads and an unused version tag. Recovery requires
the same promotion labels to remain in place; do not add or remove labels to
change the plan of a release already in progress.

The read-only promotion plan verifies `main` through the authenticated GitHub
ref API using the workflow's read-only token, not an unauthenticated Git fetch
or ref lookup, so a documentation-only promotion can exit without a write
credential (and fails closed if that read fails or the head moved). A required
stable release fails closed unless `IDS_STABLE_RELEASE_TOKEN` is configured as
a GitHub Actions secret. Configure it as a narrowly scoped GitHub App or
fine-grained automation credential with only the permissions needed to read
checks/PRs and Actions runs/jobs/recovery artifacts, create the pipeline version commit on
`main`, publish releases, and back-merge to `beta`. The job's
workflow-level `GITHUB_TOKEN` permission remains read-only. The credential must
be able to satisfy the repository's actual branch protection without disabling
human PR requirements. If the credential or a supported narrow bypass is not
available, the job fails closed; do not weaken `main` or replace the credential
with a broad token.

The job validates one merged same-repository beta-to-main promotion, a two-parent
merge commit, the successful `quality` and `only-from-beta` checks on its beta
parent, the expected `main` head, selected labels, and complete reviewed notes.
Pushing the child version commit with a separate automation token can trigger
another `push` run. Read-only planning recognizes that push only after validating
the original promotion/CI/notes, exact parent, `Release-Promotion` trailer,
VERSION-only delta, planned version and current local/remote main heads. It then
exits with no release: publication still belongs to the original promotion run.
This does not skip CI or allow an arbitrary single-parent commit onto main.
It creates one child version commit with a `Release-Promotion: <merge-sha>`
trailer, pushes without force, then tests and packages that exact commit in
stable mode. The ZIP and SHA-256 manifest are stored as an Actions artifact
before publication. `gh release create` targets that version commit, attaches
the already-built ZIP and manifest, uses the reviewed notes, and marks the
release latest. The workflow then merges `main` back into `beta` in a clean
temporary worktree, reruns the tests and beta package build, and pushes without
force. Conflicts or head movement stop the workflow; no automatic resolution
or force push is attempted.

The stable transaction uses the beta PR's labels, not labels from another open
PR. It queries both the tag ref and Release API. Only a confirmed GitHub 404 is
treated as absence; permission, API, or network errors stop the transaction.
Existing tags/releases and their assets are immutable.

## Recovery

If back-merge validation fails only because a synthetic Git fixture exceeds
Windows path limits in the nested release worktree, keep the published release
and main version commit intact. Put the test-only path repair through a normal
PR into `beta` and verify its hosted checks, then dispatch the existing
promotion's recovery with its recorded version commit/artifact run. The recovery
revalidates the immutable release and exact main commit, then merges into the
repaired beta tree and reruns the full checks before pushing. Do not copy beta
tests into the stable checkout, disable assertions, replace release assets or
increment the version to work around an environmental test-path failure.

Concurrency serializes an active run but GitHub may replace a pending run. Do
not assume a durable FIFO queue. The promotion SHA, version commit, workflow
run, and uploaded artifact are the recovery evidence.

If the version push failed, there is no release call. First resolve the
credential/protection blocker and confirm that `main` still equals the original
promotion SHA. Use **Actions → Stable release → Run workflow** with:

- `before`: the promotion's first parent SHA;
- `promotion_sha`: the original two-parent beta-to-main merge SHA;
- `recovery_version_commit`: empty;
- `artifact_run_id`: empty.

This retries validation and the one version push; it does not change `VERSION`
in the promotion or publish from a stale head.

If the version commit was pushed but the first ZIP build or artifact upload
failed before any immutable artifact was persisted, dispatch with that exact
`recovery_version_commit`, the original `before` and `promotion_sha`, and an
empty `artifact_run_id`. Recovery verifies the existing version commit and
local/remote heads; it does not increment again. It permits **first artifact
construction only** after authenticated tag/release checks confirm both absent,
the complete paginated artifact inventory confirms no artifact for that identity
(including expired records), and the promotion/version runs' upload history
confirms no prior successful immutable upload. The first ZIP/manifest is built
from the verified version commit and uploaded before publication. Permission,
network, malformed/incomplete listing, or missing history evidence fails closed.
Do not delete run history or artifacts to make recovery pass; if history was
removed or absence cannot be verified, stop and investigate.

If the version commit was pushed and the stable ZIP/manifest artifact uploaded,
dispatch recovery with the same `before` and `promotion_sha`, the exact
`recovery_version_commit` printed by the failed run, and optionally its
`artifact_run_id`. Recovery discovers the immutable artifact by version/commit
identity; a supplied run ID must match. Artifacts first persisted by a recovery
dispatch are eligible for later recovery too. Recovery verifies the source
workflow/run, direct-parent relationship, the
`Release-Promotion` trailer, that only `VERSION` changed, the planned version,
notes, current `main` head, and the original artifact checksum. It does not
increment, rebuild, or re-upload the recorded artifact. If the artifact has expired or cannot be
verified before publication, stop and investigate rather than generating a
replacement. If publication already succeeded, recovery verifies the release's
downloaded manifest against the GitHub asset digests and can omit
`artifact_run_id`; it never rebuilds or uploads assets.

If a release already exists, recovery verifies its tag target and both asset
digests; it does not create, replace, or upload assets again. It retries only
the missing main-to-beta back-merge. A tag without a release, a mismatched
target, or mismatched assets is a blocker requiring manual investigation.

Recovery dispatch is not approval for a different promotion. Never reuse these
inputs for another merge or bypass a failed verification.

### Failed validation after an immutable artifact upload

An uploaded Actions artifact is not a published GitHub Release. Release notes
can already exist in `docs/releases/` while there is no public Release page,
ZIP download or published release text. Always distinguish those states.

If tests fail after the version push, retain the exact version commit and
uploaded ZIP/manifest. A rerun cannot fix tests stored in that commit.
Do not edit the commit, replace the artifact, disable assertions or publish
manually to make the failed validation look successful. Diagnose whether the
failure is environmental or a defect in the versioned tests/application.
Source-based package tests must use an explicit synthetic fixture version;
runtime package metadata must agree with the fixture's VERSION, not assume the
bootstrap version forever.

For a versioned defect, submit the repair through `beta` and stop publication
until the owner approves a reconciliation/superseding-release path. A new
promotion may not silently discard the already-pushed pipeline version:
main/beta VERSION must agree before planning the next increment. The existing
recovery path still validates the original exact version commit and cannot
incorporate a later repair. Keep its artifacts and record the original promotion,
version commit and run IDs; do not manufacture a tag or rewrite history.

## Checks and operator update

Run the local checks before requesting a promotion:

```powershell
Invoke-Pester .\tests\*.Tests.ps1 -Output Detailed
node --test .\tests\publishing-ui.test.js .\tests\assessment-ui.test.js .\tests\app-shell-ui.test.js
pwsh -NoProfile -File .\scripts\Test-Repository.ps1
pwsh -NoProfile -File .\Build-Package.ps1
```

The release workflow repeats Pester, Node, repository-policy validation, and
the ZIP build from the exact version commit. After success, verify the run's
version, promotion SHA, version commit, checksum, release/tag target, latest
status, attached ZIP and manifest, and final beta back-merge check. Report the
actual Action check results; do not infer green status from the workflow
definition or from an untriggered bot push.

For an operator update, download the verified stable ZIP from the GitHub
Release, extract it, and replace the prior application files as described in
`QUICKSTART.md`. Keep the prior ZIP until the new package starts and its
`/api/health` and `/api/version` responses are verified. Preserve generated
customer output and its Git history separately; do not back up tokens or active
browser-session files.

## Adoption and verification status

This runbook documents the intended transaction, not evidence that stable
automation has been enabled. No stable promotion or release was run as part of
this implementation. The narrow Actions credential and the required branch
protection/bypass settings must be configured and read back separately; do not
claim their availability from local tests. The release transaction is covered
with temporary local Git remotes and a fake GitHub CLI boundary only.
