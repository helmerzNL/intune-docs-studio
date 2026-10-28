# Policy Baseline Comparison Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking. Use subagents only if the owner chooses that execution mode.

**Goal:** Add local, evidence-based Microsoft/CIS policy assessments for Windows 11, macOS, iOS/iPadOS, and Android Enterprise without changing tenant configuration or existing documentation exports.

**Architecture:** A shared deterministic engine evaluates versioned declarative packs against typed policy observations and explicit collection-completeness evidence. Dedicated modules handle packs, collection, normalization, evaluation, reports, and jobs; the existing localhost dashboard supplies the user workflow. Microsoft packs ship with the application, while CIS packs and reports remain customer-owned local files.

**Tech Stack:** PowerShell 7+, existing Graph transport and HttpListener, vanilla JavaScript/HTML/CSS, Pester, Node's built-in test runner. No new dependencies.

**Spec:** `docs\superpowers\specs\2026-10-28-policy-baseline-comparison-design.md`

## Global Constraints

- The first release supports Windows 11, macOS, iOS/iPadOS, and Android Enterprise.
- Use the connected tenant and existing read-only authentication.
- Distinguish official Microsoft security baselines from Microsoft recommendations.
- Compare configured values across policies and display assignment evidence and potential conflicts, without resolving effective device/user targeting.
- Add a dashboard assessment area and separate Markdown/JSON reports.
- Preserve existing documentation exports and Git publishing behavior.
- Do not bundle CIS benchmark content, download it automatically, or assume redistribution rights.
- Limit each pack to 10 MiB of UTF-8 JSON, 32 nesting levels, 20,000 controls, and 32,768 characters per string.
- Do not change `VERSION`, add dependencies, or raise the minimum PowerShell version.
- Allow only one export or assessment at a time in this release.
- Implementation work starts from and targets `beta`; stable promotion and release remain owner-authorized operations.

The feature worktree has already been fast-forwarded to the available `origin/beta`.
Before execution, read `AGENTS.md`, the spec, and this plan. Do not edit the main
checkout. Do not create a PR or release unless the owner requests one.

## File ownership and dependency order

| File | Responsibility |
|---|---|
| `lib\BaselinePacks.ps1` | Pack validation, byte identity, bundled/imported catalog, local import storage. |
| `lib\AssessmentCollection.ps1` | Strict Graph pagination, family adapters, source/assignment completeness. |
| `lib\AssessmentSettings.ps1` | Typed normalization and policy-family applicability. |
| `lib\AssessmentRules.ps1` | Pure comparison, aggregate statuses, coverage counts. |
| `lib\AssessmentReports.ps1` | Safe Markdown/JSON serialization and staged report publication. |
| `lib\Assessment.ps1` | Assessment lifecycle, job guards, report orchestration. |
| `lib\AssessmentApi.ps1` | Bounded request parsing and assessment route dispatch. |
| `baselines\microsoft-*.json` | Explicitly packaged, verified Microsoft rules only. |
| `web\index.html`, `web\app.js`, `web\style.css` | Assessment area integrated with current dashboard patterns. |
| `IntuneDocsStudio.ps1` | Module loading, shared lifecycle/reset integration, local route wiring. |
| `lib\Http.ps1` | Opt-in JSON serialization depth for assessment responses only. |
| `tests\TestHelpers\Assessment.ps1` | Synthetic pack/snapshot factories; no live tenant material. |
| `tests\Assessment*.Tests.ps1`, `tests\assessment-ui.test.js` | Focused synthetic verification. |
| `Build-Package.ps1`, `tests\Package.Tests.ps1` | Explicit resource packaging and exclusion checks. |
| `README.md`, `QUICKSTART.md`, `docs\operations.md`, `docs\assessment-rule-packs.md` | User/operator instructions and import contract. |

Tasks 2 and 3 consume Task 1 contracts. Task 4 consumes Tasks 1-3. Task 5
verifies production data against Tasks 1-4. Task 6 consumes Task 4 results.
Task 7 consumes Tasks 1-6; Task 8 consumes its API. Task 9 integrates packaging
and whole-feature acceptance. Keep these tasks in the current branch; separate
modules are implementation boundaries, not independent product releases.

## Shared contracts

Use ordinary PowerShell objects/hashtables consistent with this repository.
Return single root objects with array-valued properties; do not let pipeline
unrolling change empty/singleton result shapes. All JSON uses `schemaVersion: 1`.

### Pack

`Read-IdsBaselinePack -Bytes [byte[]]` returns a `PSCustomObject`:

```text
schemaVersion, id, version, framework, frameworkVersion, classification,
platform, profile, sourceRevision, sources[], coverage, controls[], sha256

platform: windows11 | macos | iosIpados | androidEnterprise
classification: baseline | recommendations
coverage: { inventory: complete | partial, totalSourceControls: integer|null }
sources[]: { id, url, revision, retrievedOn }
controls[]: {
  id, title, sourceIds[], reference,
  applicability: { osMin, osMax, enrollmentModes[] },
  manualReason: string|null,
  mappings[]: {
    family, policyTypes[], settingId, property, instancePath,
    valueType, operator, expected, caseSensitive
  }
}
```

Families: `settingsCatalog`, `deviceConfiguration`, `compliance`, `admx`,
`intent`. A control has either one or more alternative source mappings for
the same atomic check or a nonempty `manualReason`, never executable logic.
Exactly one of `settingId` and `property` identifies a mapped setting.
Property selectors must be in the adapter's allowlist for the declared Graph
policy type; they are not arbitrary object expressions.

