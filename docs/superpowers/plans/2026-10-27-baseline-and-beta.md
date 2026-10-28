# Baseline and beta release implementation plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking. Keep execution inline unless the owner explicitly chooses subagents.

**Goal:** Adopt the supplied app baseline with beta integration, reproducible ZIP builds, enforced repository controls, and owner-requested stable promotions.

**Architecture:** Keep the existing PowerShell localhost application and introduce small, shared PowerShell helpers for build identity and repository/release policy. Windows GitHub Actions invokes the same tested helpers as local development. GitHub settings establish `beta` as the default and protect `main`; no stable release is created during adoption.

**Tech stack:** PowerShell 7+, Pester 5.7.1, Node.js 24 LTS built-in test runner, Git, GitHub Actions, GitHub CLI.

**Spec:** `docs\superpowers\specs\2026-10-27-baseline-and-beta-design.md`

## Global constraints

- `beta` becomes the integration and GitHub default branch.
- Promotions happen only when the owner requests them.
- `VERSION` starts at `0.1.0`. Feature pull requests do not change it.
- The pipeline raises the version on stable promotion, patch by default, with `version:minor` and `version:major` labels selecting larger increments.
- Distribute beta and stable ZIPs, not container images.
- Never overwrite an existing version tag or release.
- Preserve the uncommitted Azure DevOps and PowerShell 7 work in this worktree.
- Do not claim full 111-topic conformance without the missing authoritative index.
- Do not introduce customer credentials into CI, release notes, or test fixtures.
- Installation on user machines remains opt-in; no automatic PowerShell installation.
- Stage exact files per commit, never `git add -A`; include the configured Copilot coauthor trailer.

## File responsibilities and interfaces

| File | Responsibility |
|---|---|
| `AGENTS.md` | Canonical contributor and agent policy, exact commands, branch/release model |
| `CLAUDE.md`, `.github\copilot-instructions.md` | Thin client pointers |
| `docs\baseline-adoption.md` | Applicable requirement/control matrix and honest deferred gaps |
| `docs\operations.md`, `docs\promotion-runbook.md` | Local operations and owner-requested stable release procedure |
| `VERSION` | Strict initial `0.1.0`, subsequently changed by pipeline only |
| `lib\Version.ps1` | Read and validate one version/build identity |
| `scripts\RepositoryPolicy.ps1` | Pure/testable guidance, version-change, and PR-target rules |
| `scripts\Test-Repository.ps1` | Executable repository checker with actionable errors |
| `scripts\Setup-Hooks.ps1` | Opt-in lightweight pre-commit setup |
| `scripts\ReleasePolicy.ps1` | Pure next-version, delta, notes, retry, and publication decisions |
| `scripts\Invoke-StableRelease.ps1` | Stable transaction; explicit Git/GitHub failure handling |
| `.github\workflows\ci.yml` | PR/push checks and `only-from-beta` status |
| `.github\workflows\beta.yml` | Product-only beta ZIP artifacts, never releases |
| `.github\workflows\release.yml` | Serialized stable transaction and explicit recovery dispatch |
| `.github\PULL_REQUEST_TEMPLATE.md` | Standards module/exception, operational impact, limits, and evidence |

Keep new runtime identity logic outside the already large `lib\Export.ps1`.
Use no new Python dependency. Use the existing packaging command and update
its interface rather than introducing a second ZIP builder.

## Task 1: Canonical guidance and enforceable local policy

**Files:** Create `AGENTS.md`, `CLAUDE.md`, `.github\copilot-instructions.md`,
`docs\baseline-adoption.md`, `scripts\RepositoryPolicy.ps1`,
`scripts\Test-Repository.ps1`, `scripts\Setup-Hooks.ps1`,
`.github\PULL_REQUEST_TEMPLATE.md`, `tests\RepositoryPolicy.Tests.ps1`.
Modify `.gitignore`.

