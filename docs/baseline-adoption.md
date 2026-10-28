# Intune Docs Studio baseline adoption matrix

This matrix is measured adoption evidence for the supplied baseline materials,
not a blanket compliance declaration. Each applicable row names a local script,
test, workflow, runtime interface, or review requirement. The repository
checker requires the listed control rows and non-empty named evidence/status
fields; it checks documentation structure only and does **not** prove that the
named control ran, passed, or is active on GitHub.

| ID | Requirement | Applicability | Control type | Evidence/control | Status and limits |
|---|---|---|---|---|---|
| B-01 | Canonical guidance and client pointers | Applicable | Automated local policy | `scripts/RepositoryPolicy.ps1` validates guidance pointers; `scripts/Test-Repository.ps1` runs the checker; `tests/RepositoryPolicy.Tests.ps1` exercises the policy. | Implemented and locally tested. Hosted enforcement depends on the CI check and repository settings being active. |
| B-02 | Supported PowerShell runtime and contributor verification | Applicable | Runtime guard and review requirement | `IntuneDocsStudio.ps1` requires PowerShell 7; `Start-IntuneDocs.cmd` rejects missing/unsupported `pwsh`; `AGENTS.md` documents test and package commands. | Runtime floor is implemented. No automatic installation/update is performed. |
| B-03 | Customer data and credentials | Applicable | Review requirement | `AGENTS.md` prohibits customer data/credentials in source, CI, issues, release notes, and fixtures; `SECURITY.md` documents the local security boundary; `tests/` uses synthetic fixtures. | Contributor/reviewer control. No credential scanner or tenant-backed CI is claimed. |
| B-04 | Feature isolation, promotion source, and PR target | Applicable | Automated policy / pending remote enforcement | `Test-IdsPullRequestTarget` in `scripts/RepositoryPolicy.ps1`; `only-from-beta` in `.github/workflows/ci.yml`; `tests/RepositoryPolicy.Tests.ps1`. | The local rule and workflow definition exist. Remote `beta` is the default branch (read back 2026-10-28), but `main` has no branch protection or ruleset; live enforcement is not active. |
| B-05 | Version change authorization | Applicable | Automated policy / release workflow | `Test-IdsVersionChange` in `scripts/RepositoryPolicy.ps1`; `.github/workflows/ci.yml`; `.github/workflows/release.yml`; `scripts/ReleasePolicy.ps1`. | Feature PR edits are locally rejected and the stable workflow owns increments. Main protection is absent, and the required `IDS_STABLE_RELEASE_TOKEN` Actions secret is not configured (read back 2026-10-28); the stable transaction is not operable end-to-end remotely. |
| B-06 | Lightweight local validation hook | Applicable | Opt-in automation | `scripts/Setup-Hooks.ps1`; `tests/hooks/pre-commit`; `tests/RepositoryPolicy.Tests.ps1`. | Available but inactive until an individual contributor opts in. Existing configured hooks and custom hooks paths are preserved. |
| B-07 | Test, package, and channel validation | Applicable | Automated local tests and workflow definitions | `.github/workflows/ci.yml`; `.github/workflows/beta.yml`; `Build-Package.ps1`; `tests/Package.Tests.ps1`; `tests/Version.Tests.ps1`. | Local implementation and tests are present. No hosted Actions run/adoption build is recorded here; workflow definitions alone do not prove a live green check or artifact. Beta workflow publishes ZIP artifacts, not releases or container images. |
| B-08 | Owner-requested stable release, immutable version/tag, and recovery | Applicable | Review requirement and guarded workflow | `AGENTS.md`; `docs/promotion-runbook.md`; `.github/workflows/release.yml`; `scripts/Invoke-StableRelease.ps1`; `tests/ReleaseTransaction.Tests.ps1`. | Stable release remains owner-requested and none was created for this adoption. Remote protection is absent and no narrow release credential is configured; do not claim remote stable automation is active. |
| B-09 | Applicable baseline completeness and missing authoritative source | Applicable, incomplete | Deferred source requirement | `111-topic engineering index`; `conformance template`; `validators`; `linked reference workflows`. | Those authoritative materials were not supplied and the upstream repository was unavailable. Section 18 and 111-topic conformance remain incomplete; do not invent a substitute index or claim compliance. |
| B-10 | OAuth standards-module deviation | Applicable deviation | Review requirement | `AGENTS.md`; `lib/Auth.ps1`; `lib/Graph.ps1`. | Authentication implements protocol handling without a dedicated standards-module dependency. This deviation is disclosed, not claimed conformant; replacement is separate work. |
| B-11 | Runtime data ownership and deployment boundary | Applicable | Runtime behavior and review requirement | `README.md`; `SECURITY.md`; `lib/Http.ps1`; `lib/Export.ps1`; `docs/operations.md`. | The app binds to localhost and writes customer-owned output. No supported CDN, proxy, ingress, or public TLS host is provided. |
| B-12 | Container storage/images, database migrations, Apple delivery, web push, crawler/sitemap, public-domain HSTS, and multi-locale catalogues | Not applicable | Product scope | `AGENTS.md`; `docs/operations.md`; `README.md`. | This is a local Windows PowerShell documentation exporter, not those services or delivery surfaces. Reassess applicability only if the product architecture changes; do not add unrelated subsystems for this adoption. |
| B-13 | Operator lifecycle, update, backup/restore, health, identity, and measured limits | Applicable | Operator procedures and runtime interfaces | `docs/operations.md`; `Start-IntuneDocs.cmd`; `GET /api/health`; `GET /api/version`; `.intune-docs-manifest.json`; `tests/Runtime.Tests.ps1`. | Procedures document actual local behavior. Capacity, performance, availability, SLO, RPO, and RTO are unmeasured/not-now because this is an operator-run local tool with no measured service history or agreed service commitment. |