Types: `boolean`, `number`, `string`, `stringSet`, `numberSet`.
Operators: `eq`, `ne`, `gte`, `lte`, `in`, `setEquals`, `containsAll`.
Only numeric values accept bounds; `in` expects a nonempty typed scalar array;
set operators accept typed arrays. String comparisons explicitly use
`caseSensitive`; arrays use set semantics and never comma-joined display text.
Do not coerce strings to booleans/numbers to make a rule pass.

`sha256` is computed from the original validated bytes; imported JSON cannot
supply or override it. Unknown fields and duplicate JSON member names are
rejected to avoid ambiguous interpretations.
Restrict IDs to `[a-z][a-z0-9.-]{0,127}` and versions to semantic-version syntax
without `@` or `#`, so catalog selection identities have an unambiguous encoding.

### Collection and normalization

```text
Collection: {
  policies[], sources[], issues[]
}
Policy: {
  key, id, name, family, policyType, template,
  platform, osMin, osMax, enrollmentMode,
  rawSettings[], assignments[], settingsComplete, assignmentsComplete
}
Source: { family, platform, complete, errors[] }
Issue: { family, policyKey, stage, statusCode, reason }
Snapshot: {
  observations[], policies[], sources[], issues[]
}
Observation: {
  policyKey, family, settingId, property, instancePath,
  valueType, value, configured, secret, supported
}
Context: {
  platforms[], osVersions: { platform: string },
  enrollmentModes: { androidEnterprise: string }
}
```

`key` is `family:id`; modern endpoint-security/baseline policies returned under
configuration policies retain the `settingsCatalog` family plus template
metadata. Omitted values remain absent; explicit `false` and `0` are configured.
Known secret values yield an unsupported/redacted observation without retaining
the secret. Assignment-only failures do not mark settings reads incomplete.

### Results

```text
Result: {
  schemaVersion, runId, generatedAt, tenant, context,
  packs[], summaries[], controls[], policies[], collectionIssues[]
}
ControlResult: {
  packId, packVersion, platform, profile, controlId, title,
  status, reason, expected, observed[], policyResults[], references[]
}
PolicyResult: {
  policyKey, status, reason, expected, observed[], assigned, assignmentsComplete
}
Summary: {
  packId, platform, profile, inventory,
  counts: { aligned, misaligned, missing, potentialConflict,
            notApplicable, notAssessed },
  assessed, coverageDenominator, coveragePercent, alignmentPercent
}
```

Use machine statuses `aligned`, `misaligned`, `missing`, `potentialConflict`,
`notApplicable`, `notAssessed`. UI labels can be human-readable. Percentages are
rounded to one decimal, with null for an unavailable denominator.
Result `packs` contains identity/source/coverage metadata, not copies of whole
imported packs. Result `policies` contains only ID/name/family/type/platform,
template identity, assignment evidence, and assignment completeness; never copy
Collection policy objects, `rawSettings`, or `rawSettings` payloads into Result.

Each task commit must include:

```text
Co-authored-by: Copilot App <223556219+Copilot@users.noreply.github.com>
```

## Task 1: Validated packs and synthetic test factories

**Files:** Create `lib\BaselinePacks.ps1`,
`tests\TestHelpers\Assessment.ps1`, `tests\AssessmentPacks.Tests.ps1`,
and `docs\assessment-rule-packs.md`.

**Interfaces:**

- `Read-IdsBaselinePack -Bytes [byte[]] -> [pscustomobject]` follows the Pack contract.
- `Get-IdsBaselinePacks -BundledRoot [string] -ImportedRoot [string] -> [pscustomobject]`
  returns `{ packs = @(); errors = @() }`, never silently skips malformed files.
- `Import-IdsBaselinePack -Bytes [byte[]] -ImportedRoot [string] -> [pscustomobject]`
  returns the validated pack. Use a generated/hash-derived filename, never an
  imported filename or pack ID as a path.
- `Get-IdsAssessmentPropertyCatalog -> [hashtable]` owns the explicit
  family/policy-type/property/value-type allowlist; normalization consumes it
  without a reverse dependency on the normalizer.
- `New-IdsTestPackBytes -Platform [string] = 'windows11' -> [byte[]]` is a test
  helper returning this synthetic pack:

```powershell
function New-IdsTestPackBytes {
    param([string]$Platform = 'windows11')
    $pack = @{
        schemaVersion = 1; id = 'synthetic-pack'; version = '1.0.0'
        framework = 'Synthetic'; frameworkVersion = '1'
        classification = 'recommendations'; platform = $Platform
        profile = 'test'; sourceRevision = 'synthetic-v1'
        sources = @(@{ id = 'source'; url = 'https://example.invalid/rules'
            revision = 'synthetic-v1'; retrievedOn = '2026-10-28' })
        coverage = @{ inventory = 'partial'; totalSourceControls = $null }
        controls = @(@{
            id = 'SYN-1'; title = 'Synthetic required setting'
            sourceIds = @('source'); reference = 'SYN-1'; manualReason = $null
            applicability = @{ osMin = $null; osMax = $null; enrollmentModes = @() }
            mappings = @(@{
                family = 'settingsCatalog'; policyTypes = @('configurationPolicy')
                settingId = 'synthetic.required'; property = $null
                instancePath = $null; valueType = 'boolean'
                operator = 'eq'; expected = $true; caseSensitive = $true
            })
        })
    }
    return ,([Text.Encoding]::UTF8.GetBytes(($pack | ConvertTo-Json -Depth 20)))
}
```

