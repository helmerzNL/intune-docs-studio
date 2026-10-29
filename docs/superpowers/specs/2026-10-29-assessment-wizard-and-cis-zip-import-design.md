# Assessment wizard and CIS ZIP import — design

Date: 2026-10-29
Status: Draft for owner review. The owner was unavailable during brainstorming and
asked for autonomous progress, so the decisions below use the recommended option
for each question. Every decision is listed in "Decisions to confirm" so the
owner can overturn it during PR review. Nothing merges into `beta` before that
review.

## Goal

1. **Assessment wizard.** Replace the single long Assess page with a guided
   wizard that leads the operator step by step through platforms, baselines,
   comparison context, a review, and the results.
2. **CIS ZIP import.** Let the operator import the ZIP archive downloaded from
   CIS directly, in addition to a single schema-1 JSON rule pack. The app reads
   the archive in memory and converts supported content into local rule packs.
3. **Landing alignment.** The hero and sign-in blocks on the landing page line
   up at the top and the bottom.

The assessment engine, rule semantics, report formats, export, sign-in and Git
publishing stay unchanged.

## Non-goals

- No change to control evaluation, applicability rules, the job model or the
  report formats.
- No parsing of PDF, Excel, XCCDF/OVAL, Group Policy (GPO/ADMX), OMA-URI or
  legacy device-configuration content. The app never downloads CIS content and
  bundles none; the customer supplies their own licensed download.
- No extraction to disk. The archive exists only in memory; only the generated
  rule packs are stored, exactly like a JSON import today.
- No pack deletion, editing or automatic selection.
- No new dependency (`System.IO.Compression` ships with .NET), no change to the
  minimum PowerShell version and no `VERSION` change.
- No change to the documentation workflow or its stepper.

## Background: what a CIS download contains

CIS publishes benchmarks as PDF (and, for members, as Excel and XCCDF/OVAL).
For Microsoft Intune, CIS members can also download **build kits**: ZIP archives
whose policies are Intune Settings Catalog policies in Graph JSON form, intended
for import into a tenant. No licensed build kit was available for this work, so
the exact folder layout is unverified. The converter is therefore defensive: it
walks every `.json` entry, recognizes Settings Catalog policy shapes and schema-1
rule packs, and reports everything else as skipped or ignored with a reason.

## Approaches considered

| Approach | Summary | Verdict |
|---|---|---|
| **A1. Client-side stepper in the Assess view** | Wizard state lives in `app.js`; the five panels toggle with `.hidden`; the stepper reuses the documentation stepper styles. | **Chosen.** No route or server change; element IDs, polling and tests stay intact. |
| A2. One hash route per step | `#/assess/platforms`, `#/assess/baselines`, … | Rejected. Back/forward would jump between half-validated steps, and the router, deep links and focus rules would need rework for no user benefit. |
| A3. Modal wizard | Steps in a dialog over the Assess page. | Rejected. Results need a full-width page, a long run would block the shell, and focus management gets harder. |
| **B1. Server-side in-memory converter** | The browser base64-encodes the ZIP and posts it to the existing pack endpoint. PowerShell reads it with `System.IO.Compression` in memory, converts it to schema-1 packs and validates every pack with the existing reader. | **Chosen.** One validator, no dependency, no disk extraction and the same trust boundary as a JSON import. |
| B2. Client-side unzip | Unzip in the browser and post each JSON. | Rejected. Needs a hand-written ZIP container parser in JavaScript, duplicates conversion logic and moves validation away from the pack reader. |
| B3. ZIP of schema-1 packs only | Accept only already-converted rule packs inside a ZIP. | Rejected as the only path: it does not accept the file CIS actually provides. Still supported as one content kind. |
| B4. Parse benchmark PDF or XCCDF | Extract rules from the benchmark documents. | Rejected. Extraction is unreliable, and XCCDF/OVAL target registry and GPO checks, not Intune settings. |

## Part A — Assessment wizard

### Steps

