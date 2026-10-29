# Operator procedures

This guide covers a local Intune Docs Studio installation. The app is a Windows
PowerShell 7+ process that serves a dashboard on a loopback `HttpListener`,
collects read-only delegated Microsoft Graph data, and writes Markdown to a
chosen output folder. It is not a hosted service.

## Runtime and data boundaries

- The listener binds to `http://localhost:<port>/` (default port `7654`). No
  supported CDN, reverse proxy, ingress, or public TLS deployment exists.
- `GET /api/health` returns `{"status":"ok"}` while the dashboard process is
  serving requests. This is a process/readiness check only; it does not verify
  sign-in, Microsoft Graph access, export completion, or output-folder health.
- `GET /api/version` returns the running build's `version`, `channel`, and
  `commit`. A source checkout without packaged build metadata identifies as
  `beta` / `development`; packaged builds carry their identity in
  `build-info.json`.
- App-managed tokens and normal dashboard state live in process memory; the
  app does not write its token state to disk. Portal-session sign-in reads a
  token from the browser's MSAL cache. Its separate browser profile under
  `%LOCALAPPDATA%\IntuneDocsStudio\browser-profile` may persist cookies and
  other cached authentication material. Do not back up, copy, or restore that
  profile as application data. Sign in again after restoring or moving an
  installation.
- The default export destination is `Documents\intune-docs`; operators can
  select another folder, which the exporter resolves before writing. The export writes
  `.intune-docs-manifest.json`, which records the tenant ID and generated-file
  list. If the destination is a Git checkout, its `.git` directory holds the
  output's repository history. Generated script bodies and custom payloads are
  included by default; restrict access to the output and its backups.
- The exporter refuses to overwrite a manifest associated with another tenant.
  If collection is incomplete, it skips stale-file pruning rather than
  fabricating deletions.
- Imported assessment packs persist outside the installation at
  `%LOCALAPPDATA%\IntuneDocsStudio\AssessmentPacks`, one `<sha256>.json` file
  per pack. Packs generated from a CIS build-kit ZIP live in the same folder as
  JSON imports. The build-kit ZIP itself is read in memory and never kept; keep
  your licensed download under your own access controls. Bundled packs are
  reviewed application resources, not customer imports. Active tenant assessment
  results live in memory and clear on session reset/identity replacement; saved
  report files and imported packs are not deleted by that reset.
- Assessment reports go only to the operator's chosen absolute report root.
  Keep installation, documentation export, and report roots mutually disjoint:
  no equal, ancestor, or descendant paths and no reparse-point roots/ancestors.
  A new `assessment-<generated-id>` directory contains `assessment.md` and
  `assessment.json` for each successful run. Reports do not change exporter
  pages/manifests, prune previous runs, or automatically upload, commit, or push.

## Assessment scope and operation

> **Five checks, four partial Microsoft packs, no complete-baseline/compliance
> claim.** Windows 11 has two Windows 26H2 baseline SmartScreen checks; macOS
> has one FileVault recommendation. Both use **legacy Endpoint Protection only
> over Graph beta**, not modern Settings Catalog/endpoint-security mappings.
> The macOS legacy template is deprecated for new profiles. iOS/iPadOS has one
> **personal-only** passcode recommendation; Android Enterprise has one
> **personally-owned work-profile-only** encryption compliance-policy requirement
> recommendation. A compliance-policy requirement is configuration, not measured
> device compliance/encryption. **Missing** is scoped to the rule's completely
> read mapped families/policy types, not tenant-wide absence.

Sign in and verify tenant identity on Home, then open **Assess policies**. The
wizard runs through **Platforms**, **Baselines**, **Context**, **Review & run**
and **Results**. Select platforms, then exact pack versions/profiles; inspect
source revisions, SHA-256, baseline versus recommendations classification, and
partial inventory. The **Import rule packs** card on **Platforms** and
**Baselines** accepts reviewed customer-licensed schema-1 JSON or the licensed
CIS Intune build-kit ZIP downloaded from CIS; click **Import pack**. Validation
and conversion do not attest to source correctness or rights. Packs converted
from a build-kit ZIP are labeled CIS without verifying the source. The
build-kit layout is unverified and the converter is defensive, so read the import
summary: skipped entries with reasons and the number of ignored files. Imported
packs are never selected automatically. CIS benchmark PDFs, Excel, XCCDF/OVAL,
Group Policy and OMA-URI content are not supported. The
[import reference](assessment-rule-packs.md) documents fields, type/operator
support, build-kit ZIP conversion, platform/enrollment context, and limits.
No framework content is downloaded automatically.