- [ ] **Step 1: Add failing tests.** Dot-source the module and factory in
  `BeforeAll`. Establish identity and false-value preservation:

```powershell
It 'validates a synthetic pack and hashes the original bytes' {
    $bytes = New-IdsTestPackBytes
    $pack = Read-IdsBaselinePack -Bytes $bytes
    $pack.controls.Count | Should -Be 1
    $pack.sha256 | Should -Match '^[0-9a-f]{64}$'
    $copy = [Text.Encoding]::UTF8.GetString($bytes) | ConvertFrom-Json
    $copy.controls[0].mappings[0].expected = $false
    $changed = [Text.Encoding]::UTF8.GetBytes(($copy | ConvertTo-Json -Depth 20))
    (Read-IdsBaselinePack -Bytes $changed).controls[0].mappings[0].expected |
        Should -BeFalse
    (Read-IdsBaselinePack -Bytes $changed).sha256 | Should -Not -Be $pack.sha256
}
```

  Add explicit mutation cases for duplicate control/member IDs, unsupported
  operators, unknown fields, string booleans, bad sources, wrong platform,
  empty mappings/manual reason, and all four documented resource limits.
  Import tests must preserve an existing valid pack after a rejected import,
  reject traversal IDs as storage names, and expose corrupted catalog entries.
- [ ] **Step 2: Run red.**
  `pwsh -NoProfile -Command "Invoke-Pester .\tests\AssessmentPacks.Tests.ps1 -Output Detailed"`
  must fail because the new functions do not exist.
- [ ] **Step 3: Implement strict parsing/validation.** Walk JSON with
  `System.Text.Json.JsonDocument`, reject duplicate names recursively, then
  deserialize validated content. Bound bytes before parsing, validate field
  names/types and operator/type combinations, and compute identity:

```powershell
$sha = [Security.Cryptography.SHA256]::Create()
try {
    $hash = ([BitConverter]::ToString($sha.ComputeHash($Bytes))).
        Replace('-', '').ToLowerInvariant()
} finally { $sha.Dispose() }
```

  Keep pack-source URLs as references only. Use staged writes in the imported
  root and reject an existing ID/version with different bytes. Document every
  field, type, limit, error, and operator, including the synthetic example's
  nonproduction status. Catalog results distinguish bundled versus imported
  origin without changing pack byte identity.
  Initialize the property catalog from verified Graph documentation, starting
  with this implementation shape:

```powershell
return @{
    'compliance:macOSCompliancePolicy' = @{
        storageRequireEncryption = 'boolean'
        systemIntegrityProtectionEnabled = 'boolean'
        passwordMinimumLength = 'number'
    }
}
```

  These property names/types were verified against
  <https://learn.microsoft.com/en-us/graph/api/resources/intune-deviceconfig-macoscompliancepolicy?view=graph-rest-1.0>.
  They establish encoding only, not Microsoft recommended values. Extend this
  catalog with reviewed Graph property definitions for other supported policy
  types during normalization/source curation; unknown properties remain rejected.
- [ ] **Step 4: Run green.** Repeat the exact Task 1 command.
- [ ] **Step 5: Commit only Task 1 files** with message
  `feat: validate versioned assessment rule packs` and the required trailer.

## Task 2: Complete policy reads with explicit failure evidence

**Files:** Create `lib\AssessmentCollection.ps1` and
`tests\AssessmentCollection.Tests.ps1`.

**Interfaces:**

- `Get-IdsAssessmentPages -Path [string] -Version [string] = 'beta' -> [pscustomobject]`
  returns `{ items = @(); complete = [bool]; errors = @() }`.
- `Get-IdsAssessmentCollection -Packs [object[]] -Context [hashtable] -> [pscustomobject]`
  returns Collection. Consumes Task 1 validated mappings to select relevant
  source families; do not use imported URLs for requests.

- [ ] **Step 1: Add failing pagination and collection tests.**

```powershell
It 'does not treat a failed second page as a complete first page' {
    Mock Invoke-IdsGraph {
        param($Path)
        if ($Path -eq '/synthetic') {
            return [pscustomobject]@{
                value = @([pscustomobject]@{ id = 'policy-a' })
                '@odata.nextLink' = 'https://graph.microsoft.com/beta/synthetic?page=2'
            }
        }
        throw 'synthetic access failure'
    }
    $page = Get-IdsAssessmentPages -Path '/synthetic'
    $page.complete | Should -BeFalse
    $page.items.Count | Should -Be 1
    $page.errors.Count | Should -Be 1
}
```

  Add cases for zero/single/multiple pages, cycles, a 500-page cap with a
  remaining next link, malformed bodies, omitted batch entries, 403/429/5xx,
  nested settings next links, and assignment read failure isolated from settings.
  Verify no imported reference URL can become a Graph request.
- [ ] **Step 2: Run red.**
  `pwsh -NoProfile -Command "Invoke-Pester .\tests\AssessmentCollection.Tests.ps1 -Output Detailed"`
- [ ] **Step 3: Implement the strict page reader and adapters.** Use existing
  transport/retry behavior, but call individual pages without `-All` or
  `-Tolerant`. Inspect every batch status before processing its body:

```powershell
$page = Invoke-IdsGraph -Path $next -Version $Version
if ($null -eq $page -or -not $page.PSObject.Properties['value'] -or
    $null -eq $page.value) {
    throw 'Expected a Graph collection with a value array.'
}
foreach ($item in @($page.value)) { [void]$items.Add($item) }
```

  Validate next links against HTTPS `graph.microsoft.com`, the selected API
  version, and the same resource path before following them; disallow credentials,
  fragments, or foreign hosts. Retain partial items with `complete = $false`
  and a reason after failure. The known top-level families are
  `/deviceManagement/configurationPolicies`,
  `/deviceManagement/deviceConfigurations`,
  `/deviceManagement/deviceCompliancePolicies`,
  `/deviceManagement/groupPolicyConfigurations`, and
  `/deviceManagement/intents`. Use their existing exporter read patterns for
  settings/definition values/presentation values/templates, but independently
  paginate settings and assignments and preserve all failures.
  Group-name resolution is optional display evidence; failed resolution must
  retain the group ID and an explicit unresolved label.
- [ ] **Step 4: Run green.** Repeat the Task 2 command and Task 1 tests together
  in one Pester invocation using both paths.
- [ ] **Step 5: Commit** `feat: collect assessment policies with completeness evidence`.

## Task 3: Typed normalization for every supported policy family/platform

**Files:** Create `lib\AssessmentSettings.ps1`,
`tests\AssessmentSettings.Tests.ps1`. Extend only synthetic factories in
`tests\TestHelpers\Assessment.ps1`.

**Interfaces:**

- `ConvertTo-IdsAssessmentSnapshot -Collection [pscustomobject] -> [pscustomobject]`
  returns Snapshot, preserving Collection issues and policy metadata.
- Consumes Task 1's `Get-IdsAssessmentPropertyCatalog`; expand the catalog in
  `lib\BaselinePacks.ps1` only for documented Graph policy-type/property pairs.
  Include that file in this task's changed-file list when expanding it.

- [ ] **Step 1: Add a typed nested-instance regression.**

```powershell
It 'retains a configured false property without display conversion' {
    $collection = [pscustomobject]@{
        policies = @([pscustomobject]@{
            key = 'compliance:policy-a'; id = 'policy-a'; name = 'Synthetic'
            family = 'compliance'; policyType = 'macOSCompliancePolicy'
            platform = 'macos'; template = $null
            osMin = $null; osMax = $null; enrollmentMode = $null
            assignments = @(); settingsComplete = $true; assignmentsComplete = $true
            rawSettings = @([pscustomobject]@{
                '@odata.type' = '#microsoft.graph.macOSCompliancePolicy'
                storageRequireEncryption = $false
            })
        })
        sources = @(); issues = @()
    }
    $snapshot = ConvertTo-IdsAssessmentSnapshot -Collection $collection
    $snapshot.observations.Count | Should -Be 1
    $snapshot.observations[0].configured | Should -BeTrue
    $snapshot.observations[0].value | Should -BeFalse
    $snapshot.observations[0].valueType | Should -Be 'boolean'
}
```

  Add table-driven cases for four platforms, Android work profile versus fully
  managed/dedicated modes, Windows generic metadata that cannot identify Windows
  11 on its own, all five policy families, choice IDs/children, simple/group
  collections, repeated paths, ADMX presentations, intent `valueJson`, zero,
  empty arrays, null/unconfigured states, and secrets.
- [ ] **Step 2: Run red.**
  `pwsh -NoProfile -Command "Invoke-Pester .\tests\AssessmentSettings.Tests.ps1 -Output Detailed"`
- [ ] **Step 3: Implement family adapters.** Retain choice option IDs as strings,
  numeric values as numbers, and collections as arrays. Match raw identifiers,
  not `Get-IdsOptionText` output. Guard recursive traversal at 32 levels; an
  unsupported shape emits a diagnostic/unsupported observation and affects
  relevant control completeness. Track repeated groups by stable instance path.
  Use the Graph policy type/template metadata for platform/enrollment mapping;
  ambiguous metadata remains unknown rather than guessing from the policy name.
  Never retain secret values when building intermediate observations.
  Legacy/configuration/compliance `rawSettings` holds the fetched policy's
  settings-bearing object; the normalizer emits only allowlisted properties,
  not metadata such as ID or display name.
  Implement typed allowlisted property reads:

```powershell
$propertyInfo = $raw.PSObject.Properties[$propertyName]
$configured = $null -ne $propertyInfo -and $null -ne $propertyInfo.Value
$value = if ($configured) { $propertyInfo.Value } else { $null }
```

  Check property presence without truthiness. Do not parse custom XML/mobileconfig
  payloads or scripts into approximate rules; mark those mappings unsupported.
- [ ] **Step 4: Run green.** Run Task 1-3 Pester paths in one invocation.
- [ ] **Step 5: Commit** `feat: normalize typed policy assessment evidence`.

## Task 4: Pure rules engine, conservative aggregation, and coverage

**Files:** Create `lib\AssessmentRules.ps1` and
`tests\AssessmentRules.Tests.ps1`.

**Interfaces:**

- `Compare-IdsAssessmentValue -Mapping [pscustomobject] -Observation [pscustomobject] -> [pscustomobject]`
  returns `{ assessed = [bool]; aligned = [bool]; reason = [string] }`.
- `Compare-IdsAssessment -Packs [object[]] -Snapshot [pscustomobject] -Context [hashtable] -> [pscustomobject]`
  returns `{ controls = @(); summaries = @() }`. No network/file access.
  Task 7 supplies run/tenant metadata to create Result.

- [ ] **Step 1: Add failing numeric, false/zero, conflict, and coverage tests.**