| # | Stepper label | Panel | Heading | Contents |
|---|---|---|---|---|
| 1 | Platforms | `assessPanelPlatforms` | `platformsTitle` "Choose platforms" | `assessmentPlatforms` check boxes with availability hints; Next. |
| 2 | Baselines | `assessPanelBaselines` | `baselinesTitle` | `assessmentCatalogNote`, `assessmentProfile`, Select all/none, `assessmentPacks`, empty state `assessmentPacksEmpty`; Back, Next. |
| 3 | Context | `assessPanelContext` | `contextTitle` | OS, enrollment and ownership fields for the selected platforms only; Windows 11 warning `assessmentContextWarning`; Back, Next. |
| 4 | Review & run | `assessPanelReview` | `runAssessmentTitle` "Review and run" | Review summary `assessmentReview`, `assessmentOutputPath`; Back, `btnAssessmentRun`. |
| 5 | Results | `assessPanelResults` | `resultsTitle` | Progress bar and phase, report paths, limitations, summary, details, status filter, evidence table; `btnAssessmentRefresh`, `btnAssessNew`. |

The stepper is `<ol class="stepper wide" aria-label="Assessment steps">` with
items `assessStepPlatforms`, `assessStepBaselines`, `assessStepContext`,
`assessStepReview` and `assessStepResults`, each with a numbered
`step-num`. It reuses the documentation stepper styles (`active`, `done`,
`aria-current="step"`) and is not clickable. A new `.stepper.wide` modifier
wraps the five items at 900 px and below. The documentation stepper is
unchanged.

All existing element IDs are kept. `assessmentError` moves directly below the
stepper so errors stay visible on every step. The import controls move into a
separate card, `assessImportPanel` ("Import rule packs"), which follows the
panels and is visible only on steps 1 and 2.

### Navigation and validation

The current step is client state, not a route, so it survives navigating to
Home and back. `setAssessmentStep(step, focus)` mirrors `setDocumentStep`: it
marks earlier items `done`, the current item `active` with
`aria-current="step"`, shows only the current panel and shows the import card on
steps 1–2. It moves focus to the panel heading only after a user action (Next,
Back, New assessment, run admission), never after a background refresh. A
successful Next or Back clears `assessmentError`; a failed validation shows its
message and keeps the current step.

| Action | Validation (error shown in `assessmentError`) | Result |
|---|---|---|
| Step 1 Next (`btnAssessPlatformsNext`) | At least one checked, enabled platform: "Choose at least one platform to assess." | Step 2. |
| Step 2 Back / Next (`btnAssessBaselinesBack`, `btnAssessBaselinesNext`) | Next only: every selected platform has a selected applicable pack ("Every selected platform requires a selected applicable pack; choose at least one platform.") and 1–64 packs are selected ("Select 1–64 packs."). | Step 1 / step 3. |
| Step 3 Back / Next (`btnAssessContextBack`, `btnAssessContextNext`) | None. The server validates OS versions. | Step 2 / step 4 with a freshly built review. |
| Step 4 Back (`btnAssessReviewBack`) | None. | Step 3. |
| Step 4 Run (`btnAssessmentRun`) | Unchanged run validation, including "Select 1–64 packs and an absolute assessment report destination." | On HTTP 202, step 5 with focus. On failure, stay on step 4. |
| Step 5 New assessment (`btnAssessNew`) | Disabled while an assessment runs. | Step 1. Platforms, packs, context and destination are kept; old evidence stays until the next run clears it. |

Background transitions never move focus:

- `refreshAssessment` shows step 5 when the server reports a running or
  completed assessment, for example after a page reload. It runs only at
  start-up, from Refresh, after admission and while polling a running
  assessment, so it cannot pull the operator back to the results after New
  assessment.
- `clearAssessment` (sign-in, sign-out, forget session, quit, workspace reset,
  server session reset) returns to step 1 and also clears the import summary,
  the review and the warning.
- A failed assessment does not change the step; its error appears under the
  stepper.

### Step details

- **Platforms.** Unavailable platforms stay disabled with today's hint
  ("unavailable, import a pack"); the import card is directly below.