## Remote adoption read-back

The read-only GitHub verification on 2026-10-28 confirmed:

- `beta` is the default branch. Both `main` and `beta` point to
  `9b8208fc1a361bed4530ffeb09589f3157c7876c`; the comparison is identical
  (zero commits ahead or behind). The existing bootstrap was preserved.
- `main` is unprotected (branch-protection API: 404, "Branch not protected").
  Repository rulesets, including inherited rulesets, and effective branch rules
  are empty. Successful ruleset reads do not prove that the private repository's
  subscription permits the intended enforcement or automation bypass.
- Actions is enabled with all actions allowed. Default workflow permissions are
  read-only, and workflow PR approval is disabled. There are zero registered
  workflows; `.github/workflows` on `beta` returns 404. The beta commit has zero
  check runs and zero commit statuses; its aggregate `pending` state is not a
  running or passing check. `quality` and `only-from-beta` exist only in the
  local workflow definitions. Do not require them before authorized adoption
  lands on beta and hosted checks are verified.
- The repository has zero Actions secrets, tags, and releases. No stable
  promotion or release was performed during this verification.
- Repository App-installation discovery returned 401 (App JWT required), and
  user-installation discovery returned 403 (App-authorized access required).
  These responses do not prove that no App is installed. No actual App identity
  or supported narrow bypass for `GITHUB_TOKEN` could be verified. Stable
  automation remains blocked pending an owner-configured, repository-scoped
  GitHub App credential and verified protection/bypass capability. Do not create
  a personal token, substitute a broad bypass, or weaken main protection.

The desktop repository-discovery cache was previously observed to still report
`main`, despite GitHub returning `beta`; that cache discrepancy is reported,
not repaired by hand-editing app state. This verification made no remote
settings changes, push, PR, merge, or release. Workflow adoption requires a
separately authorized feature PR into beta; local definitions and tests are not
evidence of active hosted enforcement or a usable stable-release pipeline.

## Source and scope

The adopted source is the supplied
[App-Guidance project baseline and promotion runbook](https://github.com/Flux76/App-Guidance).
The upstream repository was private or unavailable. The authoritative
111-topic source package is missing; this matrix records known requirements
and explicit gaps without claiming complete conformance or substituting an
invented index.