On **Context**, supply known OS versions, Android enrollment mode and optional
iOS/iPadOS ownership comparison scope; only the selected platforms' fields are
shown. On **Review & run**, check the summary, select the separate report
destination, and click **Assess selected policies**. Windows 11 uses a numeric
build version such as `10.0.22000`; macOS FileVault needs at least 10.13. A
blank Windows 11 build shows a non-blocking warning: Windows policies targeting
Windows 10 and later, including the Settings Catalog policies that CIS
build-kit packs map to, are then reported as not assessed.
Selected context is not discovered device inventory. Do not invent unknown
values to obtain a pass. iOS ownership defaults to **Unknown**; affirmatively
select **Personally owned** only for that target comparison. Neither scope nor
matching configuration establishes discovered ownership or effective assignment.
For Windows-family profiles, an explicit Windows 11 build establishes comparison
context, not discovered Windows 11 inventory. Real OS include/exclude rules are
honored; malformed/unsupported rules, edition and device-mode conditions remain
not assessed. Known unrelated policy types retain global diagnostics without
blocking mappings that explicitly exclude their type; unknown types and relevant
or unlocalizable failures still block.

Policy loading starts automatically after sign-in. Home exposes the snapshot time,
family counts and limitations. Documentation and assessment reuse that same
tenant-owned in-memory snapshot; reference lookups and other documentation areas
remain export-time reads. Refresh policies on Home to pick up tenant changes;
refresh invalidates active assessment results. Retry failed loading after checking
access, or sign out and sign in again. Partial family reads never justify pruning:
documentation skips those families and preserves previous pages/raw files and
manifest entries. Assessment retains incomplete sources rather than claiming absence.
Sign-out, tenant reset and shutdown discard the snapshot, which is not backed up.
The command-line export remains a direct collection path.

Only one policy load, export or assessment can run. Sign-out and Stop server can
cancel policy loading. For exports and assessments, wait for work to finish before resetting,
switching identity, forgetting a profile, stopping, or updating the app. A healthy
listener is not evidence that an assessment succeeded. Check progress/errors,
then read both reports and the dashboard's policy/assignment and collection
details. Interpret statuses as follows:

| Status | Operator interpretation |
|---|---|
| Aligned | Applicable, complete observed values satisfy the rule, not evidence of delivery to devices. |
| Misaligned | Applicable, complete configured values violate the rule. |
| Missing | Absent/not configured in completely read mapped families/types only. Equivalent unmapped modern settings may exist. |
| Potential conflict | Differing configured values across policies, not proof of overlapping targeting or an Intune conflict. |
| Not applicable | Explicit context excludes the control. |
| Not assessed | Unknown applicability, incomplete/unsupported source/settings evidence, or manual/unmapped logic; never a pass or an absence finding. |

Unassigned policies must be reviewed even when aligned. Included/excluded groups
and filters are evidence only; effective membership/targeting is not resolved.
An assignment-only failure means unknown assignments, not erased configuration
evidence. Review per-policy mismatches even if aggregate status is not assessed.
Assessment coverage is assessed/listed applicable controls; configuration
alignment is aligned/assessed controls. Unknown applicability remains in the
coverage denominator, unavailable denominators are not 100%, and partial packs
do not establish whole-benchmark coverage.

Validation errors do not replace a valid pack; fix the JSON/limit or review the
immutable ID/version/hash collision and use a new version for revised bytes.
Do not delete a valid pack blindly to silence a collision. A build-kit ZIP
import checks every candidate pack before writing; one collision rejects the
whole archive and writes nothing. A storage failure (`500`) during a build-kit
ZIP import can leave some complete packs imported; import the same archive
again, and those packs are reported as already present. Source access failures
(including 403), truncated pagination, and unsupported evidence are not complete
empty reads. Recheck access/source support before rerunning. Authentication
failures fail the run without reports; sign in again. Report-path/write failures
do not publish a successful pair: correct permissions and root separation,
then rerun. Busy responses mean wait, not bypass job/identity safeguards.

## Start, stop, and verify

Start the supported launcher from the extracted application folder:

```powershell
.\Start-IntuneDocs.cmd
```

PowerShell 7 or later is required; the launcher does not install or update
PowerShell and does not fall back to Windows PowerShell 5.1. The dashboard
opens at `http://localhost:7654` unless another port was configured.