- **Baselines.** Pack rows whose platform is not selected or whose profile does
  not match the filter are hidden as well as disabled. When no row is enabled,
  `assessmentPacksEmpty` explains how to change the filter or import a pack.
  The empty state sits outside `assessmentPacks`, so row *i* still maps to
  pack *i*. Select all/none (`btnAssessmentSelectAll`,
  `btnAssessmentSelectNone`) act only on enabled rows. The catalog note now
  says that CIS content is never bundled and that a licensed CIS Intune
  build-kit ZIP or a schema-1 JSON pack can be imported; PDF and Excel
  benchmarks are not supported.
- **Context.** Each field label has an ID (`assessmentContextWindows11`,
  `assessmentContextMacos`, `assessmentContextIosIpados`,
  `assessmentContextAndroidEnterprise`, `assessmentContextEnrollment`,
  `assessmentContextIosOwnership`) and is hidden unless its platform is
  selected. The run handler already sends values for selected platforms only.
  When Windows 11 is selected and its OS version is blank, the non-blocking
  notice `assessmentContextWarning` says that Windows policies targeting
  Windows 10 and later, such as the Settings Catalog policies that CIS
  build-kit packs map to, are assessed only when a Windows 11 build is entered
  (for example 10.0.22631 or 10.0.26100); otherwise their controls are reported
  as not assessed. This reflects the engine's existing rule
  (`Get-IdsRuleApplicability`) that a Windows-family policy needs an explicit
  Windows 11 comparison target.
- **Review & run.** `assessmentReview` is plain text: selected platforms, each
  pack as `id @ version` with platform and profile, every context value
  ("Unknown" when blank) and the Windows 11 warning when it applies.
- **Results.** Unchanged rendering, plus Refresh and New assessment.

### Import card

`assessImportPanel` contains `assessmentImportFile`
(`accept=".json,.zip,application/json,application/zip,application/x-zip-compressed"`),
`btnAssessmentImport`, the status line `assessmentImportSummary`
(`role="status"`) and the catalog errors `assessmentCatalogErrors` (moved here
from the Baselines card so an invalid imported pack is visible from step 1).
Success messages go to `assessmentImportSummary` rather than
`assessmentProgress`. Imported packs are merged into the catalog by identity
(`id@version#sha256`) and are never selected automatically.

- A `.json` file keeps today's checks and messages ("Choose a nonempty JSON
  rule pack, at most 10 MiB." and "Decoded UTF-8 pack exceeds 10 MiB.").
- A `.zip` file (case-insensitive extension) must be 1 byte to 32 MiB
  ("Choose a nonempty ZIP archive, at most 32 MiB."). The browser reads it with
  `arrayBuffer()`, base64-encodes it in 32 KiB chunks and posts
  `{ "archive": "<base64>" }`. The summary lists packs with their control
  counts, how many were new or already present, the first skipped entries with
  reasons, and how many files were ignored.
- Any other file, or no file: "Choose a JSON rule pack (at most 10 MiB) or a
  ZIP archive (at most 32 MiB)." Nothing is read.

## Part B — CIS ZIP import

### API

`POST /api/assessment/packs` keeps its same-origin, content-type and 64 MiB
request checks and now accepts **exactly one** of two fields:

- `content` — unchanged: original UTF-8 JSON text of one schema-1 pack, at most
  10 MiB; HTTP 201 `{ pack }`.
- `archive` — strict base64 (`A–Z a–z 0–9 + /`, at most two `=` padding
  characters, length a multiple of 4), at most 44,739,244 characters, decoding
  to 1 byte–32 MiB.

For an archive the server converts it, checks every generated pack against the
current catalog before writing anything, imports the set and answers HTTP 201:

```json
{
  "packs": [ { "...pack metadata": "...", "controlCount": 212, "added": true } ],
  "added": 1,
  "skipped": [ { "entry": "kit/readme.json", "reason": "Not a Settings Catalog policy or rule pack." } ],
  "skippedCount": 1,
  "ignored": 4,
  "archive": { "sha256": "<hex>" }
}
```

`skipped` lists at most 100 items; `skippedCount` holds the total. Entry names
are truncated to 260 characters. When nothing is importable the server answers
HTTP 400 with `skipped` and `ignored` and the error "The archive contains no
importable rule packs or Settings Catalog policies. PDF, Excel, XCCDF/OVAL,
Group Policy and OMA-URI content is not supported."