**Interfaces:**
- `Test-IdsAgentInstructions -Root <string>` returns violations as `string[]`.
- `Test-IdsVersionChange -Root <string> -Before <sha> -After <sha>` returns violations.
- `Test-IdsPullRequestTarget -Base <string> -Head <string> -SameRepository <bool>` returns violations.
- `Test-Repository.ps1 [-Before <sha> -After <sha>]` writes every violation and exits 1 on failure.
- `Setup-Hooks.ps1` installs a hook invoking only lightweight agent/policy validation.

- [ ] **1. Write failing behavior tests with temporary repository fixtures.**

```powershell
It 'refuses a feature PR into main' {
    @(Test-IdsPullRequestTarget -Base main -Head feature -SameRepository $true).Count |
        Should -Be 1
}
It 'rejects a fork branch named beta as a stable promotion' {
    @(Test-IdsPullRequestTarget -Base main -Head beta -SameRepository $false).Count |
        Should -Be 1
}
It 'accepts this repository beta as the promotion head' {
    @(Test-IdsPullRequestTarget -Base main -Head beta -SameRepository $true).Count |
        Should -Be 0
}
```

Add temporary-file cases for missing pointers, duplicated canonical prose,
missing adoption-control rows, and version edits. Bootstrap allows adding
`VERSION` only when the base has no version and the value is exactly `0.1.0`;
after bootstrap any PR edit fails, including a numerically increasing one.

- [ ] **2. Run the new tests and observe the missing policy functions fail.**

```powershell
$r = Invoke-Pester .\tests\RepositoryPolicy.Tests.ps1 -Output Detailed -PassThru
if ($r.FailedCount -or $r.NotRunCount) { exit 1 }
```

- [ ] **3. Implement policy, documentation, hooks, and exact remediation.**

```powershell
function Test-IdsPullRequestTarget {
    param([string]$Base, [string]$Head, [bool]$SameRepository)
    if ($Base -eq 'main' -and ($Head -ne 'beta' -or -not $SameRepository)) {
        'main accepts only a promotion from beta in this repository. Retarget feature PRs to beta.'
    } elseif ($Base -notin @('beta', 'main')) {
        'Target beta for feature work; main is reserved for owner-requested promotions.'
    }
}
```

The canonical policy names current test commands, PowerShell floor, untouched
customer data, secrets, feature isolation, pipeline version model, and release
authorization. Client pointers contain no copied rules. The adoption matrix
answers all supplied sections, names actual controls for applicable MUSTs, and
explicitly defers unavailable section 18 material. Existing hand-written OAuth
handling is recorded as a standards-module deviation, not silently rewritten.

Ignore `.env*` except `.env.example`. Hook setup inspects an existing
`core.hooksPath` and existing hook: refuse and explain manual integration if
installing would overwrite custom hooks. Store managed hooks under a tracked
development path, never inside product packaging.

- [ ] **4. Run policy tests and the checker; verify a deliberately broken pointer fails.**
- [ ] **5. Commit only Task 1 files with `chore: adopt canonical app guidance`.**

## Task 2: Shared runtime version, channel, and health identity

**Files:** Create `VERSION`, `lib\Version.ps1`, `tests\Version.Tests.ps1`.
Modify `IntuneDocsStudio.ps1`, `web\index.html`, `web\app.js`,
`tests\publishing-ui.test.js`, `tests\Runtime.Tests.ps1`.

**Interfaces:**
- `Get-IdsBuildInfo -Root <string>` returns
  `@{ version=<semver>; channel='beta'|'stable'; commit=<sha or 'development'> }`.
- A packaged `build-info.json` is authoritative when present; invalid or
  inconsistent metadata throws. A source checkout without metadata is beta.
- `/api/version` returns the shared build information.
- `/api/health` returns only `@{ status='ok' }` with HTTP 200.
- `/api/state` includes `build` with the same shared object.

- [ ] **1. Write tests for source beta, stable package, malformed metadata, and UI labels.**

```powershell
It 'defaults a source checkout to beta without a Git dependency' {
    Set-Content (Join-Path $TestDrive VERSION) '0.1.0'
    $build = Get-IdsBuildInfo -Root $TestDrive
    $build.version | Should -Be '0.1.0'
    $build.channel | Should -Be 'beta'
    $build.commit | Should -Be 'development'
}
```