```powershell
It 'does not accept an encoded numeric string as a numeric bound' {
    $mapping = [pscustomobject]@{
        valueType = 'number'; operator = 'gte'; expected = 8; caseSensitive = $true
    }
    $observation = [pscustomobject]@{
        configured = $true; supported = $true; secret = $false
        valueType = 'string'; value = '12'
    }
    $comparison = Compare-IdsAssessmentValue -Mapping $mapping -Observation $observation
    $comparison.assessed | Should -BeFalse
    $comparison.reason | Should -Not -BeNullOrEmpty
}
```

  Build fixtures for status precedence: known exclusion; unknown applicability;
  incomplete relevant source; equal duplicates; mixed true/false policies;
  different numeric values both meeting a bound; absent values with complete
  collection; explicit false/zero; unassigned policy matches; assignment-only
  failure; manual/unsupported checks. Include string case sensitivity,
  typed set equality/containment, `in`, and every operator/type rejection.
  For counts `{aligned=1, misaligned=1, missing=1, potentialConflict=1,
  notApplicable=1, notAssessed=2}`, require assessed 4, coverage denominator 6,
  coverage 66.7, and alignment 25.0. Empty denominators must yield null.
- [ ] **Step 2: Run red.**
  `pwsh -NoProfile -Command "Invoke-Pester .\tests\AssessmentRules.Tests.ps1 -Output Detailed"`
- [ ] **Step 3: Implement comparisons and aggregation.** Filter observations by
  family/type/identifier/path and explicit applicability. Treat mappings as
  alternatives for the same check, not compound control logic. Deduplicate
  matching observations by policy key/setting/path, preserving each policy's
  evidence. Apply the spec's aggregate precedence, retaining mismatch/conflict
  details even when the aggregate is not assessed. An absent value in one policy
  does not cancel a configured value in another; missing means absence across
  all complete relevant sources. Calculate summaries:

```powershell
$assessed = $counts.aligned + $counts.misaligned + $counts.missing +
    $counts.potentialConflict
$denominator = $controls.Count - $counts.notApplicable
$coverage = if ($denominator -gt 0) {
    [Math]::Round(100.0 * $assessed / $denominator, 1)
} else { $null }
$alignment = if ($assessed -gt 0) {
    [Math]::Round(100.0 * $counts.aligned / $assessed, 1)
} else { $null }
```

- [ ] **Step 4: Run green.** Run all four focused Pester files together.
- [ ] **Step 5: Commit** `feat: evaluate baseline alignment with explicit coverage`.

## Task 5: Source-verified Microsoft packs for the four platforms

**Files:** Create `baselines\microsoft-windows-11.json`,
`baselines\microsoft-macos.json`, `baselines\microsoft-ios-ipados.json`,
`baselines\microsoft-android-enterprise.json`, and
`tests\AssessmentBaselines.Tests.ps1`. Extend
`docs\assessment-rule-packs.md` with the reviewed catalog and source evidence;
extend `lib\BaselinePacks.ps1` only for verified property catalog entries.

**Interfaces:** Each file satisfies Read-IdsBaselinePack; expected values and
setting identities are production data, not derived from synthetic factories.
Use explicit version/profile metadata and `coverage.inventory = 'partial'`
unless a complete source inventory has actually been reviewed.

- [ ] **Step 1: Write catalog acceptance tests before adding packs.**