Returned pack metadata carries `origin: "imported"` for both `content` and
`archive` imports, matching what the catalog reports after a reload. Today a
JSON import returns no origin, so the new pack is briefly labeled "unverified
origin" until the next catalog load.

### Reading the archive (`lib\BaselineArchive.ps1`)

`ConvertFrom-IdsBaselineArchive -Bytes <byte[]>` returns
`{ packs = <byte[][]>; skipped; ignored; sha256 }`. It opens a `ZipArchive` over
a read-only `MemoryStream`; nothing is extracted.

| Limit or rule | Behavior |
|---|---|
| Not a valid ZIP | HTTP 400 "The file is not a valid ZIP archive." `ZipArchive` reports this as `InvalidDataException`, which the API maps to 413, so the converter rethrows it as an argument error. |
| More than 1,000 entries or more than 500 `.json` entries | HTTP 400. |
| Entry name with a `..` segment, a leading `/` or `\`, or a `:` | Whole archive rejected (HTTP 400), although nothing is extracted. |
| Directory | Ignored silently. |
| Non-JSON file (PDF, XLSX, XML, …) | Counted in `ignored`. |
| Nested `.zip` | Skipped: "Nested ZIP archives are not opened; extract and upload the inner ZIP." |
| Encrypted, corrupt or unsupported compression | Skipped: "Could not be read (encrypted, corrupt or unsupported compression)." |
| JSON entry over 10 MiB (declared or actual) | Skipped. |
| More than 64 MiB of JSON read in total | HTTP 413 (decompression bomb guard). |

JSON entries may use UTF-8 (with or without a BOM) or UTF-16 LE/BE with a BOM.
They are parsed
with `System.Text.Json` (depth 64) and converted with the existing
`ConvertFrom-IdsPackJsonElement`, so duplicate keys or strings longer than
32,768 characters skip the entry. Any other per-entry failure also skips the
entry with a reason; only archive-level limits fail the request.

### Recognized content

1. **Schema-1 rule pack** — a top-level `schemaVersion`. The entry is
   re-encoded as UTF-8 without BOM and validated by `Read-IdsBaselinePack`.
2. **Settings Catalog policies** — an object with `settings`, an array of such
   objects, or `{ "value": [ … ] }`. Anything else is skipped as "Not a Settings
   Catalog policy or rule pack."

### Converting Settings Catalog policies

- **Name**: `name`, else `displayName`, else the entry file name.
- **Platform**: the existing `Get-IdsAssessmentPlatform` mapping (`windows10`,
  `windows11` or `windows10AndLater` → `windows11`; `macOS` → `macos`; `iOS` →
  `iosIpados`; `androidEnterprise` → `androidEnterprise`). Other or combined
  platforms are skipped.
- **Level**: the policy name must contain exactly one distinct CIS profile
  token: case-sensitive `L1`, `L2`, `BL` or `NG` as standalone tokens, or
  case-insensitive "Level 1" / "Level 2". Otherwise the policy is
  "Unclassified build kit policies".
- **Grouping**: one pack per platform and level.

| Level | Profile label | ID slug |
|---|---|---|
| L1 | Level 1 (L1) | `l1` |
| L2 | Level 2 (L2) | `l2` |
| BL | BitLocker (BL) | `bl` |
| NG | Next Generation Windows Security (NG) | `ng` |
| none | Unclassified build kit policies | `build-kit` |

**Controls.** Every `settingInstance` runs through the existing
`ConvertTo-IdsCatalogObservations` normalizer, the same code that reads tenant
policies. Each supported, configured, non-secret observation with a value type
becomes one control:

- `id` is the setting definition ID; `title` is the definition display name when
  the policy carries `settingDefinitions`, otherwise the setting ID.
- `reference` names the source policy and archive entry (at most five, then
  "and N more").
- The single mapping is `family: settingsCatalog`, `policyTypes:
  ["deviceManagementConfigurationPolicy"]`, the `settingId`, `property: null`,
  `instancePath: null` (any instance), the observed `valueType`, operator `eq`
  for scalars or `setEquals` for string and number sets, `expected` set to the
  configured value, and `caseSensitive: true`.
- Choice settings yield the choice and each configured child as separate
  controls; group collections yield only their children.

Skipped with a reason: a setting ID that occurs more than once in any policy of
the group (repeated group instances cannot be expressed as one any-instance
check, so the setting is skipped for the whole pack), the same setting ID with
different values in two policies of one group (equal values merge into one
control with both references), and unsupported, secret, template-default or
not-configured settings. Groups with no controls produce no pack.

**Pack metadata.**

| Field | Value |
|---|---|
| `schemaVersion`, `platform` | `1`; the group's platform. |
| `id` | `cis.<platform>.<slug>`, lower case, for example `cis.windows11.l1`. |
| `version` | `1.0.0+<first 12 hex characters of the SHA-256 of the pack serialized with version 1.0.0>`. Identical input gives an identical pack, so re-importing the same archive is idempotent. |
| `framework`, `classification`, `profile` | `CIS`, `baseline`, the level label. |
| `frameworkVersion` | Per pack: the single distinct `vX.Y.Z` found in its policy names (then its entry paths), else "Unknown (customer-supplied build kit)". |
| `sourceRevision` | Names the archive SHA-256 for traceability. |
| `sources` | One source `cis-build-kit`: `https://workbench.cisecurity.org/`, revision with the archive SHA-256, `retrievedOn` = newest timestamp of the entries used (`yyyy-MM-dd`). |
| `coverage` | `inventory: partial`, `totalSourceControls: null`. |