Extend the Node DOM fixture with `document.title`; render a beta state then a
stable state and assert the name/title lose the beta marker. Assert build
rendering does not duplicate or remove the app name.

- [ ] **2. Run `Invoke-Pester .\tests\Version.Tests.ps1` and Node tests; observe failures.**
- [ ] **3. Implement strict shared identity and route/UI/console consumers.**

```powershell
$version = [IO.File]::ReadAllText((Join-Path $Root 'VERSION')).Trim()
if ($version -notmatch '^(0|[1-9]\d*)\.(0|[1-9]\d*)\.(0|[1-9]\d*)$') {
    throw 'VERSION must contain MAJOR.MINOR.PATCH, for example 0.1.0.'
}
```

Load identity once before accepting requests; include no authentication or
tenant state in health/version. Do not let a malformed metadata file quietly
fall back to development. Bind the existing listener to localhost only.

- [ ] **4. Run targeted tests and an actual temporary-port server smoke test.**

Request health/version without signing in; assert safe output and stop the
specific server through `/api/quit` in `finally`. Verify a stable fixture gives
stable identity and a development fixture gives beta. Preserve the existing
PowerShell 5.1 rejection test.

- [ ] **5. Commit exact Task 2 files with `feat: expose consistent build identity`.**

## Task 3: Product-only reproducible package contract

**Files:** Modify `Build-Package.ps1`, `README.md`, `QUICKSTART.md`.
Create `tests\Package.Tests.ps1`.

**Interfaces:**
- `Build-Package.ps1 -OutputPath <absolute-folder> -Channel beta|stable
  -SourceCommit <40-hex-sha>`; local defaults are beta/development.
- ZIP stays `IntuneDocsStudio.zip` inside the supplied output directory.
- Embedded `build-info.json` has precisely `version`, `channel`, and `commit`.

- [ ] **1. Write package-content and invalid-input tests.**

```powershell
It 'includes build identity without developer or local-state files' {
    $output = Join-Path $TestDrive 'package'
    & (Join-Path $repo 'Build-Package.ps1') -OutputPath $output -Channel beta `
        -SourceCommit ('a' * 40)
    Expand-Archive (Join-Path $output 'IntuneDocsStudio.zip') (Join-Path $TestDrive 'unpacked')
    $root = Join-Path $TestDrive 'unpacked\IntuneDocsStudio'
    $info = Get-Content (Join-Path $root 'build-info.json') -Raw | ConvertFrom-Json
    $info.channel | Should -Be 'beta'
    Test-Path (Join-Path $root '.github') | Should -BeFalse
    Test-Path (Join-Path $root 'tests') | Should -BeFalse
}
```

Test stable metadata, wrong commit format, and a source tree containing
`.env`, `.git`, browser state, developer docs and scripts. Assert the complete
permitted relative file set rather than a short denylist.

- [ ] **2. Run package tests and observe missing metadata/incorrect payload failures.**
- [ ] **3. Replace discovery-based shipping with a deliberate product allowlist.**

Include only `Start-IntuneDocs.cmd`, `IntuneDocsStudio.ps1`, `VERSION`,
`README.md`, `QUICKSTART.md`, `SECURITY.md`, needed publishing/operations docs,
runtime `lib\*.ps1`, `web\index.html`, `web\app.js`, and `web\style.css`.
Generate metadata only in the stage, never overwrite source metadata.
Preserve leak scanning over the product payload and parser validation.
Use a unique stage and remove that exact stage in `finally`, including failures.
Stable requires an explicit full source commit; do not ship a stable development build.

- [ ] **4. Run package/version tests and unpacked server smoke checks.**
- [ ] **5. Commit exact Task 3 files with `build: package channel-aware product payloads`.**

## Task 4: CI checks and continuous beta artifacts

**Files:** Create `.github\workflows\ci.yml`, `.github\workflows\beta.yml`.
Modify `scripts\Test-Repository.ps1`, `tests\RepositoryPolicy.Tests.ps1`.

**Interfaces:**
- Required status name: `only-from-beta`.
- Full check name: `quality`.
- Beta artifact name: `IntuneDocsStudio-beta-<version>-<full-sha>`.
- Jobs call the previously defined scripts and test commands, not duplicate policy.

- [ ] **1. Add negative policy cases for invalid semver and bootstrap/version edits.**
- [ ] **2. Observe failing cases before completing policy behavior.**
- [ ] **3. Implement workflows with read-only permissions by default.**

```yaml
name: CI
on:
  pull_request:
    branches: [beta, main]
  push:
    branches: [beta, main]