To stop cleanly, use **Stop server** in the dashboard or press Ctrl+C in the
launcher console. Wait for the process to exit before replacing application
files. Do not use the health endpoint as evidence that an export has completed.

After startup, check both endpoints from the same machine:

```powershell
Invoke-RestMethod http://localhost:7654/api/health
Invoke-RestMethod http://localhost:7654/api/version
```

Confirm health is `ok`, then verify the expected version, channel, and source
commit in the version response and dashboard build indicator. Do not begin an
export if the identity is missing or does not match the ZIP/build you intended
to run. Health does not attest to tenant identity or Microsoft Graph access;
confirm the signed-in tenant in the dashboard before exporting.

## Updating the application

Keep the application installation separate from every tenant's generated
output and Git checkout. Never use an output folder as an installation folder.

1. Obtain the replacement ZIP from the intended, trusted beta artifact or
   stable release. Verify its source/build identity from its provenance and
   `build-info.json`; for a beta artifact, compare the commit with the intended
   beta source. Do not infer identity from a filename alone.
2. Stop the running server and wait for its process to exit.
3. Extract the product ZIP into a new, empty, versioned application folder.
   Keep the previous application folder until the replacement passes checks.
   Do not copy output data, `.git` history, credentials, or browser profiles
   into the application folder.
4. Start `Start-IntuneDocs.cmd` from the replacement folder. Confirm
   `/api/health`, `/api/version`, and the dashboard's version/channel/commit
   before using it. Sign in again as needed, and confirm the tenant shown is
   the intended tenant before generating documentation.
5. Retain or remove the previous application folder according to local
   change-control policy only after the replacement has been verified.

Customer imports at `AssessmentPacks` survive replacement; do not copy them or
reports into the new installation. Early development builds used
`%LOCALAPPDATA%\IntuneDocsStudio\baseline-packs`; this build does not migrate that
folder automatically. If applicable, preserve the old customer files and
reimport reviewed originals through the dashboard. Verify the resulting hash.
The ZIP contains exactly four vetted Microsoft JSON packs plus the import
reference and runtime modules; it must not contain customer imports, reports,
tests, fixtures, plans/specs, or browser profiles.

The update is a file replacement, not a migration service. No automatic
installation, rollback, or compatibility guarantee between arbitrary builds
is provided.

## Back up and restore generated output

Back up each tenant's output folder as customer data, including
`.intune-docs-manifest.json` and, when present, the complete `.git` directory
and its history. Store backups in an access-controlled location because pages
can include script bodies, device/configuration details, tenant identifiers,
and other sensitive operational data. Choose and test the backup cadence
according to the organization's needs; the application does not schedule or
verify backups.

To restore, restore the complete output to a **new folder**, not over another
tenant's output. Before exporting:

1. Inspect the restored manifest's `tenantId` and compare it with the tenant
   identity shown after signing in.
2. If the folder is a Git checkout, inspect its configured remotes and branch
   (for example, `git remote -v` and `git status --short`) and verify that the
   destination is the intended documentation repository. Do not push until
   that identity is confirmed.
3. Start the intended application build, sign in again, confirm the tenant,
   and only then run an export. Never restore bearer tokens, the browser
   profile, or other sign-in credentials from a backup.

The tenant manifest prevents a detected cross-tenant overwrite; it is not a
backup-integrity check or a guarantee that a restored Git remote is correct.

Back up imported rule-pack files and chosen report roots separately as
customer-owned data, with access controls and any CIS licensing restrictions.
The imported-pack folder holds packs imported as JSON and packs generated from
a CIS build-kit ZIP alike, each as `<sha256>.json`. The application does not
keep the build-kit ZIP; keep your licensed download under your own access controls.
Preserve original bytes for hash provenance. Restore packs outside the app,
review identity/version collisions, and reimport through the dashboard where
needed. Restore reports to a separate data folder, not into exported
documentation or the installation; opening an old report does not restore an
authenticated in-memory result. Never include access tokens, credentials, or
portal browser profiles in these backups.

## Limits and service objectives

There are no measured capacity, throughput, latency, availability, or recovery
objectives for this local tool. No SLO, performance limit, RPO, or RTO is
committed. These values are **unmeasured / not-now**: the application is
operator-run on customer machines. No measured service history or agreed
service commitment is available for deriving a target.
Do not treat example tenant sizes, Graph throttling behavior, or a successful
local test as a measured limit or service guarantee.

Operators own their backup schedule and recovery objectives. Section 18 and
the 111-topic adoption declaration remain incomplete until the authoritative
index, template, validators, and linked reference workflows are supplied.