Packs are written with `Utf8JsonWriter` (indented, UTF-8 without BOM, explicit
handling of integers, decimals, Booleans, nulls, objects and arrays), must stay
within 10 MiB and are re-validated with `Read-IdsBaselinePack` before import.

### Batch import

`Import-IdsBaselinePackSet -Packs <byte[][]> -ImportedRoot <path>` in
`lib\BaselinePacks.ps1`:

1. Validates every pack, drops byte-identical duplicates and rejects two
   different packs with the same ID and version.
2. Applies the existing root checks (absolute path, no reparse points, no
   overlap with the installation).
3. Takes the `.import.lock` once, reads the imported catalog once and rejects
   conflicts with existing packs.
4. Writes each new pack through a staging file and an atomic move, as today.

It returns `{ pack; added }` per pack. `Import-IdsBaselinePack` becomes a
one-pack call of the set function with identical error messages. If storage
fails halfway, packs already moved stay imported (each is complete and valid)
and the request fails with HTTP 500; this is documented.

## Part C — Landing alignment

`.landing` stretches both blocks to one shared row (`align-items: stretch`,
`align-content: center`) so their top and bottom edges match at every desktop
width, including when "Advanced sign-in options" is expanded. Both blocks are
flex columns that centre their content, so the shorter block's content stays
balanced. The stacked layout at 900 px and below is unchanged. A static test
guards the rule.

## Security and limits

- Same-origin, content-type and request-size checks are unchanged. Pack import
  still works signed out, as today.
- All archive work happens in memory, with the limits above bounding memory
  and CPU. Nothing from the archive is written except validated packs.
- Entry names and reasons are rendered with `textContent` only.
- No archive or tenant data leaves the computer. Tests use synthetic,
  in-memory ZIPs; no CIS content is committed.
- The local server handles requests one at a time, so a large import briefly
  delays progress polling. Imports are disabled while an export or assessment
  runs.

## Error handling

| Situation | Status | Message |
|---|---|---|
| Neither or both of `content` and `archive` | 400 | "Provide exactly one of content or archive." |
| Invalid base64, empty archive, invalid ZIP, unsafe entry name, too many entries | 400 | Specific message. |
| Archive over 32 MiB, or JSON budget exceeded | 413 | Specific message. |
| Nothing importable | 400 | See "API". |
| Two different packs with the same ID/version in the archive | 400 | Names the pack ID and version. |
| Conflict with an existing pack | 400 | Names the pack ID and version; nothing is written. |
| Storage failure | 500 | "Local assessment storage failed." |
| Browser: wrong extension or size | — | Shown in `assessmentError` before any request. |