permissions:
  contents: read
```

Pass PR head/base/repository values through environment variables, not inline
shell interpolation. Run the target policy on PRs; on pushes it reports the
target rule as not applicable. Set up Node 24, pinned Pester 5.7.1, and
PowerShell 7 on Windows. Use full history where policy compares Git SHAs.

```powershell
Install-Module Pester -RequiredVersion 5.7.1 -Scope CurrentUser -Force
$r = Invoke-Pester -Path .\tests -Output Detailed -PassThru
if ($r.FailedCount -or $r.NotRunCount -or $r.PassedCount -eq 0) { exit 1 }
node --test .\tests\publishing-ui.test.js
if ($LASTEXITCODE) { exit $LASTEXITCODE }
.\scripts\Test-Repository.ps1
.\Build-Package.ps1 -OutputPath (Join-Path $env:RUNNER_TEMP 'beta-package') `
    -Channel beta -SourceCommit $env:GITHUB_SHA
```

Use maintained checkout/setup-node/upload-artifact actions pinned to verified
commit SHAs at implementation time. The beta workflow runs full validation
before upload, uses explicit beta identity, never requests release write
permission, and offers `workflow_dispatch` for an exact beta-head recovery.
Do not install packages on user machines; dependency setup here is CI-only.

- [ ] **4. Run identical commands locally; inspect workflow event/job behavior with fixture inputs.**
- [ ] **5. Commit exact Task 4 files with `ci: validate changes and publish beta artifacts`.**

## Task 5: Stable release policy and recoverable transaction

**Files:** Create `scripts\ReleasePolicy.ps1`,
`scripts\Invoke-StableRelease.ps1`, `.github\workflows\release.yml`,
`tests\ReleasePolicy.Tests.ps1`, `tests\ReleaseTransaction.Tests.ps1`,
`docs\promotion-runbook.md`.

**Interfaces:**
- `Get-IdsNextVersion -Version <string> -Labels <string[]>` returns strict semver.
- `Test-IdsReleaseDelta -Paths <string[]>` returns whether a protected non-doc changed.
- `Get-IdsReleasePlan -Root <string> -Before <sha> -After <sha>
  -Labels <string[]>` returns
  `@{ required=<bool>; previousVersion; version; tag; notesPath; promotionSha }`.
- `Invoke-StableRelease.ps1 -Before <sha> -PromotionSha <sha>
  [-RecoveryVersionCommit <sha>]` implements the transaction, rejects non-main,
  and emits the final version/tag/commit for workflow evidence.

- [ ] **1. Write version/notes/recovery tests before implementation.**

```powershell
It 'increments minor and resets patch' {
    Get-IdsNextVersion -Version '0.1.7' -Labels @('version:minor') |
        Should -Be '0.2.0'
}
It 'rejects conflicting version labels rather than choosing one' {
    { Get-IdsNextVersion -Version '0.1.0' -Labels @('version:major','version:minor') } |
        Should -Throw '*one version label*'
}
It 'does not release documentation-only changes' {
    Test-IdsReleaseDelta -Paths @('README.md', 'docs\operations.md') |
        Should -BeFalse
}
```

Use temporary Git remotes for bump push, expected-head mismatch, and back-merge
conflict behavior. Fake only external GitHub publication at a command boundary
that records all arguments and returns precise fixture responses. Verify
observables: notes absent means no version commit; push rejected means no
release call; existing tag/release means no overwrite; recovery uses the same
version commit without another increment.

- [ ] **2. Run release tests and observe failures for each missing rule.**
- [ ] **3. Implement release ordering and explicit failure reporting.**

