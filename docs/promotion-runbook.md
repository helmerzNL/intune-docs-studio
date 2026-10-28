# Owner-requested stable promotion

Stable publication is an explicit owner action. A promotion is a two-parent
merge of this repository's `beta` into `main`; feature changes and beta builds
never publish stable releases. Do not start a promotion unless the owner has
reviewed the proposed changes and requested that exact promotion.

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
3. Review the rendered notes and confirm that the selected version/tag is not
   already present. Do not edit `VERSION` in the promotion PR; the pipeline
   creates the only version bump.
4. Merge the same-repository `beta` → `main` pull request using a merge commit.
   Squash/rebase commits do not provide the required two-parent evidence.

## What the serialized workflow does

The `Stable release` workflow runs on a push to `main` or an explicit recovery
dispatch. A docs-only delta exits successfully with a no-release message.
Runtime, build, test, or workflow changes require a stable release.

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