```powershell
It 'ships nonempty verified Microsoft coverage for every selected platform' {
    $catalog = Get-IdsBaselinePacks -BundledRoot (Join-Path $repo 'baselines') `
        -ImportedRoot (Join-Path $TestDrive 'imports')
    $catalog.errors.Count | Should -Be 0
    foreach ($platform in 'windows11', 'macos', 'iosIpados', 'androidEnterprise') {
        $packs = @($catalog.packs | Where-Object platform -EQ $platform)
        $packs.Count | Should -BeGreaterThan 0
        foreach ($pack in $packs) {
            $pack.framework | Should -Be 'Microsoft'
            @($pack.controls | Where-Object { -not $_.manualReason }).Count |
                Should -BeGreaterThan 0
            foreach ($source in $pack.sources) {
                ([uri]$source.url).Host | Should -Be 'learn.microsoft.com'
                $source.revision | Should -Not -BeNullOrEmpty
            }
        }
    }
}
```

  Add mapping-specific synthetic pass/fail examples for each production control;
  schema validity alone does not establish mapping correctness.
- [ ] **Step 2: Run red.**
  `pwsh -NoProfile -Command "Invoke-Pester .\tests\AssessmentBaselines.Tests.ps1 -Output Detailed"`
- [ ] **Step 3: Curate actual rules from authoritative recommendations.** Start
  with the verified Windows baseline index:
  <https://learn.microsoft.com/en-us/intune/device-security/security-baselines/overview>.
  Follow its selected non-preview product/version settings reference. Record
  the exact release, expected values, source revisions, applicability, and
  Graph setting-definition or policy-property documentation for each mapping.
  For macOS, the verified settings reference
  <https://learn.microsoft.com/en-us/intune/device-security/compliance/ref-macos-settings>
  establishes setting behavior, not an endorsement of every configurable
  value; only explicit recommendations support a Microsoft recommendation rule.
  Discover and verify current official iOS/iPadOS and Android Enterprise
  recommendation sources before authoring their packs. Older
  enrollment/security-framework URLs returned 404 during planning and must not
  be copied as evidence. Microsoft Learn's public search API is available for
  source discovery; search results alone are not verified recommendations.

  For every rule, record this review row in the catalog documentation:

```text
Pack/version | Control ID | Source URL/revision/section | Recommended value |
Graph policy type + setting ID/property | Encoding/type | Applicability |
Synthetic positive case | Synthetic negative case
```

  Use only small, reviewed, factual mappings with original concise titles.
  Do not copy entire copyrighted benchmarks or fabricate control IDs from a
  named standard. Recommendation packs may use app-owned rule IDs that are
  clearly distinguished from official framework numbering. Missing authority
  or uncertain encoding is a source-verification blocker: leave the feature
  unreleased and ask the owner for the authoritative material, rather than
  shipping empty/fictional platform coverage.
- [ ] **Step 4: Run green.** Run pack, normalization, engine, and baseline tests
  in one Pester invocation. Independently inspect each source/mapping review
  row; unit tests cannot prove the authority or correctness of source content.
- [ ] **Step 5: Commit** `feat: add verified Microsoft assessment rule packs`.

## Task 6: Separate, evidence-preserving Markdown and JSON reports

**Files:** Create `lib\AssessmentReports.ps1` and
`tests\AssessmentReports.Tests.ps1`.

**Interfaces:**

- `ConvertTo-IdsAssessmentMarkdown -Result [pscustomobject] -> [string]`.
- `Write-IdsAssessmentReports -Result [pscustomobject] -OutputPath [string] -InstallRoot [string] -ExportRoot [string] -> [pscustomobject]`
  returns `{ root, markdownPath, jsonPath }` only after successful publication.
  Use the Result contract, never source objects containing credentials.

- [ ] **Step 1: Add failing report and filesystem tests.**

```powershell
It 'rejects a report destination inside the documentation tree' {
    $install = Join-Path $TestDrive 'app'
    $export = Join-Path $TestDrive 'docs'
    $result = [pscustomobject]@{ schemaVersion = 1; runId = 'synthetic-run' }
    {
        Write-IdsAssessmentReports -Result $result `
            -OutputPath (Join-Path $export 'assessments') `
            -InstallRoot $install -ExportRoot $export
    } | Should -Throw
}
```

  Verify both ancestor and descendant overlap, path-component boundaries
  (`docs` versus `docs-other`), junction/reparse-point aliases, stable evidence
  sorting, null percentages, every status label, provenance hashes, partial-pack
  labeling, HTML/Markdown metacharacters, and secrets excluded by construction.
  Simulate failure after the first staged file; no published pair may appear.
  Two runs must produce separate directories and leave exports untouched.
- [ ] **Step 2: Run red.**
  `pwsh -NoProfile -Command "Invoke-Pester .\tests\AssessmentReports.Tests.ps1 -Output Detailed"`
- [ ] **Step 3: Implement serialization and staged publication.** Validate
  canonical absolute roots, reject overlapping installation/export/report roots
  and reparse-point ambiguity, create a unique stage directory under the allowed
  report root, write UTF-8 Markdown and JSON, then rename that directory to its
  unique final name. Cleanup may remove only the known stage directory created
  by this invocation. Propagate filesystem errors with a clear job failure.
  Serialize the explicit result projection deeply enough to preserve evidence:

```powershell
$json = ConvertTo-Json -InputObject $Result -Depth 64
$encoding = [Text.UTF8Encoding]::new($false)
[IO.File]::WriteAllText((Join-Path $stage 'assessment.json'), $json, $encoding)
[IO.File]::WriteAllText((Join-Path $stage 'assessment.md'),
    (ConvertTo-IdsAssessmentMarkdown -Result $Result), $encoding)
```

  Reuse safe table/escaping helpers where their semantics fit; never write
  imported HTML raw. Include expected/observed values, policy/assignment
  provenance, references, collection limitations, and the distinction between
  configuration alignment and device compliance.
- [ ] **Step 4: Run green.** Repeat Task 6 tests plus engine tests.
- [ ] **Step 5: Commit** `feat: write standalone policy assessment reports`.

## Task 7: Local API, bounded imports, and session-safe background jobs

**Files:** Create `lib\Assessment.ps1`, `lib\AssessmentApi.ps1`,
`tests\AssessmentJobs.Tests.ps1`, `tests\AssessmentApi.Tests.ps1`.
Modify `IntuneDocsStudio.ps1`, `lib\Http.ps1`, and
`tests\Runtime.Tests.ps1`.

**Interfaces:**

- `Start-IdsAssessmentJob -State [hashtable] -Options [hashtable] -Root [string] -> [bool]`
  validates, snapshots packs/context, captures session epoch, and starts a job.
- `Clear-IdsAssessmentJob -State [hashtable]` disposes a completed job.
- `Reset-IdsAssessment -State [hashtable]` clears result/progress and increments
  the session epoch. It refuses to reset an active assessment.
- `Invoke-IdsAssessmentRoute -Method [string] -Path [string] -Request [object] -State [hashtable] -Root [string] -> [pscustomobject]`
  returns `{ handled, status, body }`; main dispatch sends the response.
- `Read-IdsAssessmentRequestJson -Request [object] -MaxBytes [int] -> [pscustomobject]`
  strictly parses bounded bodies, including streams with unknown content length.
- `Send-IdsJson` gains optional `-Depth [int] = 12`; assessment routes use 64.
  Existing callers retain the default.

API contracts:

```text
GET  /api/assessment/packs
  200 { packs: [metadata only], errors: [] }
POST /api/assessment/packs
  body { content: "original UTF-8 JSON text" }; 201 { pack: metadata }
POST /api/assessment
  body { packIds: ["id@version#sha256"], context: Context, outputPath: absolute }
  202 { started: true, runId }; 401 not signed in; 409 active job
GET  /api/assessment
  200 { running, done, percent, phase, error, partial, reportPaths, summaries }