For push-to-main, require exactly one associated merged same-repository
beta-to-main promotion and a two-parent merge, and confirm the required beta
checks on the promotion head succeeded. Labels come from that promotion,
never from a currently open unrelated PR. A docs-only delta exits successfully
with an explicit no-release message.

Validate notes exist, are nonempty, and contain user-facing changes and
updating guidance before changing `VERSION`. Validate the remote main head
equals the expected promotion. Increment once, add a machine-readable
`Release-Promotion: <sha>` commit trailer, push without force, then test/build
the exact version commit in stable mode. Store an artifact with a checksum
and manifest before publication. Query both the Git tag and Release API;
errors other than a confirmed 404 fail, rather than masquerading as absence.

```powershell
gh release create $plan.tag $zip --repo $repository `
    --target $versionCommit --notes-file $plan.notesPath --latest
if ($LASTEXITCODE) { throw 'Release creation failed. Recover using the recorded version commit; do not increment or overwrite the tag.' }
```

Keep write credentials restricted to the stable job. Use a single stable
concurrency group with `cancel-in-progress: false`; detect stale promotions
and head movement explicitly instead of force-pushing. Remember Actions may
replace a pending concurrency run: a manual recovery dispatch and persisted
promotion evidence are required, not an assumption of a durable FIFO queue.

After publication, fetch and merge main into beta in a temporary clean
checkout, without force or auto-conflict resolution. Fail explicitly on
conflicts. Since a `GITHUB_TOKEN` push does not trigger workflows, perform
beta validation/build for the resulting head within this workflow or invoke
the beta recovery dispatch explicitly. Do not claim an unbuilt beta is green.

Recovery verifies the supplied commit is a version commit with the expected
promotion trailer, only the expected version change, correct notes, main
ancestry, and the same recorded artifact identity. Do not accept arbitrary
refs, recreate tags, or increment twice. If a release exists, report it and
verify/retry only missing back-sync; do not replace its assets.

The local runbook records the pipeline-bump difference from upstream, exact
tests, notes path, real check results, merge-commit requirement, operator ZIP
update steps, and recovery commands. Do not add a stable notes file claiming
the current changes have shipped.

- [ ] **4. Run release tests plus the full existing test set; no live stable publication.**
- [ ] **5. Commit exact Task 5 files with `ci: add guarded stable release transaction`.**

## Task 6: Operator documentation and measured-scope adoption evidence

**Files:** Create `docs\operations.md`.
Modify `docs\baseline-adoption.md`, `AGENTS.md`, `README.md`,
`QUICKSTART.md`, `SECURITY.md`, `tests\RepositoryPolicy.Tests.ps1`.

**Interfaces:** Required matrix rows map each applicable rule to an actual
script/test/workflow or named review requirement. The checker rejects missing
control names and missing reasons; it does not assert evidence is true.

- [ ] **1. Add a fixture missing an operations/control row and observe checker failure.**
- [ ] **2. Document actual runtime/data/limit behavior from code, not guesses.**

```text
Runtime: browser -> localhost HttpListener -> PowerShell -> delegated Microsoft Graph.
Persistent output: selected absolute output directory, manifest, optional Git checkout.
Sign-in: in-memory tokens; separate saved browser profile may persist sign-in.
Edge topology: direct localhost only; no supported CDN, proxy, ingress, or public TLS host.
Health: GET /api/health; identity: GET /api/version.
```

Explain stop-before-update, keep output/history separate from the tool folder,
copy the verified replacement ZIP payload, restart through the PowerShell 7
launcher, and confirm version/channel. Back up the output including its
manifest and Git history to an access-controlled location, restore to a new
folder, verify tenant identity/remote before export, and sign in again rather
than restoring tokens/browser credentials.

Record measured limits only after measuring. For absent SLO/performance/RPO/RTO
commitments say unmeasured/not-now and give a reason; section 18 remains
incomplete pending its missing documents.

- [ ] **3. Run policy checker and all relevant tests; verify docs links resolve locally.**
- [ ] **4. Review every baseline section against the matrix without adding unrelated subsystems.**
- [ ] **5. Commit exact Task 6 files with `docs: document operations and baseline controls`.**

## Task 7: Authorized beta bootstrap and remote protection verification

**Resources:** GitHub repository `helmerz_microsoft/intune-docs-studio`;
GitHub default, branch refs, rulesets, Actions permission; current local branch.

**Prerequisite:** Task 4 provides the exact required status names. Do not
silently assume a private repository's plan permits rulesets or bypasses.

- [ ] **1. Inspect remote main/beta refs and current protections.**

```powershell
gh api repos/helmerz_microsoft/intune-docs-studio/git/ref/heads/main
gh api repos/helmerz_microsoft/intune-docs-studio/rulesets
```

If beta already exists, preserve it and check ancestry; do not replace it.
Only a confirmed missing-beta response permits creation.

- [ ] **2. Create beta from the live remote main SHA and set it as default.**

```powershell
$sha = gh api repos/helmerz_microsoft/intune-docs-studio/git/ref/heads/main --jq .object.sha
if ($LASTEXITCODE) { throw 'Cannot read remote main; no settings changed.' }
gh api repos/helmerz_microsoft/intune-docs-studio/git/refs -f ref=refs/heads/beta -f "sha=$sha"
if ($LASTEXITCODE) { throw 'Beta creation failed; inspect the live ref before retrying.' }
gh repo edit helmerz_microsoft/intune-docs-studio --default-branch beta
if ($LASTEXITCODE) { throw 'Beta exists, but setting the default branch failed.' }
```

Read both settings back. The current feature branch already descends from the
same original main; preserve its work and do not switch a shared checkout.
Verify the app's repository discovery returns beta. If the desktop cache
still says main, report that specific limitation; do not hand-edit app state.

- [ ] **3. Configure main protection only after required checks can run.**

Use a ruleset or equivalent supported protection requiring PRs and
`only-from-beta` plus `quality`, blocking deletion/force-push, and requiring
merge commits for promotions. Do not prohibit squash globally for unrelated
feature PRs. Verify the actual rule representation and read it back.

The version commit/back-sync requires a narrowly scoped automation bypass.
Discover the actual GitHub App identity and ruleset capability, rather than
hard-coding an assumed app ID or creating a personal token. If `GITHUB_TOKEN`
cannot use a supported narrowly scoped bypass, stop stable automation and
report that an owner-configured GitHub App credential is needed. Leave beta
builds working; do not remove protection or publish with weaker rules.

Do not activate a required check absent from beta: arrange adoption via a
normal feature PR into beta only if the owner requests that PR. No new PR or
merge is authorized merely by this implementation plan. Until adoption
lands, report protection activation as pending instead of making every
promotion unmergeable.

- [ ] **4. Verify read-back, run full local validation, and report unverified external paths.**

```powershell
$r = Invoke-Pester -Path .\tests -Output Detailed -PassThru
if ($r.FailedCount -or $r.NotRunCount -or $r.PassedCount -eq 0) { exit 1 }
node --test .\tests\publishing-ui.test.js
if ($LASTEXITCODE) { exit $LASTEXITCODE }
.\scripts\Test-Repository.ps1
git --no-pager diff --check
```

Remove only task-owned scratch packages and stop temporary servers. Keep
actual installed-user data untouched. Report which settings were applied,
which depend on landing the workflows, missing private-source material,
automation-credential blockers, and that no stable promotion occurred.

- [ ] **5. Record verified setup evidence in the operations documentation if needed.**

## Self-review mapping

| Spec section | Tasks |
|---|---|
| Canonical guidance, policy exceptions, secrets | 1, 6 |
| Version and runtime/channel identity | 1, 2, 5 |
| CI and fast opt-in hooks | 1, 4 |
| Beta artifacts and product ZIP payload | 3, 4 |
| Stable notes, serialization, immutable releases, recovery | 5 |
| Remote defaults, protections, supported automation | 7 |
| Operations, health, data ownership, limits | 2, 6 |
| Missing 111-topic material and standards deviation | 1, 6 |
| No promotion or alteration of existing local changes | Global constraints, 7 |

The first successful CI run and protection activation require the adoption
commit to reach beta. The plan does not misrepresent local validation as a
remote required check, and does not infer a request to open or merge a PR.