## Behavior and data flow

1. The operator opens Assess and lands on step 1, or on step 5 if an
   assessment is running or completed in this session.
2. They import packs (JSON or ZIP) on step 1 or 2 when needed, choose
   platforms, then packs, then optional context, review and run.
3. On admission the wizard moves to step 5; polling fills in progress and
   results exactly as today.
4. New assessment returns to step 1 with the previous choices kept.

## Testing

- **Pester (new `tests\BaselineArchive.Tests.ps1`)** — in-memory ZIPs only:
  valid ZIP limits and HTTP 413 budgets; unsafe names; nested, encrypted and
  non-JSON entries; corrupt archive; UTF-8/UTF-16 BOMs; single, array and
  `value` shapes; choice, child, collection, integer and string settings;
  secret, unsupported, repeated and conflicting settings; level grouping;
  deterministic ID, version and bytes; idempotent re-import; schema-1 packs in
  a ZIP.
- **Pester (existing files)** — `Import-IdsBaselinePackSet` (batch conflicts,
  duplicates, lock, single import unchanged) in `AssessmentPacks.Tests.ps1`;
  the `archive` field, exactly-one rule, base64 validation, summary,
  nothing-importable answer and conflict pre-check in
  `AssessmentApi.Tests.ps1`; the 32-file package list in `Package.Tests.ps1`.
- **Node (`tests\assessment-ui.test.js`)** — step navigation and validation;
  step 5 after admission, running or completed; New assessment;
  `clearAssessment` returns to step 1; Select all/none; hidden rows and empty
  state; context fields per platform; the Windows 11 warning; the review text;
  ZIP import (base64 post, summary, merge, size errors). Existing tests keep
  passing.
- **Node (`tests\app-shell-ui.test.js`)** — landing alignment rule; new IDs
  exist exactly once.
- Visual check at 1280 px and 390 px with synthetic data.

## Documentation

- `docs\assessment-rule-packs.md`: ZIP import, supported and unsupported
  content, conversion rules, limits, the API `archive` field and the response.
- `README.md` and `QUICKSTART.md`: the wizard and ZIP import in the Assess
  instructions.
- `docs\operations.md`: imported packs generated from a ZIP live in the same
  imported-pack folder; the archive itself is not kept.

## Decisions to confirm (made autonomously)

1. Five wizard steps: Platforms, Baselines, Context, Review & run, Results.
2. The import card is a separate, always-open card shown on steps 1 and 2 only.
3. Context fields are shown only for selected platforms.
4. A blank Windows 11 build gives a warning, not a blocking error.
5. Imported packs are never selected automatically.
6. New assessment is disabled while an assessment runs and keeps the previous
   choices.
7. Supported ZIP content: CIS Intune build-kit Settings Catalog JSON and
   schema-1 rule packs. PDF, Excel, XCCDF/OVAL, GPO/ADMX and OMA-URI are not
   supported.
8. CIS profile levels are detected from policy names (L1, L2, BL, NG, "Level
   1/2"); anything else is grouped as unclassified.
9. A control ID is the Settings Catalog setting ID.
10. Mappings match any instance (`instancePath: null`); settings repeated within
    one policy are skipped.
11. Expected values are the build kit's configured values, compared strictly
    (`eq` / `setEquals`, case-sensitive).
12. Versions are `1.0.0+<content hash>`; the source revision names the archive
    SHA-256, so a re-zipped archive yields new versions; `retrievedOn` comes
    from the entry timestamps.
13. Limits: 32 MiB archive, 1,000 entries, 500 JSON entries, 10 MiB per JSON
    entry, 64 MiB of JSON in total.
14. A storage failure mid-import may leave some complete packs imported.
15. The package grows from 31 to 32 files (`lib\BaselineArchive.ps1`).
16. Landing blocks share one row height and centre their content.
17. Import responses report `origin: "imported"`, also for single JSON packs.
18. Catalog errors move into the import card so they are visible from step 1.

Open question for the owner: the file listing (names only, no content) of a
real CIS build-kit ZIP, so the converter can be checked against the actual
layout.