GET  /api/assessment/results
  200 Result only for current authenticated epoch; 404 no completed result
```

Packs/catalog metadata is local configuration, not tenant data. Progress/results
require authentication and matching epoch. Imports require a same-origin JSON
POST, and new mutating assessment routes reject a mismatching Origin/Host rather
than trusting loopback alone. Do not change OAuth callback behavior.

- [ ] **Step 1: Add failing lifecycle/API tests.**

```powershell
It 'rejects assessment starts while an export is active' {
    $state = [hashtable]::Synchronized(@{
        Auth = @{ transport = 'token' }
        Export = @{ running = $true }
        Assessment = @{ running = $false; epoch = 1 }
    })
    Start-IdsAssessmentJob -State $state -Options @{} -Root $repo |
        Should -BeFalse
}
```

  Add route tests for 401/409/404, malformed JSON, unknown pack IDs, wrong hashes,
  too-large streamed requests, Unicode byte counts, foreign Origin/Host,
  duplicate starts, immutable pack snapshots, and no secret fields in responses.
  Test all interactive/device-code/Azure CLI/Graph/portal sign-in paths plus
  pending OAuth/device-code completion while a job is active. Reject identity
  replacement during jobs; invalidate stale pending sign-ins on session reset.
  Verify sign-out, forget-profile, quit, Ctrl+C cleanup, cross-tenant reset,
  failed writes, and successful partial assessments.
- [ ] **Step 2: Run red.**
  `pwsh -NoProfile -Command "Invoke-Pester .\tests\AssessmentJobs.Tests.ps1,.\tests\AssessmentApi.Tests.ps1 -Output Detailed"`
- [ ] **Step 3: Implement lifecycle and dispatch.** Keep
  `State.Assessment` synchronized with `running`, `done`, `error`, `percent`,
  `phase`, `epoch`, `runId`, `result`, `reportPaths`, `partial`, and `job`.
  Serialize admission in the main HTTP loop and enforce guards in both
  export-start and assessment-start functions. Run collection, normalization,
  evaluation, and report writing in order, loading their modules inside the
  runspace as the existing export job does. Do not return/store authentication
  objects or collection policy objects in Result. Project only the shared Result
  fields, policy metadata/assignments, observed nonsecret values, and pack
  identity/source/coverage metadata. Recheck epoch before publishing state.

  The runspace error boundary records an explicit error and always completes/
  disposes its job state; source failures remain control-level not-assessed
  evidence. `partial = $true` distinguishes completed-with-limitations from a
  clean full assessment. A top-level collection/authentication failure must not
  be reported as a successful assessment with zero controls.

  Bound ordinary start requests to 64 KiB. Bound import request envelopes to
  64 MiB (JSON escaping can expand a 10 MiB pack), then enforce the decoded
  10 MiB pack-byte limit before parsing it. Never use the current lenient
  `Read-IdsRequestJson` for new assessment routes.

  Add assessment module loading near the existing `lib` imports, route dispatch
  before the existing unmatched-route fallback, assessment cleanup beside
  `Clear-IdsFinishedJob`, and job disposal in `finally`. Extend session reset and
  all identity-changing/job-stop guards without altering authentication protocol
  handling. Add the bundled pack resource directory to local server test
  fixtures now that server startup needs it.
- [ ] **Step 4: Run green.** Run jobs/API/runtime tests plus the pack/engine/report
  tests in one Pester invocation. Existing runtime identity/launcher assertions
  must remain unchanged in meaning.
- [ ] **Step 5: Commit** `feat: expose session-safe policy assessment jobs`.

## Task 8: Dashboard assessment workflow without export regressions

**Files:** Modify `web\index.html`, `web\app.js`, `web\style.css`;
create `tests\assessment-ui.test.js`; adjust only shared test-double capabilities
in `tests\publishing-ui.test.js` if new DOM methods are required.

**Interfaces:** Consume Task 7 routes exactly. Add
`renderAssessmentPacks(catalog)`, `renderAssessmentResult(result)`,
`clearAssessment()`, and `refreshAssessment()` in the existing dashboard script.
Reuse its API/error/escaping helpers and existing visual style; no separate app,
new framework, or dependency.

- [ ] **Step 1: Add failing Node tests using the existing VM/DOM-double pattern.**

```javascript
test('assessment rendering treats imported control names as text', () => {
  const { element, context } = assessmentDashboard();
  vm.runInContext(`renderAssessmentResult({
    summaries: [],
    controls: [{
      controlId: 'SYN-1', title: '<script>bad()</script>',
      status: 'notAssessed', reason: 'Unsupported mapping',
      expected: true, observed: [], policyResults: [], references: []
    }]
  })`, context);
  assert.doesNotMatch(element('assessmentResults').innerHTML, /<script>/);
  assert.match(element('assessmentResults').innerHTML, /&lt;script&gt;/);
});
```

  Define `assessmentDashboard(respond)` in this test file by adapting the current
  `publishing-ui.test.js` harness: expose `element`, `context`, `requests`,
  `fetch` status handling, file `.text()`, dynamic checkbox selection, and only
  the DOM methods the dashboard actually uses.
  Test pack/platform/profile selection, disabled unsupported combinations,
  original import text submission, request errors preserving prior selection,
  bounded file checks, 202 progress polling, all statuses, status filtering,
  potential-conflict labels, unassigned policy flags, and 401/409 failures.
  Verify `clearWorkspace()` clears assessment evidence and report paths; stale
  poll responses cannot repopulate them after sign-out/tenant switch.
- [ ] **Step 2: Run red.**
  `node --test .\tests\assessment-ui.test.js .\tests\publishing-ui.test.js`
- [ ] **Step 3: Add the assessment area.** Use accessible labeled selectors,
  import file input, separate report-folder input, run button, progress/errors,
  summaries, status filter, and evidence table. Distinguish recommendation
  packs, official baselines, imported CIS, partial inventories, and unknown
  applicability visibly before running. Allow explicit OS-version/enrollment
  context when required by selected packs, and label it user-selected context.

  Send the selected snapshot identities, not arbitrary filenames:

```javascript
const payload = {
  packIds: selectedPacks.map((p) => `${p.id}@${p.version}#${p.sha256}`),
  context: assessmentContext,
  outputPath: document.getElementById('assessmentOutputPath').value.trim()
};
```

  Use request-generation counters to ignore stale async results after reset.
  Disable export and assessment admission appropriately while either job runs,
  with the server remaining authoritative. Keep export options/output-path/
  Git controls independent. Display report locations from server results only.
- [ ] **Step 4: Run green.** Repeat both Node paths in one runner. Exercise a
  mocked/synthetic four-platform dashboard assessment locally; do not sign in
  to a customer tenant or render customer data for screenshots.
- [ ] **Step 5: Commit** `feat: add policy assessment dashboard`.

## Task 9: Customer packaging, operator documentation, and acceptance

**Files:** Modify `Build-Package.ps1`, `tests\Package.Tests.ps1`,
`README.md`, `QUICKSTART.md`, `docs\operations.md`,
`docs\assessment-rule-packs.md`. Update only the existing applicable workflow
files if they explicitly enumerate test paths and omit the new suites.

**Interfaces:** Customer ZIP includes runtime assessment modules and exactly the
four vetted bundled Microsoft pack files. Imported packs, reports, tests,
fixtures, plans/specs, and browser profiles are not product resources.

- [ ] **Step 1: Add failing package/integration assertions.** Extend the current
  package fixture and content checks, including:

```powershell
$expectedPacks = @(
    'baselines/microsoft-windows-11.json',
    'baselines/microsoft-macos.json',
    'baselines/microsoft-ios-ipados.json',
    'baselines/microsoft-android-enterprise.json'
)
foreach ($entry in $expectedPacks) {
    $zip.Entries.FullName | Should -Contain "IntuneDocsStudio/$entry"
}
```

  Use the existing test's actual ZIP variable/entry-prefix conventions.
  Add sentinel customer-pack/report files outside the allowlist and assert they
  are absent. Build twice from identical inputs and compare ZIP hashes. Exercise
  a synthetic four-platform result through reports and compare Markdown evidence
  to parsed JSON; ensure no exporter manifest or documentation page is changed.
- [ ] **Step 2: Run red.**
  `pwsh -NoProfile -Command "Invoke-Pester .\tests\Package.Tests.ps1 -Output Detailed"`
- [ ] **Step 3: Extend the explicit package allowlist.** Add only:

```powershell
'baselines\microsoft-windows-11.json'
'baselines\microsoft-macos.json'
'baselines\microsoft-ios-ipados.json'
'baselines\microsoft-android-enterprise.json'
```

  Include `docs\assessment-rule-packs.md` as the customer import reference.
  Continue using the existing `lib\*.ps1` runtime inclusion. Do not recursively
  include customer rule folders or all of `docs`.

  Document: connect/select/import/run/read reports; baseline versus
  recommendations; configuration versus device compliance; partial coverage;
  CIS pack format/rights; precise limits; supported operators/platform context;
  source revision/hash provenance; failure meanings; unassigned/potential
  conflict caveats; and report folders separate from export output.
  Use `%LOCALAPPDATA%\IntuneDocsStudio\AssessmentPacks` as the default customer
  pack location. Imported pack files survive application updates, while active
  tenant results clear on session reset. Reports go only to the user's chosen
  report root. Back up these files only as customer-owned data, never tokens or
  portal profiles. No automatic uploads or Git pushes occur.
- [ ] **Step 4: Run acceptance in PowerShell 7.**

```powershell
Invoke-Pester .\tests\*.Tests.ps1 -Output Detailed
node --test .\tests\publishing-ui.test.js .\tests\assessment-ui.test.js
pwsh -NoProfile -File .\scripts\Test-Repository.ps1
pwsh -NoProfile -File .\Build-Package.ps1 -OutputPath $packageOutput
```

  Create `$packageOutput` as a specific temporary directory owned by this
  validation run. Inspect ZIP contents before deleting only that known directory.
  Record actual command results, source-review evidence, and any limitations.
  No real tenant is required. Do not report the feature complete if a selected
  platform lacks verified nonempty Microsoft coverage, if imports cannot drive
  CIS comparison, or if incomplete evidence can become a pass/missing result.
- [ ] **Step 5: Commit** `docs: package and document policy baseline assessments`.

## Self-review and completion criteria

This plan maps the spec to: pack contract/import limits (Task 1), strict
collection (Task 2), typed platform/family normalization (Task 3), result/
coverage semantics (Task 4), authoritative four-platform Microsoft content and
customer CIS support (Tasks 1 and 5), safe separate reports (Task 6), jobs/session
isolation/local routes (Task 7), dashboard workflow (Task 8), and packaging/
operator/regression evidence (Task 9).

Production source curation is required work, not completed by this plan.
Source availability problems are explicit blockers; tests with invented
recommendations are not an acceptable substitute. Final handoff must distinguish
implemented automation from manual/unsupported controls and must not claim device
compliance or broad standards conformance.
