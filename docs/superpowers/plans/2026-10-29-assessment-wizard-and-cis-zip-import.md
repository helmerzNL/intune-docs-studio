# Assessment Wizard and CIS ZIP Import Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Guide operators through an assessment with a five-step wizard, and let them import the CIS Intune build-kit ZIP they downloaded. The ZIP is converted in memory into local schema-1 rule packs.

**Architecture:**
- **Wizard.** The wizard is client state in `web\app.js`. Five panels inside the existing Assess view toggle with `.hidden`. A `.stepper.wide` stepper reuses the documentation stepper styles. There is no route or server change.
- **ZIP import.** The browser base64-posts the ZIP to the existing `POST /api/assessment/packs` endpoint.
  - A new `lib\BaselineArchive.ps1` reads the archive in memory with `System.IO.Compression`.
  - It converts Settings Catalog policies into schema-1 packs through the existing `ConvertTo-IdsCatalogObservations` normalizer.
  - Every pack is re-validated with `Read-IdsBaselinePack`.
  - `Import-IdsBaselinePackSet` stores the whole set under one lock.

**Tech Stack:** PowerShell 7 (`System.IO.Compression`, `System.Text.Json`), Pester 5, vanilla JavaScript and CSS, and Node `node:test` with a fake DOM.

**Spec:** `docs/superpowers/specs/2026-10-29-assessment-wizard-and-cis-zip-import-design.md`. Read the spec together with this plan; the plan argues from it.

## Global Constraints

**Runtime and dependencies**
- The runtime is PowerShell 7 or later (`pwsh`). Windows PowerShell 5.1 is not supported. The minimum PowerShell version does not change.
- No new dependency; `System.IO.Compression` and `System.Text.Json` ship with .NET. No `VERSION` change.

**Unchanged behavior**
- No change to control evaluation, applicability rules, the job model or the report formats.
- Export, sign-in and Git publishing stay unchanged.
- No change to the documentation workflow or its stepper.
- All existing element IDs are kept.

**Content scope**
- No parsing of PDF, Excel, XCCDF/OVAL, Group Policy (GPO/ADMX), OMA-URI or legacy device-configuration content.
- The app never downloads CIS content and bundles none; the customer supplies their own licensed download.
- No extraction to disk. The archive exists only in memory. Only the generated rule packs are stored, exactly like a JSON import today.
- No pack deletion, editing or automatic selection.

**Limits**
- Archive: at most 32 MiB.
- Entries: at most 1,000, of which at most 500 are JSON.
- JSON: at most 10 MiB per entry and 64 MiB in total.
- Base64 request text: at most 44,739,244 characters.
- The package grows from 31 to 32 files (`lib\BaselineArchive.ps1`).

**Rendering and data safety**
- Entry names and reasons are rendered with `textContent` only.
- Tests use synthetic, in-memory ZIPs.
- Never commit CIS content, tenant data, credentials, user paths, e-mail addresses or GUID literals. The package leak scan rejects them in shipped files.

**Language and process**
- App UI text and repository docs are in English.
- Every commit message ends with the trailer `Co-authored-by: Copilot App <223556219+Copilot@users.noreply.github.com>`.
- Work on the current feature branch. The pull request targets `beta`. No merge, promotion or release.

## File Structure

| File | Responsibility | Tasks |
|---|---|---|
| `lib\BaselinePacks.ps1` | Pack validation and storage. Gains `Import-IdsBaselinePackSet`: one lock, one catalog read, and every conflict checked before anything is written. | 1 |
| `lib\BaselineArchive.ps1` (new) | Build-kit conversion (`ConvertTo-IdsBuildKitPacks`) and in-memory ZIP reading (`ConvertFrom-IdsBaselineArchive`). | 2, 3 |
| `IntuneDocsStudio.ps1` | Loads `BaselineArchive`. | 2 |
| `tests\AssessmentIntegration.Tests.ps1` | Mirrors the app library load order, including `BaselineArchive`. | 2 |
| `lib\AssessmentApi.ps1` | `POST /api/assessment/packs` accepts exactly one of `content` or `archive`. | 4 |
| `web\index.html`, `web\app.js`, `web\style.css` | Wizard, import card and ZIP upload. | 5, 6 |
| `tests\AssessmentPacks.Tests.ps1` | Batch import tests. | 1 |
| `tests\BaselineArchive.Tests.ps1` (new) | Converter and archive reader tests with in-memory ZIPs. | 2, 3 |
| `tests\TestHelpers\Assessment.ps1` | Shared synthetic builders (build-kit policy, ZIP). | 2, 3 |
| `tests\AssessmentApi.Tests.ps1` | Endpoint tests. | 4 |
| `tests\Package.Tests.ps1` | 32-file product list. | 2 |
| `tests\assessment-ui.test.js`, `tests\app-shell-ui.test.js` | Wizard and import UI tests; ID and CSS checks. | 5, 6 |
| `docs\assessment-rule-packs.md`, `README.md`, `QUICKSTART.md`, `docs\operations.md` | Operator and API documentation. | 7 |

**Task order:**
- Tasks 1 → 2 → 3 → 4 build the backend.
- Tasks 5 → 6 build the UI. They do not depend on Tasks 1–4, because the UI tests fake the API.
- Task 7 documents the shipped behavior.
- Task 8 verifies everything.

---


### Task 1: Batch rule-pack import

Add `Import-IdsBaselinePackSet` to `lib\BaselinePacks.ps1`. It stores a whole
set of rule packs under one import lock. It validates every pack first, reads
the imported catalog once and checks every pack for conflicts before it writes
any file. `Import-IdsBaselinePack` becomes a one-pack call of the set function
and keeps its parameters, return value and error messages. This is the "Batch
import" section of Part B of the design spec
(`docs\superpowers\specs\2026-10-29-assessment-wizard-and-cis-zip-import-design.md`).
Tasks 3 and 4 use the set function for ZIP imports.

Notes for this task:

- Line numbers refer to the files before this task. Find each edit by its exact
  current text; every "replace this text" snippet occurs exactly once in its
  file.
- Both files use CRLF line endings. Keep CRLF. The repository has no
  `.gitattributes`; with `core.autocrlf=true`, Git normalizes on commit.
- `tests\AssessmentPacks.Tests.ps1` does not load `lib\BaselinePacks.ps1` from
  the repository.
  - Its top-level `BeforeAll` copies the file into
    `$scratch\synthetic-installation\lib` and dot-sources the copy, so the
    installation-overlap check sees a synthetic installation. `$scratch` is a
    repo-local `.assessment-pack-tests-<32 hex>` folder.
  - The same `BeforeAll` defines `New-TestPack` (the synthetic pack as an
    object) and `ConvertTo-TestBytes($Pack)`.
  - The new tests reuse this setup. Each test imports into a new folder under
    `$scratch`.
- `New-IdsTestPackBytes` in `tests\TestHelpers\Assessment.ps1` returns the
  UTF-8 bytes of the synthetic pack `synthetic-pack`, version `1.0.0`.
- The set function works in this order:
  1. `Read-IdsBaselinePack` validates every pack before the storage root is
     touched. A byte-identical duplicate (same `id@version` and SHA-256) is
     dropped. Two different packs with the same `id@version` throw "Pack set
     contains different packs with the same ID/version: `<id>@<version>`."
  2. The root checks are copied unchanged from `Import-IdsBaselinePack`, with
     identical messages.
  3. `.import.lock` is opened once, with `FileShare.None` and `DeleteOnClose`.
  4. The imported catalog is read once. Catalog errors throw the existing
     message. Every pack is compared with the catalog (`-ceq` on id and
     version) before the first write:
     - a different SHA-256 throws 'Imported pack ID/version already exists with
       different bytes.' and nothing is written;
     - the same SHA-256 reports the pack with `added = $false`.
  5. Each new pack is written to `.stage-<32 hex>` and moved to
     `<sha256>.json`. The stage file is deleted in an inner `finally` and the
     lock is released in an outer `finally`.
- The result is one `[pscustomobject]@{ pack; added }` per unique pack, in input
  order. PowerShell unrolls a one-item result, so callers wrap the call in
  `@()`.
- The existing tests in `tests\AssessmentPacks.Tests.ps1` do not change and
  keep passing. They match the messages "\*expected\*", "\*different bytes\*",
  "\*.id\*", "\*catalog\*", "\*absolute\*", "\*installation\*" and
  "\*reparse\*".
- A storage failure after earlier packs of the set were moved into place leaves
  those packs imported. Every stored pack is complete and valid, and repeating
  the import adds the rest (spec decision 14). Task 7 documents this.

**Files:**

- Modify: `lib\BaselinePacks.ps1` (about lines 436–481, `Import-IdsBaselinePack`,
  the last function in the file)
- Test: `tests\AssessmentPacks.Tests.ps1` (a new `Describe` after line 461)

**Interfaces:**

- Consumes (existing code; no earlier task):
  - `Read-IdsBaselinePack -Bytes <byte[]>` → the validated pack as a
    `[pscustomobject]` with a `sha256` NoteProperty (64 lowercase hex). It
    throws a plain string message for an invalid pack.
  - `Assert-IdsPackNoReparsePath([string]$Path)`.
  - `Get-IdsBaselinePacks -BundledRoot <string> -ImportedRoot <string>` →
    `[pscustomobject]@{ packs; errors }`.
  - Test helpers: `New-IdsTestPackBytes([string]$Platform = 'windows11')`, and
    `New-TestPack`, `ConvertTo-TestBytes($Pack)` and `$scratch` from the
    top-level `BeforeAll` of `tests\AssessmentPacks.Tests.ps1`.
- Produces:
  - `Import-IdsBaselinePackSet -Packs <byte[][]> -ImportedRoot <string>` (both
    mandatory) → one `[pscustomobject]@{ pack = <the Read-IdsBaselinePack
    result, including sha256>; added = <bool> }` per unique pack, in input
    order. `added` is `$false` when the imported catalog already holds the same
    bytes.
  - Errors are plain strings: "Pack set contains different packs with the same
    ID/version: `<id>@<version>`.", plus every existing message of
    `Import-IdsBaselinePack`.
  - `Import-IdsBaselinePack -Bytes <byte[]> -ImportedRoot <string>`, unchanged:
    it returns the validated pack, without an `added` member.

- [ ] **Step 1: Append the batch import tests**

Append this code at the end of `tests\AssessmentPacks.Tests.ps1`, after the
closing `}` of `Describe 'Assessment pack local catalog and imports'` (about
line 461). Leave one blank line before it.

```powershell
Describe 'Assessment pack batch imports' {
    BeforeEach {
        $imported = Join-Path $scratch ([guid]::NewGuid().ToString('N'))
        $one = New-IdsTestPackBytes
        $second = New-TestPack; $second.id = 'synthetic-pack-two'
        $two = ConvertTo-TestBytes $second
    }
    It 'imports each unique pack once and reports added in input order' {
        $first = @(Import-IdsBaselinePackSet -Packs @($two, $one) -ImportedRoot $imported)
        $first.Count | Should -Be 2
        $first[0].pack.id | Should -BeExactly 'synthetic-pack-two'
        $first[1].pack.id | Should -BeExactly 'synthetic-pack'
        $first[0].added | Should -BeTrue
        $first[1].added | Should -BeTrue
        @(Get-ChildItem -LiteralPath $imported -Force).Count | Should -Be 2
        foreach ($case in @(@{ result = $first[0]; bytes = $two }, @{ result = $first[1]; bytes = $one })) {
            $path = Join-Path $imported "$($case.result.pack.sha256).json"
            [Convert]::ToBase64String([IO.File]::ReadAllBytes($path)) | Should -BeExactly ([Convert]::ToBase64String($case.bytes))
        }
        $again = @(Import-IdsBaselinePackSet -Packs @($two, $one) -ImportedRoot $imported)
        $again.Count | Should -Be 2
        $again[0].added | Should -BeFalse
        $again[1].added | Should -BeFalse
        $again[0].pack.sha256 | Should -BeExactly $first[0].pack.sha256
        $again[1].pack.sha256 | Should -BeExactly $first[1].pack.sha256
        @(Get-ChildItem -LiteralPath $imported -Force).Count | Should -Be 2
    }
    It 'drops byte-identical duplicates within a batch' {
        $results = @(Import-IdsBaselinePackSet -Packs @($one, $two, $one, $two) -ImportedRoot $imported)
        $results.Count | Should -Be 2
        @($results | Where-Object added).Count | Should -Be 2
        @(Get-ChildItem -LiteralPath $imported -Force).Count | Should -Be 2
    }
    It 'validates the whole batch before creating the storage root' {
        $changed = New-TestPack; $changed.controls[0].mappings[0].expected = $false
        { Import-IdsBaselinePackSet -Packs @($one, (ConvertTo-TestBytes $changed)) -ImportedRoot $imported } |
            Should -Throw '*synthetic-pack@1.0.0*'
        { Import-IdsBaselinePackSet -Packs @($one, [Text.Encoding]::UTF8.GetBytes('{}')) -ImportedRoot $imported } |
            Should -Throw '*required*'
        (Test-Path -LiteralPath $imported) | Should -BeFalse
    }
    It 'rejects a conflict with an existing import before writing any pack of the batch' {
        $existing = Import-IdsBaselinePack -Bytes $one -ImportedRoot $imported
        $changed = New-TestPack; $changed.controls[0].mappings[0].expected = $false
        { Import-IdsBaselinePackSet -Packs @($two, (ConvertTo-TestBytes $changed)) -ImportedRoot $imported } |
            Should -Throw 'Imported pack ID/version already exists with different bytes.'
        $files = @(Get-ChildItem -LiteralPath $imported -Force)
        $files.Count | Should -Be 1
        $files[0].Name | Should -BeExactly "$($existing.sha256).json"
    }
    It 'keeps a single import as one validated pack' {
        $pack = Import-IdsBaselinePack -Bytes $one -ImportedRoot $imported
        ($pack -is [array]) | Should -BeFalse
        $pack.PSObject.Properties.Name | Should -Not -Contain 'added'
        $pack.id | Should -BeExactly 'synthetic-pack'
        $pack.controls.Count | Should -Be 1
        $pack.sha256 | Should -BeExactly (Read-IdsBaselinePack -Bytes $one).sha256
        (Import-IdsBaselinePack -Bytes $one -ImportedRoot $imported).sha256 | Should -BeExactly $pack.sha256
        @(Get-ChildItem -LiteralPath $imported -Force).Count | Should -Be 1
    }
    It 'honours another writer''s lock and releases its own lock after success and failure' {
        [void][IO.Directory]::CreateDirectory($imported)
        $lockPath = Join-Path $imported '.import.lock'
        $held = [IO.FileStream]::new($lockPath, [IO.FileMode]::OpenOrCreate,
            [IO.FileAccess]::Write, [IO.FileShare]::None, 4096, [IO.FileOptions]::DeleteOnClose)
        try {
            { Import-IdsBaselinePackSet -Packs @($one, $two) -ImportedRoot $imported } | Should -Throw
        } finally { $held.Dispose() }
        @(Get-ChildItem -LiteralPath $imported -Force).Count | Should -Be 0
        @(Import-IdsBaselinePackSet -Packs @($one, $two) -ImportedRoot $imported).Count | Should -Be 2
        (Test-Path -LiteralPath $lockPath) | Should -BeFalse
        $changed = New-TestPack; $changed.controls[0].mappings[0].expected = $false
        { Import-IdsBaselinePackSet -Packs @(, (ConvertTo-TestBytes $changed)) -ImportedRoot $imported } |
            Should -Throw '*different bytes*'
        (Test-Path -LiteralPath $lockPath) | Should -BeFalse
        $probe = [IO.FileStream]::new($lockPath, [IO.FileMode]::OpenOrCreate,
            [IO.FileAccess]::Write, [IO.FileShare]::None, 4096, [IO.FileOptions]::DeleteOnClose)
        $probe.Dispose()
        @(Get-ChildItem -LiteralPath $imported -Force).Count | Should -Be 2
    }
}
```

- [ ] **Step 2: Run the new tests and see them fail**

Run:

```powershell
Invoke-Pester .\tests\AssessmentPacks.Tests.ps1 -Output Detailed
```

Expected: `Tests Passed: 133, Failed: 5, Skipped: 0, Inconclusive: 0, NotRun: 0`.
The failing tests are:

- `imports each unique pack once and reports added in input order`, `drops
  byte-identical duplicates within a batch` and `honours another writer's lock
  and releases its own lock after success and failure`, with `The term
  'Import-IdsBaselinePackSet' is not recognized as a name of a cmdlet,
  function, script file, or executable program.`
- `validates the whole batch before creating the storage root`, with `Expected
  an exception with message like '*synthetic-pack@1.0.0*' to be thrown, but the
  message was 'The term 'Import-IdsBaselinePackSet' is not recognized ...`.
- `rejects a conflict with an existing import before writing any pack of the
  batch`, with `Expected an exception with message like 'Imported pack
  ID/version already exists with different bytes.' to be thrown, but the
  message was 'The term 'Import-IdsBaselinePackSet' is not recognized ...`.

The other 133 tests pass: the 132 existing tests and `keeps a single import as
one validated pack`.

- [ ] **Step 3: Replace the single import with the set import and a wrapper**

In `lib\BaselinePacks.ps1`, replace the whole `Import-IdsBaselinePack` function
(about lines 436–481, the end of the file). The text to replace is:

```powershell
function Import-IdsBaselinePack {
    param(
        [Parameter(Mandatory)][AllowEmptyCollection()][byte[]]$Bytes,
        [Parameter(Mandatory)][string]$ImportedRoot
    )
    $pack = Read-IdsBaselinePack -Bytes $Bytes
    if (-not [IO.Path]::IsPathFullyQualified($ImportedRoot)) { throw 'ImportedRoot must be an absolute filesystem path outside the installation and source tree.' }
    $root = [IO.Path]::GetFullPath($ImportedRoot)
    Assert-IdsPackNoReparsePath $root
    $installation = [IO.Path]::GetFullPath((Split-Path -Parent $PSScriptRoot))
    $separator = [IO.Path]::DirectorySeparatorChar
    $rootPrefix = $root.TrimEnd($separator) + $separator
    $installationPrefix = $installation.TrimEnd($separator) + $separator
    if ($rootPrefix.StartsWith($installationPrefix, [StringComparison]::OrdinalIgnoreCase) -or
        $installationPrefix.StartsWith($rootPrefix, [StringComparison]::OrdinalIgnoreCase)) {
        throw 'ImportedRoot must not overlap the application installation/source tree.'
    }
    [void][IO.Directory]::CreateDirectory($root)
    # Serialize writers in this directory; staged files are never catalog entries.
    $lockPath = Join-Path $root '.import.lock'
    $lock = $null
    $staged = $null
    try {
        $lock = [IO.FileStream]::new($lockPath, [IO.FileMode]::OpenOrCreate,
            [IO.FileAccess]::Write, [IO.FileShare]::None, 4096, [IO.FileOptions]::DeleteOnClose)
        $catalog = Get-IdsBaselinePacks -BundledRoot (Join-Path $root '.unused-bundled') -ImportedRoot $root
        if ($catalog.errors.Count -gt 0) { throw 'Imported catalog has invalid or conflicting entries; repair them before importing.' }
        foreach ($existing in $catalog.packs) {
            if ($existing.id -ceq $pack.id -and $existing.version -ceq $pack.version) {
                if ($existing.sha256 -cne $pack.sha256) { throw 'Imported pack ID/version already exists with different bytes.' }
                return $pack
            }
        }
        $target = Join-Path $root "$($pack.sha256).json"
        $staged = Join-Path $root ('.stage-' + [guid]::NewGuid().ToString('N'))
        [IO.File]::WriteAllBytes($staged, $Bytes)
        [IO.File]::Move($staged, $target)
        return $pack
    } finally {
        try {
            if ($staged -and [IO.File]::Exists($staged)) { [IO.File]::Delete($staged) }
        } finally {
            if ($lock) { $lock.Dispose() }
        }
    }
}
```

Replace it with:

```powershell
function Import-IdsBaselinePackSet {
    param(
        [Parameter(Mandatory)][byte[][]]$Packs,
        [Parameter(Mandatory)][string]$ImportedRoot
    )
    $candidates = [Collections.Generic.List[object]]::new()
    $identities = [Collections.Generic.Dictionary[string,string]]::new([StringComparer]::Ordinal)
    foreach ($bytes in $Packs) {
        $pack = Read-IdsBaselinePack -Bytes $bytes
        $identity = "$($pack.id)@$($pack.version)"
        if ($identities.ContainsKey($identity)) {
            if ($identities[$identity] -cne $pack.sha256) { throw "Pack set contains different packs with the same ID/version: $identity." }
            continue
        }
        $identities[$identity] = $pack.sha256
        $candidates.Add([pscustomobject]@{ pack = $pack; bytes = $bytes; added = $true })
    }
    if (-not [IO.Path]::IsPathFullyQualified($ImportedRoot)) { throw 'ImportedRoot must be an absolute filesystem path outside the installation and source tree.' }
    $root = [IO.Path]::GetFullPath($ImportedRoot)
    Assert-IdsPackNoReparsePath $root
    $installation = [IO.Path]::GetFullPath((Split-Path -Parent $PSScriptRoot))
    $separator = [IO.Path]::DirectorySeparatorChar
    $rootPrefix = $root.TrimEnd($separator) + $separator
    $installationPrefix = $installation.TrimEnd($separator) + $separator
    if ($rootPrefix.StartsWith($installationPrefix, [StringComparison]::OrdinalIgnoreCase) -or
        $installationPrefix.StartsWith($rootPrefix, [StringComparison]::OrdinalIgnoreCase)) {
        throw 'ImportedRoot must not overlap the application installation/source tree.'
    }
    [void][IO.Directory]::CreateDirectory($root)
    # Serialize writers in this directory; staged files are never catalog entries.
    $lockPath = Join-Path $root '.import.lock'
    $lock = $null
    $staged = $null
    try {
        $lock = [IO.FileStream]::new($lockPath, [IO.FileMode]::OpenOrCreate,
            [IO.FileAccess]::Write, [IO.FileShare]::None, 4096, [IO.FileOptions]::DeleteOnClose)
        $catalog = Get-IdsBaselinePacks -BundledRoot (Join-Path $root '.unused-bundled') -ImportedRoot $root
        if ($catalog.errors.Count -gt 0) { throw 'Imported catalog has invalid or conflicting entries; repair them before importing.' }
        # Check every pack before the first write so a conflict leaves the catalog untouched.
        foreach ($candidate in $candidates) {
            foreach ($existing in $catalog.packs) {
                if ($existing.id -ceq $candidate.pack.id -and $existing.version -ceq $candidate.pack.version) {
                    if ($existing.sha256 -cne $candidate.pack.sha256) { throw 'Imported pack ID/version already exists with different bytes.' }
                    $candidate.added = $false
                }
            }
        }
        foreach ($candidate in $candidates) {
            if (-not $candidate.added) { continue }
            $target = Join-Path $root "$($candidate.pack.sha256).json"
            $staged = Join-Path $root ('.stage-' + [guid]::NewGuid().ToString('N'))
            [IO.File]::WriteAllBytes($staged, $candidate.bytes)
            [IO.File]::Move($staged, $target)
        }
        return @(foreach ($candidate in $candidates) { [pscustomobject]@{ pack = $candidate.pack; added = $candidate.added } })
    } finally {
        try {
            if ($staged -and [IO.File]::Exists($staged)) { [IO.File]::Delete($staged) }
        } finally {
            if ($lock) { $lock.Dispose() }
        }
    }
}

function Import-IdsBaselinePack {
    param(
        [Parameter(Mandatory)][AllowEmptyCollection()][byte[]]$Bytes,
        [Parameter(Mandatory)][string]$ImportedRoot
    )
    return @(Import-IdsBaselinePackSet -Packs @(, $Bytes) -ImportedRoot $ImportedRoot)[0].pack
}
```

- [ ] **Step 4: Run the new tests and see them pass**

Run:

```powershell
Invoke-Pester .\tests\AssessmentPacks.Tests.ps1 -Output Detailed
```

Expected: `Tests Passed: 138, Failed: 0, Skipped: 0, Inconclusive: 0, NotRun: 0`.

- [ ] **Step 5: Run the regression suite**

The API and integration suites import packs through `Import-IdsBaselinePack`.
Run:

```powershell
Invoke-Pester .\tests\AssessmentApi.Tests.ps1, .\tests\AssessmentIntegration.Tests.ps1 -Output Detailed
pwsh -NoProfile -File .\scripts\Test-Repository.ps1; $LASTEXITCODE
git --no-pager diff --stat
```

Expected:

- Pester shows `Tests Passed: 45, Failed: 0, Skipped: 0, Inconclusive: 0,
  NotRun: 0` (14 API tests and 31 integration tests).
- `Test-Repository.ps1` prints `Repository guidance and local policy checks
  passed.` and then `0`. It may first print `Pull request target policy: not
  applicable without pull request event context.`
- The diff stat lists exactly these 2 files: `lib/BaselinePacks.ps1` and
  `tests/AssessmentPacks.Tests.ps1`. It shows `2 files changed, 119
  insertions(+), 12 deletions(-)`.

Optionally, check that no LF-only line endings slipped into the edited files:

```powershell
'lib\BaselinePacks.ps1','tests\AssessmentPacks.Tests.ps1' |
  ForEach-Object { '{0}: {1}' -f $_, ([regex]::Matches((Get-Content -Raw $_), '(?<!\r)\n')).Count }
```

Expected: every count is `0`.

- [ ] **Step 6: Commit**

Run:

```powershell
git add lib\BaselinePacks.ps1 tests\AssessmentPacks.Tests.ps1
git commit -m "feat: import baseline pack sets under one lock" -m "Co-authored-by: Copilot App <223556219+Copilot@users.noreply.github.com>"
```

Expected: one commit with `2 files changed, 119 insertions(+), 12
deletions(-)`. If the opt-in pre-commit hook is installed, it passes.

### Task 2: Build-kit Settings Catalog converter

Create `lib\BaselineArchive.ps1` with `ConvertTo-IdsBuildKitPacks`. It turns
CIS build-kit Settings Catalog policies into schema-1 rule packs: one pack per
platform and CIS profile level. Values are normalized by the existing
`ConvertTo-IdsCatalogObservations`, and every generated pack is re-validated
with `Read-IdsBaselinePack`. The output is deterministic, so importing the same
archive again is idempotent. This task also wires the new module into the app
and the package test. This is the "Converting Settings Catalog policies"
section of Part B of the design spec
(`docs\superpowers\specs\2026-10-29-assessment-wizard-and-cis-zip-import-design.md`).
Task 3 adds the ZIP reader to the same file.

Notes for this task:

- Line numbers refer to the files before this task. Find each edit by its exact
  current text; every "replace this text" snippet occurs exactly once in its
  file.
- All six files use CRLF line endings, including the two new files. Keep CRLF.
  The repository has no `.gitattributes`; with `core.autocrlf=true`, Git
  normalizes on commit.
- Module wiring:
  - `IntuneDocsStudio.ps1` (line 57) and `tests\AssessmentIntegration.Tests.ps1`
    (line 3) load the same module list. `'BaselineArchive'` goes after
    `'AssessmentSettings'` in both, because it uses `BaselinePacks`,
    `AssessmentCollection` and `AssessmentSettings`.
  - `Build-Package.ps1` includes `lib\*.ps1` automatically, so only the
    `$script:ProductFiles` list in `tests\Package.Tests.ps1` changes. The
    package grows from 31 to 32 product files (spec decision 15).
  - The package leak scan rejects GUID literals, user paths, e-mail
    addresses, `*.onmicrosoft.com` names and bearer tokens in shipped files.
    `lib\BaselineArchive.ps1` contains none of them.
  - `tests\BaselineArchive.Tests.ps1` loads `tests\TestHelpers\Assessment.ps1`,
    `BaselinePacks`, `AssessmentCollection`, `AssessmentSettings` and
    `AssessmentRules`. It loads `lib\BaselineArchive.ps1` only if the file
    exists, so the failing run reports missing commands, not a load error.
- Input: each item is `[pscustomobject]@{ entry = <archive entry FullName>;
  policy = <a value from ConvertFrom-IdsPackJsonElement>; lastWriteTime =
  <[DateTimeOffset]> }`.
  - `ConvertFrom-IdsPackJsonElement` returns `[ordered]` dictionaries,
    `object[]`, `[long]`, `[decimal]`/`[double]`, strings, booleans and `$null`.
  - `New-IdsTestBuildKitPolicy` builds such a value through
    `ConvertTo-IdsTestJsonValue`.
- Conversion rules:
  - Name: `name`, else `displayName`, else the entry's file name without
    `.json`.
  - Platform: `Get-IdsAssessmentPlatform $policy $null`. For example
    `windows10` maps to `windows11`. Unsupported or combined values such as
    `windows10,macOS` return `$null`, and the policy is skipped.
  - Level, from the policy name:
    - case-sensitive `L1`, `L2`, `BL` or `NG`, not next to a letter or digit;
    - case-insensitive `Level 1` or `Level 2`.
    - Exactly one distinct level gives that level; none or several give
      "unclassified".
  - Levels map to labels and ID slugs:
    - L1 → `Level 1 (L1)`, `l1`;
    - L2 → `Level 2 (L2)`, `l2`;
    - BL → `BitLocker (BL)`, `bl`;
    - NG → `Next Generation Windows Security (NG)`, `ng`;
    - unclassified → `Unclassified build kit policies`, `build-kit`.
  - Grouping: one pack per platform and level, with the id
    `cis.<platform in lowercase>.<slug>`, for example `cis.windows11.l1` or
    `cis.iosipados.build-kit`. Packs are returned sorted by id (ordinal).
  - Each top-level `settingInstance` is normalized with
    `ConvertTo-IdsCatalogObservations $state $instance $definitions '' $counters`.
    - `$state.policy` is `@{ key = "<entry>/<name>"; family = 'settingsCatalog';
      settingsComplete = $true }`.
    - `$definitions` holds only the definitions whose ids occur inside that
      setting. The normalizer ignores the others anyway, and this keeps large
      policies linear.
  - The normalizer checks template defaults only on direct values. The
    converter therefore scans each top-level setting recursively and skips the
    whole setting when any value inside it has
    `settingValueTemplateReference.useTemplateDefault = true`.
  - An observation is kept when it is supported, configured, not secret and
    has a `valueType`. Every other observation is reported as skipped.
  - Within one pack:
    - a setting that occurs more than once in any one policy is skipped for
      the whole pack;
    - a setting with different values in two policies is skipped for the whole
      pack, and the reason names both policies;
    - equal values merge into one control that references every contributing
      policy.
  - Comparison is type-aware: strings are ordinal and case-sensitive, numbers
    compare by value (`10` equals `10.0`), and sets compare as sorted ordinal
    sequences. The expected set keeps the first policy's order.
- Control: `id` = the setting ID.
  - `title` is the first contributing policy's definition `displayName`, else
    the setting ID.
  - `sourceIds = @('cis-build-kit')`.
  - `reference` is "CIS build kit policy '<name>' (archive entry '<entry>')"
    per distinct policy: up to 5 joined with "; ", then "; and N more".
  - `applicability = { osMin = null; osMax = null; enrollmentModes = [] }` and
    `manualReason = null`.
  - Exactly one mapping: `family 'settingsCatalog'`, `policyTypes
    ['deviceManagementConfigurationPolicy']`, `settingId`, `property null`,
    `instancePath null`, the observed `valueType`, `operator` `eq` (scalars) or
    `setEquals` (`stringSet`/`numberSet`), `expected` (an array for sets, which
    may be empty) and `caseSensitive true`.
- Pack fields, in this order:
  - `schemaVersion 1`, `id`, `version`, `framework 'CIS'`, `frameworkVersion`,
    `classification 'baseline'`, `platform`, `profile` (the label);
  - `sourceRevision "CIS build kit archive SHA-256 <hex>"`;
  - `sources`: one `{ id 'cis-build-kit'; url 'https://workbench.cisecurity.org/';
    revision "Archive SHA-256 <hex>"; retrievedOn }`;
  - `coverage { inventory 'partial'; totalSourceControls null }`;
  - `controls`, sorted by id (ordinal).
- How the variable pack fields are computed:
  - `version` is `1.0.0+` and the first 12 hex characters of the SHA-256 of
    the pack serialized with version `1.0.0`. The content includes the
    archive SHA-256, so a re-zipped archive gives new versions (spec
    decision 12).
  - `frameworkVersion` is the single distinct `v<major>.<minor>.<patch>` in
    the group's used policy names, else in their entry paths, else `Unknown
    (customer-supplied build kit)`. Several versions, or a four-part version,
    give `Unknown`.
  - `retrievedOn` is the newest `lastWriteTime` among the policies that
    contributed a control. It uses the stored wall-clock date (`.DateTime`,
    `yyyy-MM-dd`, InvariantCulture). ZIP timestamps carry no time zone, so
    this gives the same pack in every time zone.
- Serialization: a recursive `[Text.Json.Utf8JsonWriter]` (indented) writes
  UTF-8 without BOM. It keeps the insertion order of `[ordered]` dictionaries
  and writes integers as `long`.
  - A generated pack over 10 MiB is skipped.
  - So is a generated pack that `Read-IdsBaselinePack` rejects.
  - Pack-level skips use the pack id as `entry`.
- Skip reasons, exactly:
  - "Policy '<name>' targets an unsupported or combined platform."
  - "Policy '<name>' contains no settings."
  - "Setting '<id>' in policy '<name>' uses a template default value and was
    not converted."
  - "Setting '<id>' in policy '<name>' is secret and was not converted."
  - "Setting '<id>' in policy '<name>' has an unsupported shape or value type
    and was not converted."
  - "Setting '<id>' in policy '<name>' has no configured value and was not
    converted."
  - "Setting '<id>' occurs more than once in policy '<name>', so it was
    skipped for pack '<pack id>'."
  - "Setting '<id>' has different values in policies '<first>' (archive entry
    '<first entry>') and '<second>' (archive entry '<second entry>'), so it was
    skipped for pack '<pack id>'." The `entry` is the second policy's entry.
  - "Generated pack '<pack id>' exceeds the 10 MiB pack limit."
  - "Generated pack '<pack id>' is invalid: <validator message>"
- `tests\Package.Tests.ps1` runs `Build-Package.ps1`, which prints Dutch
  progress text such as `Pakket klaar`. The leak-scan test prints `FOUT -
  omgevingsspecifieke gegevens gevonden:`. That output is existing and
  expected.

**Files:**

- Create: `lib\BaselineArchive.ps1`
- Modify: `IntuneDocsStudio.ps1` (about lines 57–58, the module load list)
- Modify: `tests\AssessmentIntegration.Tests.ps1` (line 3, the module load list)
- Test: `tests\BaselineArchive.Tests.ps1` (new file)
- Test: `tests\TestHelpers\Assessment.ps1` (new builders after line 60)
- Test: `tests\Package.Tests.ps1` (about lines 62–63, inside the
  `$script:ProductFiles` list at lines 42–73)

**Interfaces:**

- Consumes:
  - From Task 1: nothing.
  - `lib\BaselinePacks.ps1`:
    - `Read-IdsBaselinePack -Bytes <byte[]>`;
    - `ConvertFrom-IdsPackJsonElement($Element, [string]$Path = '$')`;
    - `ConvertTo-IdsPackNumberKey([string]$Text)`.
  - `lib\AssessmentCollection.ps1`:
    - `Get-IdsAssessmentMember($Object, [string]$Name)`;
    - `Get-IdsAssessmentPlatform($Policy, $Template)` → `windows11`, `macos`,
      `iosIpados`, `androidEnterprise` or `$null`.
  - `lib\AssessmentSettings.ps1`:
    - `ConvertTo-IdsCatalogObservations($State, $Node, $Definitions,
      [string]$Parent = '', $Counters = @{}, [int]$Depth = 0,
      [bool]$InheritedSecret = $false)`. It appends `[pscustomobject]@{
      policyKey; family; settingId; property; instancePath; valueType; value;
      configured; secret; supported }` to `$State.observations`.
    - `ConvertTo-IdsAssessmentSnapshot($Collection)` (tests only).
  - `lib\AssessmentRules.ps1`: `Compare-IdsAssessment([object[]]$Packs,
    [pscustomobject]$Snapshot, [hashtable]$Context)` (tests only).
  - Test helpers in `tests\TestHelpers\Assessment.ps1`:
    - `New-IdsTestSettingInstance([string]$Kind = 'simple', [string]$Id =
      'synthetic.setting', $Value = 0)`;
    - `New-IdsTestAssessmentPolicy` and `New-IdsTestAssessmentCollection`.
- Produces:
  - `ConvertTo-IdsBuildKitPacks -Policies <object[]> -ArchiveSha256 <string>`
    (both mandatory; `-Policies` may be empty).
    - It returns `[pscustomobject]@{ packs = <byte[][], sorted by pack id>;
      skipped = <object[] of [pscustomobject]@{ entry; reason }> }`.
    - It throws 'ArchiveSha256 must be 64 lowercase hexadecimal characters.'
  - `Get-IdsBuildKitSha256([byte[]]$Bytes)` → 64 lowercase hex characters.
    Task 3 uses it for the archive hash.
  - Internal helpers in `lib\BaselineArchive.ps1`:
    - `Write-IdsBuildKitJsonValue([Text.Json.Utf8JsonWriter]$Writer, $Value)`;
    - `ConvertTo-IdsBuildKitJsonBytes($Value)` → `byte[]`;
    - `Add-IdsBuildKitSettingScan($Node, $Scan)`;
    - `Get-IdsBuildKitValueKey([string]$ValueType, $Value)` → string;
    - `Get-IdsBuildKitProfile([string]$Name)` → `{ label; slug }`;
    - `Get-IdsBuildKitPolicyName($Policy, [string]$Entry)` → string;
    - `Get-IdsBuildKitVersions([string[]]$Texts)` → `string[]`.
  - Test helpers in `tests\TestHelpers\Assessment.ps1`. Tasks 3 and 4 use
    them.
    - `ConvertTo-IdsTestJsonValue($Value)` → the value as
      `ConvertFrom-IdsPackJsonElement` returns it.
    - `New-IdsTestSettingCollectionInstance([string]$Kind = 'simple',
      [string]$Id = 'synthetic.collection', [object[]]$Values = @())`.
    - `New-IdsTestBuildKitPolicy([string]$Name = 'Synthetic L1 policy',
      [string]$Platforms = 'windows10', [object[]]$Instances = @(),
      [object[]]$Definitions = @())`. The definitions are attached to the
      first setting.
    - `New-IdsTestBuildKitItem($Policy, [string]$Entry = 'kit/policy.json',
      [DateTimeOffset]$LastWriteTime = 2026-10-01 12:00 +00:00)`.
  - `tests\BaselineArchive.Tests.ps1`: a top-level `BeforeAll` that loads the
    modules and defines `$archiveSha` and `Get-TestControlSignature($Control)`.
    Task 3 appends to this file.
  - `'BaselineArchive'` is in the module load list of `IntuneDocsStudio.ps1`
    and `tests\AssessmentIntegration.Tests.ps1`.

- [ ] **Step 1: Add the build-kit test builders**

Append this code at the end of `tests\TestHelpers\Assessment.ps1`, after the
closing `}` of `Assert-IdsTestMarkdownObservations` (about line 60). Leave one
blank line before it.

```powershell
function ConvertTo-IdsTestJsonValue {
    param($Value)
    $document = [Text.Json.JsonDocument]::Parse((ConvertTo-Json -InputObject $Value -Depth 64))
    try { $converted = ConvertFrom-IdsPackJsonElement $document.RootElement } finally { $document.Dispose() }
    return ,$converted
}

function New-IdsTestSettingCollectionInstance {
    param([string]$Kind = 'simple', [string]$Id = 'synthetic.collection', [object[]]$Values = @())
    $typeKind = $Kind.Substring(0, 1).ToUpperInvariant() + $Kind.Substring(1)
    $instance = @{ '@odata.type' = "#microsoft.graph.deviceManagementConfiguration${typeKind}SettingCollectionInstance"; settingDefinitionId = $Id }
    $instance["${Kind}SettingCollectionValue"] = $Values
    return $instance
}

function New-IdsTestBuildKitPolicy {
    param([string]$Name = 'Synthetic L1 policy', [string]$Platforms = 'windows10',
        [object[]]$Instances = @(), [object[]]$Definitions = @())
    $settings = @(for ($index = 0; $index -lt $Instances.Count; $index++) {
        $setting = @{ settingInstance = $Instances[$index] }
        if ($index -eq 0 -and $Definitions.Count -gt 0) { $setting.settingDefinitions = $Definitions }
        $setting
    })
    return ,(ConvertTo-IdsTestJsonValue @{ name = $Name; platforms = $Platforms; technologies = 'mdm'; settings = $settings })
}

function New-IdsTestBuildKitItem {
    param($Policy, [string]$Entry = 'kit/policy.json',
        [DateTimeOffset]$LastWriteTime = [DateTimeOffset]::new(2026, 10, 1, 12, 0, 0, [TimeSpan]::Zero))
    return [pscustomobject]@{ entry = $Entry; policy = $Policy; lastWriteTime = $LastWriteTime }
}
```

- [ ] **Step 2: Create the converter tests**

Create `tests\BaselineArchive.Tests.ps1` with this content:

```powershell
BeforeAll {
    . "$PSScriptRoot\TestHelpers\Assessment.ps1"
    foreach ($module in 'BaselinePacks', 'AssessmentCollection', 'AssessmentSettings', 'AssessmentRules') {
        . "$PSScriptRoot\..\lib\$module.ps1"
    }
    if (Test-Path "$PSScriptRoot\..\lib\BaselineArchive.ps1") { . "$PSScriptRoot\..\lib\BaselineArchive.ps1" }
    $archiveSha = '0123456789abcdef' * 4
    function Get-TestControlSignature($Control) {
        $mapping = $Control.mappings[0]
        "$($Control.id)|$($mapping.valueType)|$($mapping.operator)|$(ConvertTo-Json -InputObject $mapping.expected -Compress)"
    }
}

Describe 'Build-kit Settings Catalog conversion' {
    It 'converts choice, child, collection, integer and string settings into validated controls' {
        $child = New-IdsTestSettingInstance -Id 'syn.choice.child' -Value @{ value = 7 }
        $instances = @(
            (New-IdsTestSettingInstance -Kind choice -Id 'syn.choice' -Value @{ value = 'syn.choice_1'; children = @($child) }),
            (New-IdsTestSettingInstance -Id 'syn.integer' -Value @{
                '@odata.type' = '#microsoft.graph.deviceManagementConfigurationIntegerSettingValue'; value = 5 }),
            (New-IdsTestSettingInstance -Id 'syn.string' -Value @{
                '@odata.type' = '#microsoft.graph.deviceManagementConfigurationStringSettingValue'; value = 'Exact Text' }),
            (New-IdsTestSettingCollectionInstance -Id 'syn.strings' -Values @(@{ value = 'b' }, @{ value = 'a' })),
            (New-IdsTestSettingCollectionInstance -Id 'syn.numbers' -Values @(@{ value = 3 }, @{ value = 1 })),
            (New-IdsTestSettingCollectionInstance -Id 'syn.empty'),
            (New-IdsTestSettingCollectionInstance -Kind choice -Id 'syn.choices' -Values @(
                @{ value = 'syn.choices_2' }, @{ value = 'syn.choices_1' }))
        )
        $definitions = @(
            @{ id = 'syn.choice'; displayName = 'Synthetic choice' },
            @{ id = 'syn.empty'; valueDefinition = @{
                '@odata.type' = '#microsoft.graph.deviceManagementConfigurationIntegerSettingValueDefinition' } }
        )
        $policy = New-IdsTestBuildKitPolicy -Instances $instances -Definitions $definitions
        $result = ConvertTo-IdsBuildKitPacks -Policies @(New-IdsTestBuildKitItem $policy) -ArchiveSha256 $archiveSha
        $result.skipped.Count | Should -Be 0
        $result.packs.Count | Should -Be 1
        $pack = Read-IdsBaselinePack -Bytes $result.packs[0]
        $pack.id | Should -BeExactly 'cis.windows11.l1'
        $pack.profile | Should -BeExactly 'Level 1 (L1)'
        $pack.framework | Should -BeExactly 'CIS'
        $pack.classification | Should -BeExactly 'baseline'
        $pack.platform | Should -BeExactly 'windows11'
        $pack.frameworkVersion | Should -BeExactly 'Unknown (customer-supplied build kit)'
        (@($pack.controls | ForEach-Object { Get-TestControlSignature $_ }) -join "`n") | Should -BeExactly (@(
            'syn.choice|string|eq|"syn.choice_1"'
            'syn.choice.child|number|eq|7'
            'syn.choices|stringSet|setEquals|["syn.choices_2","syn.choices_1"]'
            'syn.empty|numberSet|setEquals|[]'
            'syn.integer|number|eq|5'
            'syn.numbers|numberSet|setEquals|[3,1]'
            'syn.string|string|eq|"Exact Text"'
            'syn.strings|stringSet|setEquals|["b","a"]'
        ) -join "`n")
        $pack.controls[0].title | Should -BeExactly 'Synthetic choice'
        $pack.controls[3].title | Should -BeExactly 'syn.empty'
        foreach ($control in $pack.controls) {
            $control.reference | Should -BeExactly "CIS build kit policy 'Synthetic L1 policy' (archive entry 'kit/policy.json')"
            (@($control.sourceIds) -join ',') | Should -BeExactly 'cis-build-kit'
            $control.manualReason | Should -BeNullOrEmpty
            $control.applicability.osMin | Should -BeNullOrEmpty
            $control.applicability.osMax | Should -BeNullOrEmpty
            @($control.applicability.enrollmentModes).Count | Should -Be 0
            @($control.mappings).Count | Should -Be 1
            $control.mappings[0].family | Should -BeExactly 'settingsCatalog'
            (@($control.mappings[0].policyTypes) -join ',') | Should -BeExactly 'deviceManagementConfigurationPolicy'
            $control.mappings[0].settingId | Should -BeExactly $control.id
            $control.mappings[0].property | Should -BeNullOrEmpty
            $control.mappings[0].instancePath | Should -BeNullOrEmpty
            $control.mappings[0].caseSensitive | Should -BeTrue
        }
    }

    It 'skips secret, unsupported, unconfigured and template-default settings with reasons' {
        $secret = New-IdsTestSettingInstance -Id 'syn.secret' -Value @{
            '@odata.type' = '#microsoft.graph.deviceManagementConfigurationSecretSettingValue'; value = 'synthetic-hidden-value' }
        $unknown = @{ '@odata.type' = '#microsoft.graph.deviceManagementConfigurationUnknownSettingInstance'; settingDefinitionId = 'syn.unknown' }
        $missing = New-IdsTestSettingInstance -Id 'syn.missing' -Value $null
        $template = New-IdsTestSettingInstance -Id 'syn.template' -Value @{
            value = 1; settingValueTemplateReference = @{ useTemplateDefault = $true } }
        $nestedChild = New-IdsTestSettingInstance -Id 'syn.parent.child' -Value @{
            value = 2; settingValueTemplateReference = @{ useTemplateDefault = $true } }
        $nested = New-IdsTestSettingInstance -Kind choice -Id 'syn.parent' -Value @{ value = 'syn.parent_1'; children = @($nestedChild) }
        $kept = New-IdsTestSettingInstance -Id 'syn.kept' -Value @{ value = 1 }
        $policy = New-IdsTestBuildKitPolicy -Name 'Synthetic L1 skips' -Instances @($secret, $unknown, $missing, $template, $nested, $kept)
        $result = ConvertTo-IdsBuildKitPacks -Policies @(New-IdsTestBuildKitItem $policy 'kit/skips.json') -ArchiveSha256 $archiveSha
        $result.packs.Count | Should -Be 1
        $pack = Read-IdsBaselinePack -Bytes $result.packs[0]
        (@($pack.controls.id) -join ',') | Should -BeExactly 'syn.kept'
        (@($result.skipped | ForEach-Object { "$($_.entry) => $($_.reason)" }) -join "`n") | Should -BeExactly (@(
            "kit/skips.json => Setting 'syn.secret' in policy 'Synthetic L1 skips' is secret and was not converted."
            "kit/skips.json => Setting 'syn.unknown' in policy 'Synthetic L1 skips' has an unsupported shape or value type and was not converted."
            "kit/skips.json => Setting 'syn.missing' in policy 'Synthetic L1 skips' has no configured value and was not converted."
            "kit/skips.json => Setting 'syn.template' in policy 'Synthetic L1 skips' uses a template default value and was not converted."
            "kit/skips.json => Setting 'syn.parent' in policy 'Synthetic L1 skips' uses a template default value and was not converted."
        ) -join "`n")
        [Text.Encoding]::UTF8.GetString($result.packs[0]) | Should -Not -Match 'synthetic-hidden-value'
    }

    It 'skips repeated and conflicting settings and merges equal values from several policies' {
        $group = @{
            '@odata.type' = '#microsoft.graph.deviceManagementConfigurationGroupSettingCollectionInstance'
            settingDefinitionId = 'syn.group'
            groupSettingCollectionValue = @(
                @{ children = @(New-IdsTestSettingInstance -Id 'syn.group.item' -Value @{ value = 1 }) },
                @{ children = @(New-IdsTestSettingInstance -Id 'syn.group.item' -Value @{ value = 2 }) }
            )
        }
        $first = New-IdsTestBuildKitPolicy -Name 'Synthetic L1 first' -Instances @(
            $group,
            (New-IdsTestSettingInstance -Id 'syn.number' -Value @{ value = 5 }),
            (New-IdsTestSettingInstance -Id 'syn.text' -Value @{ value = 'Abc' }),
            (New-IdsTestSettingInstance -Id 'syn.type' -Value @{ value = 5 }),
            (New-IdsTestSettingInstance -Id 'syn.same' -Value @{ value = 10 }),
            (New-IdsTestSettingCollectionInstance -Id 'syn.set' -Values @(@{ value = 'a' }, @{ value = 'b' }))
        )
        $second = New-IdsTestBuildKitPolicy -Name 'Synthetic L1 second' -Instances @(
            (New-IdsTestSettingInstance -Id 'syn.number' -Value @{ value = 6 }),
            (New-IdsTestSettingInstance -Id 'syn.text' -Value @{ value = 'abc' }),
            (New-IdsTestSettingInstance -Id 'syn.type' -Value @{ value = '5' }),
            (New-IdsTestSettingInstance -Id 'syn.same' -Value @{ value = [decimal]'10.0' }),
            (New-IdsTestSettingCollectionInstance -Id 'syn.set' -Values @(@{ value = 'b' }, @{ value = 'a' }))
        )
        $result = ConvertTo-IdsBuildKitPacks -Policies @(
            (New-IdsTestBuildKitItem $first 'kit/a.json'),
            (New-IdsTestBuildKitItem $second 'kit/b.json')
        ) -ArchiveSha256 $archiveSha
        $pack = Read-IdsBaselinePack -Bytes $result.packs[0]
        (@($pack.controls.id) -join ',') | Should -BeExactly 'syn.same,syn.set'
        $pack.controls[0].reference | Should -BeExactly ("CIS build kit policy 'Synthetic L1 first' (archive entry 'kit/a.json'); " +
            "CIS build kit policy 'Synthetic L1 second' (archive entry 'kit/b.json')")
        $pack.controls[0].mappings[0].expected | Should -Be 10
        $conflict = "in policies 'Synthetic L1 first' (archive entry 'kit/a.json') and 'Synthetic L1 second' " +
            "(archive entry 'kit/b.json'), so it was skipped for pack 'cis.windows11.l1'."
        (@($result.skipped | ForEach-Object { "$($_.entry) => $($_.reason)" }) -join "`n") | Should -BeExactly (@(
            "kit/a.json => Setting 'syn.group.item' occurs more than once in policy 'Synthetic L1 first', so it was skipped for pack 'cis.windows11.l1'."
            "kit/b.json => Setting 'syn.number' has different values $conflict"
            "kit/b.json => Setting 'syn.text' has different values $conflict"
            "kit/b.json => Setting 'syn.type' has different values $conflict"
        ) -join "`n")
    }

    It 'lists at most five policy references per control' {
        $items = @(foreach ($number in 1..7) {
            $policy = New-IdsTestBuildKitPolicy -Name "Synthetic L1 policy $number" -Instances @(
                New-IdsTestSettingInstance -Id 'syn.shared' -Value @{ value = 1 })
            New-IdsTestBuildKitItem $policy "kit/p$number.json"
        })
        $result = ConvertTo-IdsBuildKitPacks -Policies $items -ArchiveSha256 $archiveSha
        $pack = Read-IdsBaselinePack -Bytes $result.packs[0]
        $expected = (@(foreach ($number in 1..5) {
            "CIS build kit policy 'Synthetic L1 policy $number' (archive entry 'kit/p$number.json')"
        }) -join '; ') + '; and 2 more'
        $pack.controls[0].reference | Should -BeExactly $expected
    }

    It 'groups policies by platform and CIS profile level and skips unsupported platforms' {
        $cases = @(
            @('Synthetic L1 Windows', 'windows10'),
            @('Synthetic (L2) Windows', 'windows10AndLater'),
            @('Synthetic BL Windows', 'windows11'),
            @('Synthetic NG Windows', 'windows10'),
            @('Synthetic l1 BLOCKING Windows', 'windows10'),
            @('Synthetic L1 and L2 Windows', 'windows10'),
            @('Synthetic Level 1 (L1) macOS', 'macOS'),
            @('Synthetic LEVEL 2 iOS', 'iOS'),
            @('Synthetic Android', 'androidEnterprise'),
            @('Synthetic L1 combined', 'windows10,macOS'),
            @('Synthetic L1 Linux', 'linux')
        )
        $items = @(for ($index = 0; $index -lt $cases.Count; $index++) {
            $policy = New-IdsTestBuildKitPolicy -Name $cases[$index][0] -Platforms $cases[$index][1] -Instances @(
                New-IdsTestSettingInstance -Id "syn.setting$index" -Value @{ value = $index })
            New-IdsTestBuildKitItem $policy "kit/$index.json"
        })
        $result = ConvertTo-IdsBuildKitPacks -Policies $items -ArchiveSha256 $archiveSha
        $packs = @($result.packs | ForEach-Object { Read-IdsBaselinePack -Bytes $_ })
        (@($packs | ForEach-Object { "$($_.id)|$($_.profile)|$($_.platform)|$(@($_.controls.id) -join ',')" }) -join "`n") |
            Should -BeExactly (@(
                'cis.androidenterprise.build-kit|Unclassified build kit policies|androidEnterprise|syn.setting8'
                'cis.iosipados.l2|Level 2 (L2)|iosIpados|syn.setting7'
                'cis.macos.l1|Level 1 (L1)|macos|syn.setting6'
                'cis.windows11.bl|BitLocker (BL)|windows11|syn.setting2'
                'cis.windows11.build-kit|Unclassified build kit policies|windows11|syn.setting4,syn.setting5'
                'cis.windows11.l1|Level 1 (L1)|windows11|syn.setting0'
                'cis.windows11.l2|Level 2 (L2)|windows11|syn.setting1'
                'cis.windows11.ng|Next Generation Windows Security (NG)|windows11|syn.setting3'
            ) -join "`n")
        (@($result.skipped | ForEach-Object { "$($_.entry) => $($_.reason)" }) -join "`n") | Should -BeExactly (@(
            "kit/9.json => Policy 'Synthetic L1 combined' targets an unsupported or combined platform."
            "kit/10.json => Policy 'Synthetic L1 Linux' targets an unsupported or combined platform."
        ) -join "`n")
    }

    It 'detects one framework version from <label>' -ForEach @(
        @{ label = 'policy names'; names = @('Synthetic L1 v4.0.0 first', 'Synthetic L1 v4.0.0 second')
            entries = @('kit/a.json', 'kit/b.json'); expected = 'v4.0.0' }
        @{ label = 'entry paths'; names = @('Synthetic L1 first', 'Synthetic L1 second')
            entries = @('kit_v3.0.1/a.json', 'kit_v3.0.1/b.json'); expected = 'v3.0.1' }
        @{ label = 'conflicting names'; names = @('Synthetic L1 v4.0.0', 'Synthetic L1 v4.1.0')
            entries = @('kit_v3.0.1/a.json', 'kit_v3.0.1/b.json'); expected = 'Unknown (customer-supplied build kit)' }
        @{ label = 'four-part versions'; names = @('Synthetic L1 v4.0.0.1', 'Synthetic L1 second')
            entries = @('kit/a.json', 'kit/b.json'); expected = 'Unknown (customer-supplied build kit)' }
    ) {
        $items = @(for ($index = 0; $index -lt 2; $index++) {
            $policy = New-IdsTestBuildKitPolicy -Name $names[$index] -Instances @(
                New-IdsTestSettingInstance -Id "syn.version$index" -Value @{ value = $index })
            New-IdsTestBuildKitItem $policy $entries[$index]
        })
        $result = ConvertTo-IdsBuildKitPacks -Policies $items -ArchiveSha256 $archiveSha
        (Read-IdsBaselinePack -Bytes $result.packs[0]).frameworkVersion | Should -BeExactly $expected
    }

    It 'produces deterministic bytes, content-derived versions and wall-clock retrieval dates' {
        $first = New-IdsTestBuildKitPolicy -Name 'Synthetic L1 first' -Instances @(
            New-IdsTestSettingInstance -Id 'syn.first' -Value @{ value = 1 })
        $second = New-IdsTestBuildKitPolicy -Name 'Synthetic L1 second' -Instances @(
            New-IdsTestSettingInstance -Id 'syn.second' -Value @{ value = 'two' })
        $hidden = New-IdsTestBuildKitPolicy -Name 'Synthetic L1 hidden' -Instances @(
            New-IdsTestSettingInstance -Id 'syn.hidden' -Value @{
                '@odata.type' = '#microsoft.graph.deviceManagementConfigurationSecretSettingValue'; value = 'hidden' })
        $items = @(
            (New-IdsTestBuildKitItem $first 'kit/a.json' ([DateTimeOffset]::new(2026, 10, 3, 1, 0, 0, [TimeSpan]::FromHours(5)))),
            (New-IdsTestBuildKitItem $second 'kit/b.json' ([DateTimeOffset]::new(2026, 10, 1, 12, 0, 0, [TimeSpan]::Zero))),
            (New-IdsTestBuildKitItem $hidden 'kit/c.json' ([DateTimeOffset]::new(2026, 12, 31, 12, 0, 0, [TimeSpan]::Zero)))
        )
        $one = ConvertTo-IdsBuildKitPacks -Policies $items -ArchiveSha256 $archiveSha
        $two = ConvertTo-IdsBuildKitPacks -Policies $items -ArchiveSha256 $archiveSha
        $one.packs.Count | Should -Be 1
        [Convert]::ToBase64String($two.packs[0]) | Should -BeExactly ([Convert]::ToBase64String($one.packs[0]))
        $one.packs[0][0] | Should -Be 0x7B
        $pack = Read-IdsBaselinePack -Bytes $one.packs[0]
        $text = [Text.Encoding]::UTF8.GetString($one.packs[0])
        $escaped = [Text.Json.JsonEncodedText]::Encode($pack.version).ToString()
        $baseText = $text.Replace("""version"": ""$escaped""", '"version": "1.0.0"')
        $baseBytes = [Text.Encoding]::UTF8.GetBytes($baseText)
        $baseHash = (Get-FileHash -InputStream ([IO.MemoryStream]::new($baseBytes)) -Algorithm SHA256).Hash.ToLowerInvariant()
        $pack.version | Should -BeExactly ('1.0.0+' + $baseHash.Substring(0, 12))
        $pack.sourceRevision | Should -BeExactly "CIS build kit archive SHA-256 $archiveSha"
        @($pack.sources).Count | Should -Be 1
        $pack.sources[0].id | Should -BeExactly 'cis-build-kit'
        $pack.sources[0].url | Should -BeExactly 'https://workbench.cisecurity.org/'
        $pack.sources[0].revision | Should -BeExactly "Archive SHA-256 $archiveSha"
        $pack.sources[0].retrievedOn | Should -BeExactly '2026-10-03'
        $pack.coverage.inventory | Should -BeExactly 'partial'
        $pack.coverage.totalSourceControls | Should -BeNullOrEmpty
        $other = ConvertTo-IdsBuildKitPacks -Policies $items -ArchiveSha256 ('fedcba9876543210' * 4)
        (Read-IdsBaselinePack -Bytes $other.packs[0]).version | Should -Not -Be $pack.version
    }

    It 'reports policies without settings and accepts an empty policy list' {
        $empty = ConvertTo-IdsTestJsonValue @{ name = 'Synthetic L1 empty'; platforms = 'windows10'; settings = @() }
        $missing = ConvertTo-IdsTestJsonValue @{ name = 'Synthetic L1 missing'; platforms = 'windows10' }
        $result = ConvertTo-IdsBuildKitPacks -Policies @(
            (New-IdsTestBuildKitItem $empty 'kit/empty.json'),
            (New-IdsTestBuildKitItem $missing 'kit/missing.json')
        ) -ArchiveSha256 $archiveSha
        $result.packs.Count | Should -Be 0
        (@($result.skipped | ForEach-Object { "$($_.entry) => $($_.reason)" }) -join "`n") | Should -BeExactly (@(
            "kit/empty.json => Policy 'Synthetic L1 empty' contains no settings."
            "kit/missing.json => Policy 'Synthetic L1 missing' contains no settings."
        ) -join "`n")
        $none = ConvertTo-IdsBuildKitPacks -Policies @() -ArchiveSha256 $archiveSha
        $none.packs.Count | Should -Be 0
        $none.skipped.Count | Should -Be 0
    }

    It 'creates controls that the rule engine evaluates against Settings Catalog evidence' {
        $policy = New-IdsTestBuildKitPolicy -Name 'Synthetic L1 rule' -Instances @(
            New-IdsTestSettingInstance -Id 'syn.rule' -Value @{ value = 15 })
        $result = ConvertTo-IdsBuildKitPacks -Policies @(New-IdsTestBuildKitItem $policy) -ArchiveSha256 $archiveSha
        $pack = Read-IdsBaselinePack -Bytes $result.packs[0]
        $context = @{ platforms = @('windows11'); osVersions = @{ windows11 = '10.0.22631' }; enrollmentModes = @{} }
        foreach ($case in @(@{ value = 15; status = 'aligned' }, @{ value = 14; status = 'misaligned' })) {
            $instance = New-IdsTestSettingInstance -Id 'syn.rule' -Value @{ value = $case.value }
            $tenant = New-IdsTestAssessmentPolicy -Settings @(@{ settingInstance = $instance })
            $tenant.platform = 'windows11'
            $collection = New-IdsTestAssessmentCollection @($tenant)
            $collection.sources = @([pscustomobject]@{ family = 'settingsCatalog'; platform = 'windows11'; complete = $true; errors = @() })
            $comparison = Compare-IdsAssessment @($pack) (ConvertTo-IdsAssessmentSnapshot $collection) $context
            $comparison.controls.Count | Should -Be 1
            $comparison.controls[0].status | Should -BeExactly $case.status
        }
    }

    It 'requires a lowercase archive SHA-256' {
        { ConvertTo-IdsBuildKitPacks -Policies @() -ArchiveSha256 ('A' * 64) } |
            Should -Throw 'ArchiveSha256 must be 64 lowercase hexadecimal characters.'
    }

    It 'skips generated packs over the 10 MiB limit and packs that fail validation' {
        $large = @{ name = 'Synthetic L1 large'; platforms = 'windows10'; settings = @(foreach ($number in 1..11) {
            @{ settingInstance = New-IdsTestSettingInstance -Id "syn.large$number" -Value @{ value = ('x' * 1MB) } }
        }) }
        $long = @{ name = 'Synthetic L2 long'; platforms = 'windows10'; settings = @(
            @{ settingInstance = New-IdsTestSettingInstance -Id 'syn.long' -Value @{ value = ('y' * 40000) } }
        ) }
        $result = ConvertTo-IdsBuildKitPacks -Policies @(
            (New-IdsTestBuildKitItem $large 'kit/large.json'),
            (New-IdsTestBuildKitItem $long 'kit/long.json')
        ) -ArchiveSha256 $archiveSha
        $result.packs.Count | Should -Be 0
        $result.skipped.Count | Should -Be 2
        $result.skipped[0].entry | Should -BeExactly 'cis.windows11.l1'
        $result.skipped[0].reason | Should -BeExactly "Generated pack 'cis.windows11.l1' exceeds the 10 MiB pack limit."
        $result.skipped[1].entry | Should -BeExactly 'cis.windows11.l2'
        $result.skipped[1].reason | Should -BeLike "Generated pack 'cis.windows11.l2' is invalid: *string limit*"
    }

    It 'names policies by name, then displayName, then archive file name' {
        $display = ConvertTo-IdsTestJsonValue @{ displayName = 'Synthetic L1 display'; platforms = 'windows10'; settings = @(
            @{ settingInstance = New-IdsTestSettingInstance -Id 'syn.display' -Value @{ value = 1 } }) }
        $file = ConvertTo-IdsTestJsonValue @{ platforms = 'windows10'; settings = @(
            @{ settingInstance = New-IdsTestSettingInstance -Id 'syn.file' -Value @{ value = 2 } }) }
        $result = ConvertTo-IdsBuildKitPacks -Policies @(
            (New-IdsTestBuildKitItem $display 'kit/display.json'),
            (New-IdsTestBuildKitItem $file 'kit/L1/Synthetic L1 file.JSON')
        ) -ArchiveSha256 $archiveSha
        $pack = Read-IdsBaselinePack -Bytes $result.packs[0]
        $pack.id | Should -BeExactly 'cis.windows11.l1'
        (@($pack.controls.reference) -join "`n") | Should -BeExactly (@(
            "CIS build kit policy 'Synthetic L1 display' (archive entry 'kit/display.json')"
            "CIS build kit policy 'Synthetic L1 file' (archive entry 'kit/L1/Synthetic L1 file.JSON')"
        ) -join "`n")
    }
}
```

- [ ] **Step 3: Expect the new module in the package**

In `tests\Package.Tests.ps1`, inside `$script:ProductFiles`, replace these two
lines (about lines 62–63):

```powershell
        'lib\Auth.ps1'
        'lib\BaselinePacks.ps1'
```

with:

```powershell
        'lib\Auth.ps1'
        'lib\BaselineArchive.ps1'
        'lib\BaselinePacks.ps1'
```

- [ ] **Step 4: Run the new tests and see them fail**

Run:

```powershell
Invoke-Pester .\tests\BaselineArchive.Tests.ps1, .\tests\Package.Tests.ps1 -Output Detailed
```

Expected: `Tests Passed: 16, Failed: 16, Skipped: 0, Inconclusive: 0, NotRun: 0`.
The failing tests are:

- 14 of the 15 cases in `tests\BaselineArchive.Tests.ps1`, with `The term
  'ConvertTo-IdsBuildKitPacks' is not recognized as a name of a cmdlet,
  function, script file, or executable program.`
- `requires a lowercase archive SHA-256`, with `Expected an exception with
  message like 'ArchiveSha256 must be 64 lowercase hexadecimal characters.' to
  be thrown, but the message was 'The term 'ConvertTo-IdsBuildKitPacks' is not
  recognized ...`.
- `includes build identity and exactly the permitted product files` in
  `tests\Package.Tests.ps1`. Its message starts with `Expected
  @('baselines\microsoft-android-enterprise.json',`, and it contains `...22
  more), but got @(` and ends with `...21 more).`. The list now names 32
  product files plus `build-info.json`, and the package still has 31.

The other 16 tests in `tests\Package.Tests.ps1` pass.

- [ ] **Step 5: Create the converter**

Create `lib\BaselineArchive.ps1` with this content:

```powershell
<#
    CIS build-kit import. Requires BaselinePacks.ps1, AssessmentCollection.ps1
    and AssessmentSettings.ps1.

    Archives are read in memory; nothing is extracted or written here. Policy
    values come from ConvertFrom-IdsPackJsonElement. Generated packs are
    deterministic for the same archive, so importing it again is idempotent.
#>

function Get-IdsBuildKitSha256 {
    param([byte[]]$Bytes)
    $sha = [Security.Cryptography.SHA256]::Create()
    try {
        return ([BitConverter]::ToString($sha.ComputeHash($Bytes))).Replace('-', '').ToLowerInvariant()
    } finally { $sha.Dispose() }
}

function Write-IdsBuildKitJsonValue {
    param([Text.Json.Utf8JsonWriter]$Writer, $Value)
    if ($null -eq $Value) { $Writer.WriteNullValue(); return }
    if ($Value -is [bool]) { $Writer.WriteBooleanValue($Value); return }
    if ($Value -is [string]) { $Writer.WriteStringValue([string]$Value); return }
    if ($Value -is [decimal]) { $Writer.WriteNumberValue([decimal]$Value); return }
    if ($Value -is [double] -or $Value -is [single]) { $Writer.WriteNumberValue([double]$Value); return }
    if ($Value -is [uint64]) { $Writer.WriteNumberValue([uint64]$Value); return }
    if ($Value -is [sbyte] -or $Value -is [byte] -or $Value -is [int16] -or $Value -is [uint16] -or
        $Value -is [int32] -or $Value -is [uint32] -or $Value -is [int64]) {
        $Writer.WriteNumberValue([long]$Value)
        return
    }
    if ($Value -is [Collections.IDictionary]) {
        $Writer.WriteStartObject()
        foreach ($pair in $Value.GetEnumerator()) {
            $Writer.WritePropertyName([string]$pair.Key)
            Write-IdsBuildKitJsonValue $Writer $pair.Value
        }
        $Writer.WriteEndObject()
        return
    }
    if ($Value -is [Collections.IList]) {
        $Writer.WriteStartArray()
        foreach ($item in $Value) { Write-IdsBuildKitJsonValue $Writer $item }
        $Writer.WriteEndArray()
        return
    }
    throw "Unsupported generated pack value type: $($Value.GetType().FullName)."
}

function ConvertTo-IdsBuildKitJsonBytes {
    param($Value)
    $options = [Text.Json.JsonWriterOptions]::new()
    $options.Indented = $true
    $stream = [IO.MemoryStream]::new()
    try {
        $writer = [Text.Json.Utf8JsonWriter]::new($stream, $options)
        try {
            Write-IdsBuildKitJsonValue $writer $Value
            $writer.Flush()
        } finally { $writer.Dispose() }
        return ,($stream.ToArray())
    } finally { $stream.Dispose() }
}

function Add-IdsBuildKitSettingScan {
    param($Node, $Scan)
    if ($Node -is [Collections.IList]) {
        foreach ($item in $Node) { Add-IdsBuildKitSettingScan $item $Scan }
        return
    }
    if ($Node -isnot [Collections.IDictionary]) { return }
    $id = $Node['settingDefinitionId']
    if ($id -is [string]) { [void]$Scan.ids.Add($id) }
    # The normalizer checks template defaults only on direct values; a nested
    # default would otherwise leave the parent choice behind as a control.
    if ((Get-IdsAssessmentMember $Node['settingValueTemplateReference'] 'useTemplateDefault') -eq $true) {
        $Scan.templateDefault = $true
    }
    # Enumerate pairs: member access on a dictionary can resolve to a key.
    foreach ($pair in $Node.GetEnumerator()) { Add-IdsBuildKitSettingScan $pair.Value $Scan }
}

function Get-IdsBuildKitValueKey {
    param([string]$ValueType, $Value)
    $parts = [Collections.Generic.List[string]]::new()
    foreach ($item in @($Value)) {
        $text = if ($item -is [bool]) {
            if ($item) { 'true' } else { 'false' }
        } elseif ($item -is [string]) {
            $item
        } elseif ($item -is [decimal]) {
            ConvertTo-IdsPackNumberKey ($item.ToString('G29', [Globalization.CultureInfo]::InvariantCulture))
        } elseif ($item -is [double] -or $item -is [single]) {
            ConvertTo-IdsPackNumberKey ($item.ToString('R', [Globalization.CultureInfo]::InvariantCulture))
        } else {
            ConvertTo-IdsPackNumberKey ([Convert]::ToString($item, [Globalization.CultureInfo]::InvariantCulture))
        }
        $parts.Add("$($text.Length):$text")
    }
    $keys = $parts.ToArray()
    if ($ValueType -cin @('stringSet', 'numberSet')) { [Array]::Sort($keys, [StringComparer]::Ordinal) }
    return "$ValueType|" + ($keys -join '|')
}

function Get-IdsBuildKitProfile {
    param([string]$Name)
    $levels = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    foreach ($match in [regex]::Matches($Name, '(?<![A-Za-z0-9])(L1|L2|BL|NG)(?![A-Za-z0-9])')) {
        [void]$levels.Add($match.Groups[1].Value)
    }
    foreach ($match in [regex]::Matches($Name, '(?<![A-Za-z0-9])level ([12])(?![A-Za-z0-9])', 'IgnoreCase')) {
        [void]$levels.Add("L$($match.Groups[1].Value)")
    }
    $level = if ($levels.Count -eq 1) { @($levels)[0] } else { $null }
    switch -CaseSensitive ($level) {
        'L1' { return [pscustomobject]@{ label = 'Level 1 (L1)'; slug = 'l1' } }
        'L2' { return [pscustomobject]@{ label = 'Level 2 (L2)'; slug = 'l2' } }
        'BL' { return [pscustomobject]@{ label = 'BitLocker (BL)'; slug = 'bl' } }
        'NG' { return [pscustomobject]@{ label = 'Next Generation Windows Security (NG)'; slug = 'ng' } }
    }
    return [pscustomobject]@{ label = 'Unclassified build kit policies'; slug = 'build-kit' }
}

function Get-IdsBuildKitPolicyName {
    param($Policy, [string]$Entry)
    foreach ($field in @('name', 'displayName')) {
        $value = Get-IdsAssessmentMember $Policy $field
        if ($value -is [string] -and -not [string]::IsNullOrWhiteSpace($value)) { return $value }
    }
    $file = @($Entry -split '[/\\]')[-1] -replace '(?i)\.json\z', ''
    if ([string]::IsNullOrWhiteSpace($file)) { return $Entry }
    return $file
}

function Get-IdsBuildKitVersions {
    param([string[]]$Texts)
    $versions = [Collections.Generic.List[string]]::new()
    foreach ($text in $Texts) {
        foreach ($match in [regex]::Matches($text, '(?<![A-Za-z0-9])v[0-9]+\.[0-9]+\.[0-9]+(?!\.?[0-9])')) {
            if (-not $versions.Contains($match.Value)) { $versions.Add($match.Value) }
        }
    }
    return ,($versions.ToArray())
}

function ConvertTo-IdsBuildKitPacks {
    param([Parameter(Mandatory)][AllowEmptyCollection()][object[]]$Policies,
        [Parameter(Mandatory)][string]$ArchiveSha256)
    if ($ArchiveSha256 -cnotmatch '\A[0-9a-f]{64}\z') { throw 'ArchiveSha256 must be 64 lowercase hexadecimal characters.' }
    $skipped = [Collections.Generic.List[object]]::new()
    $groups = [Collections.Generic.Dictionary[string, object]]::new([StringComparer]::Ordinal)
    foreach ($item in $Policies) {
        $entry = [string]$item.entry
        $policy = $item.policy
        $name = Get-IdsBuildKitPolicyName $policy $entry
        $platform = Get-IdsAssessmentPlatform $policy $null
        if (-not $platform) {
            $skipped.Add([pscustomobject]@{ entry = $entry; reason = "Policy '$name' targets an unsupported or combined platform." })
            continue
        }
        $settings = Get-IdsAssessmentMember $policy 'settings'
        if ($settings -isnot [Collections.IList] -or $settings.Count -eq 0) {
            $skipped.Add([pscustomobject]@{ entry = $entry; reason = "Policy '$name' contains no settings." })
            continue
        }
        $definitions = [Collections.Generic.Dictionary[string, object]]::new([StringComparer]::Ordinal)
        $titles = [Collections.Generic.Dictionary[string, string]]::new([StringComparer]::Ordinal)
        foreach ($setting in $settings) {
            foreach ($definition in (Get-IdsAssessmentMember $setting 'settingDefinitions')) {
                $definitionId = Get-IdsAssessmentMember $definition 'id'
                if ($definitionId -isnot [string]) { continue }
                if (-not $definitions.ContainsKey($definitionId)) {
                    $definitions[$definitionId] = [Collections.Generic.List[object]]::new()
                }
                $definitions[$definitionId].Add($definition)
                $displayName = Get-IdsAssessmentMember $definition 'displayName'
                if (-not $titles.ContainsKey($definitionId) -and $displayName -is [string] -and
                    -not [string]::IsNullOrWhiteSpace($displayName)) {
                    $titles[$definitionId] = $displayName
                }
            }
        }
        $state = @{
            policy = [pscustomobject]@{ key = "$entry/$name"; family = 'settingsCatalog'; settingsComplete = $true }
            observations = [Collections.Generic.List[object]]::new()
            issues = [Collections.Generic.List[object]]::new()
        }
        $counters = @{}
        $kept = [Collections.Generic.List[object]]::new()
        foreach ($setting in $settings) {
            $instance = Get-IdsAssessmentMember $setting 'settingInstance'
            $topId = Get-IdsAssessmentMember $instance 'settingDefinitionId'
            $label = if ($topId -is [string] -and -not [string]::IsNullOrWhiteSpace($topId)) { $topId } else { '(unnamed setting)' }
            $scan = @{ ids = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal); templateDefault = $false }
            Add-IdsBuildKitSettingScan $instance $scan
            if ($scan.templateDefault) {
                $skipped.Add([pscustomobject]@{ entry = $entry
                    reason = "Setting '$label' in policy '$name' uses a template default value and was not converted." })
                continue
            }
            # The normalizer only uses definitions whose id matches a node, so
            # passing that subset keeps large policies linear.
            $subset = [Collections.Generic.List[object]]::new()
            foreach ($id in $scan.ids) {
                if ($definitions.ContainsKey($id)) { $subset.AddRange($definitions[$id]) }
            }
            $start = $state.observations.Count
            ConvertTo-IdsCatalogObservations $state $instance $subset.ToArray() '' $counters
            for ($index = $start; $index -lt $state.observations.Count; $index++) {
                $observation = $state.observations[$index]
                $problem = if ($observation.secret) { 'is secret' }
                elseif (-not $observation.supported) { 'has an unsupported shape or value type' }
                elseif (-not $observation.configured -or -not $observation.valueType) { 'has no configured value' }
                else { $null }
                if (-not $problem) { $kept.Add($observation); continue }
                $settingLabel = if ($observation.settingId -is [string] -and
                    -not [string]::IsNullOrWhiteSpace($observation.settingId)) { $observation.settingId } else { '(unnamed setting)' }
                $skipped.Add([pscustomobject]@{ entry = $entry
                    reason = "Setting '$settingLabel' in policy '$name' $problem and was not converted." })
            }
        }
        if ($kept.Count -eq 0) { continue }
        $level = Get-IdsBuildKitProfile $name
        $packId = "cis.$($platform.ToLowerInvariant()).$($level.slug)"
        if (-not $groups.ContainsKey($packId)) {
            $groups[$packId] = [pscustomobject]@{
                platform = $platform; profile = $level.label; members = [Collections.Generic.List[object]]::new()
            }
        }
        $group = $groups[$packId]
        $group.members.Add([pscustomobject]@{
            index = $group.members.Count; entry = $entry; name = $name
            lastWriteTime = ([DateTimeOffset]$item.lastWriteTime).DateTime
            observations = $kept; titles = $titles
        })
    }

    $packs = [Collections.Generic.List[byte[]]]::new()
    $packIds = [string[]]@($groups.Keys)
    [Array]::Sort($packIds, [StringComparer]::Ordinal)
    foreach ($packId in $packIds) {
        $group = $groups[$packId]
        $candidates = [Collections.Generic.Dictionary[string, object]]::new([StringComparer]::Ordinal)
        $excluded = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
        foreach ($member in $group.members) {
            $counts = [Collections.Generic.Dictionary[string, int]]::new([StringComparer]::Ordinal)
            foreach ($observation in $member.observations) {
                $count = 0
                [void]$counts.TryGetValue($observation.settingId, [ref]$count)
                $counts[$observation.settingId] = $count + 1
            }
            foreach ($observation in $member.observations) {
                $id = $observation.settingId
                if ($excluded.Contains($id)) { continue }
                # Repeated instances cannot be expressed as one any-instance check.
                if ($counts[$id] -gt 1) {
                    [void]$excluded.Add($id)
                    [void]$candidates.Remove($id)
                    $skipped.Add([pscustomobject]@{ entry = $member.entry
                        reason = "Setting '$id' occurs more than once in policy '$($member.name)', so it was skipped for pack '$packId'." })
                    continue
                }
                $key = Get-IdsBuildKitValueKey $observation.valueType $observation.value
                if (-not $candidates.ContainsKey($id)) {
                    $candidate = [pscustomobject]@{ key = $key; observation = $observation; members = [Collections.Generic.List[object]]::new() }
                    $candidate.members.Add($member)
                    $candidates[$id] = $candidate
                } elseif (-not [StringComparer]::Ordinal.Equals($candidates[$id].key, $key)) {
                    $first = $candidates[$id].members[0]
                    [void]$excluded.Add($id)
                    [void]$candidates.Remove($id)
                    $skipped.Add([pscustomobject]@{ entry = $member.entry
                        reason = "Setting '$id' has different values in policies '$($first.name)' (archive entry '$($first.entry)') " +
                            "and '$($member.name)' (archive entry '$($member.entry)'), so it was skipped for pack '$packId'." })
                } else {
                    $candidates[$id].members.Add($member)
                }
            }
        }
        if ($candidates.Count -eq 0) { continue }

        $controlIds = [string[]]@($candidates.Keys)
        [Array]::Sort($controlIds, [StringComparer]::Ordinal)
        $used = [Collections.Generic.HashSet[int]]::new()
        $controls = [Collections.Generic.List[object]]::new()
        foreach ($id in $controlIds) {
            $candidate = $candidates[$id]
            $references = [Collections.Generic.List[string]]::new()
            foreach ($member in $candidate.members) {
                [void]$used.Add($member.index)
                $reference = "CIS build kit policy '$($member.name)' (archive entry '$($member.entry)')"
                if (-not $references.Contains($reference)) { $references.Add($reference) }
            }
            $reference = if ($references.Count -gt 5) {
                ($references.GetRange(0, 5) -join '; ') + "; and $($references.Count - 5) more"
            } else { $references -join '; ' }
            $title = $id
            if ($candidate.members[0].titles.ContainsKey($id)) { $title = $candidate.members[0].titles[$id] }
            $valueType = $candidate.observation.valueType
            $controls.Add([ordered]@{
                id = $id; title = $title; sourceIds = @('cis-build-kit'); reference = $reference
                applicability = [ordered]@{ osMin = $null; osMax = $null; enrollmentModes = @() }
                manualReason = $null
                mappings = @([ordered]@{
                    family = 'settingsCatalog'; policyTypes = @('deviceManagementConfigurationPolicy')
                    settingId = $id; property = $null; instancePath = $null; valueType = $valueType
                    operator = $(if ($valueType -cin @('stringSet', 'numberSet')) { 'setEquals' } else { 'eq' })
                    expected = $candidate.observation.value; caseSensitive = $true
                })
            })
        }

        $newest = $null
        $names = [Collections.Generic.List[string]]::new()
        $entries = [Collections.Generic.List[string]]::new()
        foreach ($member in $group.members) {
            if (-not $used.Contains($member.index)) { continue }
            if ($null -eq $newest -or $member.lastWriteTime -gt $newest) { $newest = $member.lastWriteTime }
            $names.Add($member.name)
            $entries.Add($member.entry)
        }
        $versions = Get-IdsBuildKitVersions $names.ToArray()
        if ($versions.Count -eq 0) { $versions = Get-IdsBuildKitVersions $entries.ToArray() }
        $frameworkVersion = if ($versions.Count -eq 1) { $versions[0] } else { 'Unknown (customer-supplied build kit)' }
        # The archive's stored wall-clock date, so every time zone gets the same pack.
        $retrievedOn = $newest.ToString('yyyy-MM-dd', [Globalization.CultureInfo]::InvariantCulture)
        $pack = [ordered]@{
            schemaVersion = 1L; id = $packId; version = '1.0.0'; framework = 'CIS'
            frameworkVersion = $frameworkVersion; classification = 'baseline'
            platform = $group.platform; profile = $group.profile
            sourceRevision = "CIS build kit archive SHA-256 $ArchiveSha256"
            sources = @([ordered]@{
                id = 'cis-build-kit'; url = 'https://workbench.cisecurity.org/'
                revision = "Archive SHA-256 $ArchiveSha256"; retrievedOn = $retrievedOn
            })
            coverage = [ordered]@{ inventory = 'partial'; totalSourceControls = $null }
            controls = $controls.ToArray()
        }
        $pack.version = '1.0.0+' + (Get-IdsBuildKitSha256 (ConvertTo-IdsBuildKitJsonBytes $pack)).Substring(0, 12)
        $bytes = ConvertTo-IdsBuildKitJsonBytes $pack
        if ($bytes.Length -gt 10MB) {
            $skipped.Add([pscustomobject]@{ entry = $packId; reason = "Generated pack '$packId' exceeds the 10 MiB pack limit." })
            continue
        }
        try { [void](Read-IdsBaselinePack -Bytes $bytes) } catch {
            $skipped.Add([pscustomobject]@{ entry = $packId; reason = "Generated pack '$packId' is invalid: $($_.Exception.Message)" })
            continue
        }
        $packs.Add($bytes)
    }
    return [pscustomobject]@{ packs = $packs.ToArray(); skipped = $skipped.ToArray() }
}
```

- [ ] **Step 6: Load the module in the app and the integration tests**

In `IntuneDocsStudio.ps1`, replace this text (about lines 57–58):

```powershell
foreach ($module in 'BaselinePacks', 'AssessmentCollection', 'AssessmentSettings', 'AssessmentRules', 'AssessmentReports', 'Assessment', 'AssessmentApi') {
    . (Join-Path $Root "lib\$module.ps1")
```

with:

```powershell
foreach ($module in 'BaselinePacks', 'AssessmentCollection', 'AssessmentSettings', 'BaselineArchive', 'AssessmentRules', 'AssessmentReports', 'Assessment', 'AssessmentApi') {
    . (Join-Path $Root "lib\$module.ps1")
```

In `tests\AssessmentIntegration.Tests.ps1`, replace this line (line 3):

```powershell
    foreach ($module in 'BaselinePacks', 'AssessmentCollection', 'AssessmentSettings', 'AssessmentRules', 'AssessmentReports', 'Assessment', 'AssessmentApi') {
```

with:

```powershell
    foreach ($module in 'BaselinePacks', 'AssessmentCollection', 'AssessmentSettings', 'BaselineArchive', 'AssessmentRules', 'AssessmentReports', 'Assessment', 'AssessmentApi') {
```

- [ ] **Step 7: Run the new tests and see them pass**

Run:

```powershell
Invoke-Pester .\tests\BaselineArchive.Tests.ps1, .\tests\Package.Tests.ps1 -Output Detailed
```

Expected: `Tests Passed: 32, Failed: 0, Skipped: 0, Inconclusive: 0, NotRun: 0`.

- [ ] **Step 8: Run the regression suite**

`tests\Runtime.Tests.ps1` starts `IntuneDocsStudio.ps1` in child processes, so
it checks the new load list. Run:

```powershell
Invoke-Pester .\tests\AssessmentIntegration.Tests.ps1, .\tests\Runtime.Tests.ps1, .\tests\AssessmentPacks.Tests.ps1, .\tests\AssessmentSettings.Tests.ps1, .\tests\AssessmentRules.Tests.ps1 -Output Detailed
pwsh -NoProfile -File .\scripts\Test-Repository.ps1; $LASTEXITCODE
git --no-pager diff --stat
git status --short
```

Expected:

- Pester shows `Tests Passed: 431, Failed: 0, Skipped: 0, Inconclusive: 0,
  NotRun: 0`.
- `Test-Repository.ps1` prints `Repository guidance and local policy checks
  passed.` and then `0`. It may first print `Pull request target policy: not
  applicable without pull request event context.`
- The diff stat lists exactly these 4 tracked files: `IntuneDocsStudio.ps1`,
  `tests/AssessmentIntegration.Tests.ps1`, `tests/Package.Tests.ps1` and
  `tests/TestHelpers/Assessment.ps1`. It shows `4 files changed, 35
  insertions(+), 2 deletions(-)`.
- `git status --short` also lists the 2 new files: `?? lib/BaselineArchive.ps1`
  and `?? tests/BaselineArchive.Tests.ps1`.

Optionally, check that no LF-only line endings slipped into the edited files:

```powershell
'lib\BaselineArchive.ps1','tests\BaselineArchive.Tests.ps1','IntuneDocsStudio.ps1','tests\TestHelpers\Assessment.ps1','tests\Package.Tests.ps1','tests\AssessmentIntegration.Tests.ps1' |
  ForEach-Object { '{0}: {1}' -f $_, ([regex]::Matches((Get-Content -Raw $_), '(?<!\r)\n')).Count }
```

Expected: every count is `0`.

- [ ] **Step 9: Commit**

Run:

```powershell
git add lib\BaselineArchive.ps1 IntuneDocsStudio.ps1 tests\BaselineArchive.Tests.ps1 tests\TestHelpers\Assessment.ps1 tests\Package.Tests.ps1 tests\AssessmentIntegration.Tests.ps1
git commit -m "feat: convert CIS build-kit Settings Catalog policies into rule packs" -m "Co-authored-by: Copilot App <223556219+Copilot@users.noreply.github.com>"
```

Expected: one commit with `6 files changed, 712 insertions(+), 2
deletions(-)`. If the opt-in pre-commit hook is installed, it passes.

### Task 3: In-memory build-kit archive reader

**Integrity review correction (2026-10-29):** the original Step 4 code below
is superseded by `lib\BaselineArchive.ps1`; do not copy its `Entry.Open()`
reader. Matching `ZipArchiveEntry.Length` does not prove integrity: .NET can
clamp deflated output and omit CRC checks. The implemented reader uses bounded
central/local metadata (including ZIP64 and signed/unsigned data descriptors),
unclamped stored/deflate streams, CRC-32, full actual-length comparison, and
bounded DEFLATE framing validation. `DeflateStream` alone also accepts a
missing final block or trailing compressed bytes. The framing pass counts
symbols without generating another decompressed copy. The mutable read budget
survives entry exceptions; PowerShell does not copy `[ref]` arguments back on
a failed managed invocation. The 64 MiB error remains outside the entry catch.
These corrections implement the spec's existing corrupt-entry rule, not a new
API. Task 4 must use the current source, not this historical implementation.

Add `ConvertFrom-IdsBaselineArchive` to `lib\BaselineArchive.ps1`. It reads a
ZIP archive from a byte array in memory and extracts nothing to disk. It
enforces the archive limits and passes schema-1 rule packs through. It collects
Settings Catalog policies for `ConvertTo-IdsBuildKitPacks` (Task 2) and
reports every skipped entry with a reason. This is the "Reading the archive"
and "Recognized content" sections of Part B of the design spec, together with
"Security and limits"
(`docs\superpowers\specs\2026-10-29-assessment-wizard-and-cis-zip-import-design.md`).
Task 4 calls the reader from the API.

Notes for this task:

- Line numbers refer to the files after Task 2. Find each edit by its exact
  current text.
- All three files use CRLF line endings. Keep CRLF. The repository has no
  `.gitattributes`; with `core.autocrlf=true`, Git normalizes on commit.
- `[IO.Compression.ZipArchive]` opens in `Read` mode over a read-only
  `[IO.MemoryStream]::new($Bytes, $false)`.
  - PowerShell 7 already loads `System.IO.Compression`. The
    `Add-Type -AssemblyName System.IO.Compression` call is harmless and keeps
    the dependency explicit.
- Archive-level errors fail the whole request. API status codes follow the
  catch order of `Invoke-IdsAssessmentRoute`.
  - Not a ZIP → `[ArgumentException]` 'The file is not a valid ZIP archive.'
    (HTTP 400). Opening damaged bytes throws `InvalidDataException`, which the
    API would map to HTTP 413, so the reader replaces it.
  - More than 1,000 entries → `[ArgumentException]` 'Archive entry limit
    exceeded (1,000 entries).'
  - More than 500 `.json` entries → `[ArgumentException]` 'Archive JSON entry
    limit exceeded (500 entries).'
  - An entry name with a leading `/` or `\`, a `:`, or a `..` segment (split on
    `/` and `\`) → `[ArgumentException]` "Archive entry names must be relative
    without ':' or '..' segments."
  - More than 64 MiB of JSON read in total → `[IO.InvalidDataException]`
    'Archive JSON read limit exceeded (64 MiB).' (HTTP 413). This check sits
    outside the per-entry `catch`, so it is never reported as an unreadable
    entry.
- Entry handling never fails the archive:
  - Names ending in `/` or `\` are directories and are ignored silently.
  - A `.zip` entry is skipped: "Nested ZIP archives are not opened; extract
    and upload the inner ZIP."
  - Other non-`.json` files are counted in `ignored`.
  - These entries are skipped with "Could not be read (encrypted, corrupt or
    unsupported compression).":
    - an encrypted entry (`IsEncrypted`, read through `PSObject.Properties`);
    - a read error (`InvalidDataException`, `IOException`,
      `NotSupportedException` or `InvalidOperationException`);
    - an entry whose data length differs from its declared `Length`.
  - A declared `Length` over 10 MiB, or more than 10 MiB actually read, gives
    "JSON entry exceeds the 10 MiB limit." At most 10 MiB + 1 bytes are read
    per entry, and every byte read counts toward the 64 MiB budget.
  - Text is decoded with strict decoders: UTF-8 with or without BOM, or UTF-16
    LE/BE with BOM. Anything else gives "Not valid UTF-8 or UTF-16 text."
  - JSON is parsed by `[Text.Json.JsonDocument]` with `MaxDepth = 64`.
    - A parse failure gives "Invalid JSON or nesting deeper than 64 levels."
    - `ConvertFrom-IdsPackJsonElement` errors (duplicate members, strings over
      32,768 characters) give "Invalid JSON: <message>".
  - A top-level object with `schemaVersion` is re-encoded as UTF-8 without BOM
    and validated with `Read-IdsBaselinePack`. Valid packs pass through.
    Invalid ones are skipped with "Invalid rule pack: <message>".
  - These shapes are collected for `ConvertTo-IdsBuildKitPacks`, with the
    entry's `LastWriteTime`:
    - an object with `settings`;
    - a nonempty array whose items are all objects with `settings`;
    - `{ "value": [ ... ] }` with the same rule.
  - Anything else, including `[]` and `{ "value": [] }`, is skipped with "Not a
    Settings Catalog policy or rule pack."
- Result order:
  - `packs` holds the schema-1 packs in entry order, then the converted packs
    in pack-id order;
  - `skipped` holds the entry skips, then the converter skips.
- Test helpers:
  - `New-IdsTestZipBytes` builds a ZIP in memory with `ZipArchiveMode` `Create`.
    String values are written as UTF-8 without BOM and byte arrays as-is.
    `$null` creates an empty entry; use it for directory names ending in `/`.
  - .NET cannot create encrypted entries. `Edit-IdsTestZipFirstEntry` patches
    the first entry's local and central headers instead:
    - the encryption flag;
    - compression method 14, which is unsupported;
    - `0xFF` over the compressed data;
    - or a different declared size.
- The 64 MiB budget tests use seven 10,000,000-byte entries of `0xFF`. Each is
  under the 10 MiB entry limit, compresses well and is not valid UTF-8. No
  entry reaches the JSON parser, so the test stays fast.

**Files:**

- Modify: `lib\BaselineArchive.ps1` (new functions after line 351, the end of
  `ConvertTo-IdsBuildKitPacks`)
- Test: `tests\BaselineArchive.Tests.ps1` (a new `Describe` after line 326)
- Test: `tests\TestHelpers\Assessment.ps1` (new ZIP builders after line 92)

**Interfaces:**

- Consumes:
  - From Task 1: `Import-IdsBaselinePackSet -Packs <byte[][]> -ImportedRoot
    <string>` → one `[pscustomobject]@{ pack; added }` per unique pack. Only
    the idempotence test uses it.
  - From Task 2:
    - `ConvertTo-IdsBuildKitPacks -Policies <object[]> -ArchiveSha256
      <string>` → `[pscustomobject]@{ packs = <byte[][]>; skipped = <object[]
      of { entry; reason }> }`. Each input item is `[pscustomobject]@{ entry;
      policy; lastWriteTime = <[DateTimeOffset]> }`.
    - `Get-IdsBuildKitSha256([byte[]]$Bytes)` → 64 lowercase hex characters.
    - The test helper `New-IdsTestBuildKitPolicy([string]$Name = 'Synthetic L1
      policy', [string]$Platforms = 'windows10', [object[]]$Instances = @(),
      [object[]]$Definitions = @())`.
    - The top-level `BeforeAll` of `tests\BaselineArchive.Tests.ps1`, which
      loads the modules.
  - Existing:
    - `ConvertFrom-IdsPackJsonElement($Element, [string]$Path = '$')`;
    - `Read-IdsBaselinePack -Bytes <byte[]>`;
    - the test helpers `New-IdsTestSettingInstance([string]$Kind = 'simple',
      [string]$Id = 'synthetic.setting', $Value = 0)` and
      `New-IdsTestPackBytes([string]$Platform = 'windows11')`.
- Produces:
  - `ConvertFrom-IdsBaselineArchive -Bytes <byte[]>` (mandatory; may be empty)
    → `[pscustomobject]@{ packs = <byte[][]>; skipped = <object[] of
    [pscustomobject]@{ entry; reason }>; ignored = <int>; sha256 = <64
    lowercase hex of the archive bytes> }`.
    - It throws only `[ArgumentException]` (HTTP 400) or
      `[IO.InvalidDataException]` (HTTP 413), with the messages above.
  - Internal helpers:
    - `Initialize-IdsBaselineArchiveReader` loads the dependency-free managed
      integrity helper once. Its bounded `ReadDirectory` returns entry metadata.
    - `Read-IdsBaselineArchiveEntry($Bytes, $Entry, $Budget)` → `byte[]`, at
      most 10 MiB + 1 bytes. `$Entry` is validated raw-directory metadata, not
      a `ZipArchiveEntry`. `$Budget` is the shared `@{ read = 0L }`, updated
      even when CRC/length/framing validation subsequently fails.
    - `ConvertFrom-IdsBaselineArchiveText([byte[]]$Bytes)` → string.
    - `Get-IdsBaselineArchivePolicies($Value)` → an array of policies, or
      `$null`.
  - Test helpers in `tests\TestHelpers\Assessment.ps1`. Task 4 uses
    `New-IdsTestZipBytes`.
    - `New-IdsTestZipBytes([Collections.IDictionary]$Entries,
      [string]$CompressionLevel = 'Optimal', [DateTimeOffset]$LastWriteTime =
      2026-10-01 12:00 +00:00)` → `byte[]`. `$Entries` is mandatory.
    - `Edit-IdsTestZipFirstEntry([byte[]]$Bytes, [string]$Change,
      [uint32]$Length = 0)` → `byte[]`. `$Change` is one of `Encrypted`,
      `UnsupportedCompression`, `CorruptData` or `DeclaredLength`.

- [ ] **Step 1: Add the ZIP test builders**

Append this code at the end of `tests\TestHelpers\Assessment.ps1`, after the
closing `}` of `New-IdsTestBuildKitItem` (about line 92, added in Task 2). Leave
one blank line before it.

```powershell
function New-IdsTestZipBytes {
    param([Parameter(Mandatory)][Collections.IDictionary]$Entries, [string]$CompressionLevel = 'Optimal',
        [DateTimeOffset]$LastWriteTime = [DateTimeOffset]::new(2026, 10, 1, 12, 0, 0, [TimeSpan]::Zero))
    Add-Type -AssemblyName System.IO.Compression
    $stream = [IO.MemoryStream]::new()
    try {
        $archive = [IO.Compression.ZipArchive]::new($stream, [IO.Compression.ZipArchiveMode]::Create, $true)
        try {
            foreach ($pair in $Entries.GetEnumerator()) {
                $entry = $archive.CreateEntry([string]$pair.Key, [IO.Compression.CompressionLevel]$CompressionLevel)
                $entry.LastWriteTime = $LastWriteTime
                if ($null -eq $pair.Value) { continue }
                $bytes = $pair.Value
                if ($bytes -isnot [byte[]]) { $bytes = [Text.UTF8Encoding]::new($false).GetBytes([string]$pair.Value) }
                $content = $entry.Open()
                try { $content.Write($bytes, 0, $bytes.Length) } finally { $content.Dispose() }
            }
        } finally { $archive.Dispose() }
        return ,($stream.ToArray())
    } finally { $stream.Dispose() }
}

function Edit-IdsTestZipFirstEntry {
    param([Parameter(Mandatory)][byte[]]$Bytes,
        [Parameter(Mandatory)][ValidateSet('Encrypted', 'UnsupportedCompression', 'CorruptData', 'DeclaredLength')][string]$Change,
        [uint32]$Length = 0)
    # Archives from New-IdsTestZipBytes have no comment, so the central
    # directory offset is the 4-byte field 6 bytes before the end, and the
    # first local header starts at offset 0.
    $copy = [byte[]]$Bytes.Clone()
    $central = [BitConverter]::ToInt32($copy, $copy.Length - 6)
    switch ($Change) {
        Encrypted { $copy[6] = $copy[6] -bor 1; $copy[$central + 8] = $copy[$central + 8] -bor 1 }
        UnsupportedCompression { $copy[8] = 14; $copy[$central + 10] = 14 }
        CorruptData {
            $start = 30 + [BitConverter]::ToUInt16($copy, 26) + [BitConverter]::ToUInt16($copy, 28)
            $end = $start + [BitConverter]::ToInt32($copy, $central + 20)
            for ($index = $start; $index -lt $end; $index++) { $copy[$index] = 0xFF }
        }
        DeclaredLength {
            [BitConverter]::GetBytes($Length).CopyTo($copy, 22)
            [BitConverter]::GetBytes($Length).CopyTo($copy, $central + 24)
        }
    }
    return ,$copy
}
```

- [ ] **Step 2: Append the archive reader tests**

Append this code at the end of `tests\BaselineArchive.Tests.ps1`, after the
closing `}` of `Describe 'Build-kit Settings Catalog conversion'` (about line
326). Leave one blank line before it.

```powershell
Describe 'CIS build-kit archive reader' {
    BeforeAll {
        function New-TestPolicyJson([string]$Name = 'Synthetic L1 policy', [string]$Id = 'syn.archive', $Value = 1) {
            $policy = New-IdsTestBuildKitPolicy -Name $Name -Instances @(New-IdsTestSettingInstance -Id $Id -Value @{ value = $Value })
            return ConvertTo-Json -InputObject $policy -Depth 64 -Compress
        }
        function Get-TestSkipLines($Result) { @($Result.skipped | ForEach-Object { "$($_.entry) => $($_.reason)" }) }
        $unreadable = 'Could not be read (encrypted, corrupt or unsupported compression).'
    }

    It 'rejects <label> bytes as an invalid ZIP archive' -ForEach @(
        @{ label = 'text'; bytes = [Text.Encoding]::UTF8.GetBytes('not a zip archive') }
        @{ label = 'empty'; bytes = [byte[]]::new(0) }
    ) {
        { ConvertFrom-IdsBaselineArchive -Bytes $bytes } |
            Should -Throw -ExceptionType ([ArgumentException]) -ExpectedMessage 'The file is not a valid ZIP archive.'
    }

    It 'rejects archives over the <limit> limit' -ForEach @(
        @{ limit = 'entry'; count = 1001; extension = 'txt'; message = 'Archive entry limit exceeded (1,000 entries).' }
        @{ limit = 'JSON entry'; count = 501; extension = 'json'; message = 'Archive JSON entry limit exceeded (500 entries).' }
    ) {
        $entries = [ordered]@{}
        for ($index = 0; $index -lt $count; $index++) { $entries["kit/entry$index.$extension"] = '{}' }
        $zip = New-IdsTestZipBytes $entries
        { ConvertFrom-IdsBaselineArchive -Bytes $zip } |
            Should -Throw -ExceptionType ([ArgumentException]) -ExpectedMessage $message
    }

    It 'accepts archives at the entry limits' {
        $entries = [ordered]@{}
        for ($index = 0; $index -lt 500; $index++) {
            $entries["kit/entry$index.json"] = '{}'
            $entries["kit/entry$index.txt"] = 'synthetic'
        }
        $result = ConvertFrom-IdsBaselineArchive -Bytes (New-IdsTestZipBytes $entries)
        $result.packs.Count | Should -Be 0
        $result.skipped.Count | Should -Be 500
        $result.skipped[0].reason | Should -BeExactly 'Not a Settings Catalog policy or rule pack.'
        $result.ignored | Should -Be 500
    }

    It 'rejects the whole archive for the unsafe entry name <name>' -ForEach @(
        @{ name = '../escape.json' }
        @{ name = 'kit/../escape.json' }
        @{ name = 'kit\..\escape.json' }
        @{ name = 'kit/..' }
        @{ name = '/rooted.json' }
        @{ name = '\rooted.json' }
        @{ name = 'C:drive.json' }
        @{ name = 'kit/policy.json:stream' }
    ) {
        $zip = New-IdsTestZipBytes ([ordered]@{ 'kit/safe.json' = (New-TestPolicyJson); $name = '{}' })
        { ConvertFrom-IdsBaselineArchive -Bytes $zip } |
            Should -Throw -ExceptionType ([ArgumentException]) -ExpectedMessage "Archive entry names must be relative without ':' or '..' segments."
    }

    It 'ignores directories, counts other files and skips nested archives' {
        $zip = New-IdsTestZipBytes ([ordered]@{
            'kit/' = $null
            'kit/L1/' = $null
            'kit/readme.pdf' = 'synthetic'
            'kit/settings.xlsx' = 'synthetic'
            'kit/policy.xml' = '<policy />'
            'kit/inner.ZIP' = (New-IdsTestZipBytes ([ordered]@{ 'inner.json' = (New-TestPolicyJson) }))
            'kit/L1/policy.json' = (New-TestPolicyJson)
        })
        $result = ConvertFrom-IdsBaselineArchive -Bytes $zip
        $result.ignored | Should -Be 3
        (Get-TestSkipLines $result) | Should -BeExactly 'kit/inner.ZIP => Nested ZIP archives are not opened; extract and upload the inner ZIP.'
        $result.packs.Count | Should -Be 1
        (Read-IdsBaselinePack -Bytes $result.packs[0]).controls[0].reference |
            Should -BeExactly "CIS build kit policy 'Synthetic L1 policy' (archive entry 'kit/L1/policy.json')"
    }

    It 'skips an entry that is <label>' -ForEach @(
        @{ label = 'encrypted'; change = 'Encrypted' }
        @{ label = 'stored with an unsupported compression method'; change = 'UnsupportedCompression' }
        @{ label = 'corrupt'; change = 'CorruptData' }
        @{ label = 'shorter than its declared size'; change = 'DeclaredLength' }
    ) {
        $zip = New-IdsTestZipBytes ([ordered]@{
            'kit/broken.json' = (New-TestPolicyJson -Id 'syn.broken')
            'kit/good.json' = (New-TestPolicyJson -Id 'syn.good')
        })
        $result = ConvertFrom-IdsBaselineArchive -Bytes (Edit-IdsTestZipFirstEntry $zip $change -Length 5000)
        (Get-TestSkipLines $result) | Should -BeExactly "kit/broken.json => $unreadable"
        $result.packs.Count | Should -Be 1
        (@((Read-IdsBaselinePack -Bytes $result.packs[0]).controls.id) -join ',') | Should -BeExactly 'syn.good'
    }

    It 'skips JSON entries over 10 MiB by <label> size' -ForEach @(
        @{ label = 'declared'; level = 'Optimal'; declared = 0 }
        @{ label = 'actual'; level = 'NoCompression'; declared = 100 }
    ) {
        $zip = New-IdsTestZipBytes ([ordered]@{ 'kit/large.json' = [byte[]]::new(10MB + 1) }) -CompressionLevel $level
        if ($declared) { $zip = Edit-IdsTestZipFirstEntry $zip DeclaredLength -Length $declared }
        $result = ConvertFrom-IdsBaselineArchive -Bytes $zip
        $result.packs.Count | Should -Be 0
        (Get-TestSkipLines $result) | Should -BeExactly 'kit/large.json => JSON entry exceeds the 10 MiB limit.'
    }

    It 'stops with an InvalidDataException after more than 64 MiB of JSON' {
        $entries = [ordered]@{}
        # 0xFF bytes are not valid UTF-8, so no entry reaches the JSON parser.
        $filler = [byte[]]::new(10000000)
        [Array]::Fill($filler, [byte]255)
        for ($index = 0; $index -lt 7; $index++) { $entries["kit/filler$index.json"] = $filler }
        $zip = New-IdsTestZipBytes $entries
        { ConvertFrom-IdsBaselineArchive -Bytes $zip } |
            Should -Throw -ExceptionType ([IO.InvalidDataException]) -ExpectedMessage 'Archive JSON read limit exceeded (64 MiB).'
    }

    It 'decodes <label> JSON entries' -ForEach @(
        @{ label = 'UTF-8 without BOM'; encoding = [Text.UTF8Encoding]::new($false); bom = $false }
        @{ label = 'UTF-8 with BOM'; encoding = [Text.UTF8Encoding]::new($true); bom = $true }
        @{ label = 'UTF-16 LE with BOM'; encoding = [Text.UnicodeEncoding]::new($false, $true); bom = $true }
        @{ label = 'UTF-16 BE with BOM'; encoding = [Text.UnicodeEncoding]::new($true, $true); bom = $true }
    ) {
        $value = "Caf$([char]0xE9) $([char]0x2713) $([char]::ConvertFromUtf32(0x1F600))"
        [byte[]]$bytes = $encoding.GetBytes((New-TestPolicyJson -Id 'syn.text' -Value $value))
        if ($bom) { [byte[]]$bytes = $encoding.GetPreamble() + $bytes }
        $result = ConvertFrom-IdsBaselineArchive -Bytes (New-IdsTestZipBytes ([ordered]@{ 'kit/text.json' = $bytes }))
        $result.skipped.Count | Should -Be 0
        $result.packs.Count | Should -Be 1
        (Read-IdsBaselinePack -Bytes $result.packs[0]).controls[0].mappings[0].expected | Should -BeExactly $value
    }

    It 'skips entries that are not valid text, JSON, rule packs or Settings Catalog policies' {
        $zip = New-IdsTestZipBytes ([ordered]@{
            'kit/latin1.json' = [byte[]](0x7B, 0x22, 0xE9, 0x22, 0x7D)
            'kit/odd.json' = [byte[]](0xFF, 0xFE, 0x7B)
            'kit/invalid.json' = '{"name":'
            'kit/deep.json' = ('[' * 65) + (']' * 65)
            'kit/duplicate.json' = '{"name":"Synthetic L1 a","Name":"Synthetic L1 b","settings":[]}'
            'kit/long.json' = '{"name":"' + ('x' * 40000) + '","settings":[]}'
            'kit/readme.json' = '{"title":"Synthetic readme"}'
            'kit/empty.json' = '[]'
            'kit/mixed.json' = '[{"settings":[]},{"title":"Synthetic"}]'
            'kit/list.json' = '{"value":[]}'
            'kit/pack.json' = '{"schemaVersion":1}'
        })
        $result = ConvertFrom-IdsBaselineArchive -Bytes $zip
        $result.packs.Count | Should -Be 0
        $result.ignored | Should -Be 0
        $lines = Get-TestSkipLines $result
        $expected = @(
            'kit/latin1.json => Not valid UTF-8 or UTF-16 text.'
            'kit/odd.json => Not valid UTF-8 or UTF-16 text.'
            'kit/invalid.json => Invalid JSON or nesting deeper than 64 levels.'
            'kit/deep.json => Invalid JSON or nesting deeper than 64 levels.'
            'kit/duplicate.json => Invalid JSON: Pack JSON duplicate member at $.'
            'kit/long.json => Invalid JSON: Pack string limit (32768 characters) at $.name.'
            'kit/readme.json => Not a Settings Catalog policy or rule pack.'
            'kit/empty.json => Not a Settings Catalog policy or rule pack.'
            'kit/mixed.json => Not a Settings Catalog policy or rule pack.'
            'kit/list.json => Not a Settings Catalog policy or rule pack.'
            'kit/pack.json => Invalid rule pack: *'
        )
        $lines.Count | Should -Be $expected.Count
        for ($index = 0; $index -lt $expected.Count; $index++) { $lines[$index] | Should -BeLike $expected[$index] }
    }

    It 'converts single policies, policy arrays and value lists' {
        $first = New-TestPolicyJson -Name 'Synthetic L1 first' -Id 'syn.first'
        $second = New-TestPolicyJson -Name 'Synthetic L1 second' -Id 'syn.second'
        $listed = New-TestPolicyJson -Name 'Synthetic L1 listed' -Id 'syn.listed'
        $zip = New-IdsTestZipBytes ([ordered]@{
            'kit/single.json' = (New-TestPolicyJson -Name 'Synthetic L1 single' -Id 'syn.single')
            'kit/array.json' = "[$first,$second]"
            'kit/list.json' = "{""@odata.context"":""synthetic"",""value"":[$listed]}"
        })
        $result = ConvertFrom-IdsBaselineArchive -Bytes $zip
        $result.skipped.Count | Should -Be 0
        $result.packs.Count | Should -Be 1
        $pack = Read-IdsBaselinePack -Bytes $result.packs[0]
        (@($pack.controls | ForEach-Object { "$($_.id) <= $($_.reference)" }) -join "`n") | Should -BeExactly (@(
            "syn.first <= CIS build kit policy 'Synthetic L1 first' (archive entry 'kit/array.json')"
            "syn.listed <= CIS build kit policy 'Synthetic L1 listed' (archive entry 'kit/list.json')"
            "syn.second <= CIS build kit policy 'Synthetic L1 second' (archive entry 'kit/array.json')"
            "syn.single <= CIS build kit policy 'Synthetic L1 single' (archive entry 'kit/single.json')"
        ) -join "`n")
    }

    It 'passes schema-1 rule packs through and skips invalid ones' {
        $packBytes = New-IdsTestPackBytes
        [byte[]]$withBom = [byte[]](0xEF, 0xBB, 0xBF) + $packBytes
        $zip = New-IdsTestZipBytes ([ordered]@{
            'packs/synthetic.json' = $packBytes
            'packs/synthetic-bom.json' = $withBom
            'packs/invalid.json' = '{"schemaVersion":1,"id":"synthetic-invalid"}'
        })
        $result = ConvertFrom-IdsBaselineArchive -Bytes $zip
        $result.packs.Count | Should -Be 2
        [Convert]::ToBase64String($result.packs[0]) | Should -BeExactly ([Convert]::ToBase64String($packBytes))
        [Convert]::ToBase64String($result.packs[1]) | Should -BeExactly ([Convert]::ToBase64String($packBytes))
        (Get-TestSkipLines $result) | Should -BeLike 'packs/invalid.json => Invalid rule pack: *'
    }

    It 'converts mixed archives deterministically and imports them idempotently' {
        $secret = New-IdsTestBuildKitPolicy -Name 'Synthetic L1 secret' -Instances @(
            New-IdsTestSettingInstance -Id 'syn.secret' -Value @{
                '@odata.type' = '#microsoft.graph.deviceManagementConfigurationSecretSettingValue'; value = 'synthetic-hidden-value' })
        $zip = New-IdsTestZipBytes ([ordered]@{
            'kit/readme.txt' = 'synthetic'
            'kit/notes.json' = '{"title":"Synthetic notes"}'
            'kit/L2/policy.json' = (New-TestPolicyJson -Name 'Synthetic L2 policy' -Id 'syn.level2')
            'packs/synthetic.json' = (New-IdsTestPackBytes)
            'kit/L1/policy.json' = (New-TestPolicyJson -Name 'Synthetic L1 policy' -Id 'syn.level1')
            'kit/L1/secret.json' = (ConvertTo-Json -InputObject $secret -Depth 64 -Compress)
        }) -LastWriteTime ([DateTimeOffset]::new(2026, 10, 3, 23, 30, 0, [TimeSpan]::FromHours(-8)))
        $first = ConvertFrom-IdsBaselineArchive -Bytes $zip
        $second = ConvertFrom-IdsBaselineArchive -Bytes $zip
        $first.sha256 | Should -BeExactly ((Get-FileHash -InputStream ([IO.MemoryStream]::new($zip)) -Algorithm SHA256).Hash.ToLowerInvariant())
        $first.ignored | Should -Be 1
        (@($first.packs | ForEach-Object { (Read-IdsBaselinePack -Bytes $_).id }) -join ',') |
            Should -BeExactly 'synthetic-pack,cis.windows11.l1,cis.windows11.l2'
        ((Get-TestSkipLines $first) -join "`n") | Should -BeExactly (@(
            'kit/notes.json => Not a Settings Catalog policy or rule pack.'
            "kit/L1/secret.json => Setting 'syn.secret' in policy 'Synthetic L1 secret' is secret and was not converted."
        ) -join "`n")
        $level1 = Read-IdsBaselinePack -Bytes $first.packs[1]
        $level1.sources[0].retrievedOn | Should -BeExactly '2026-10-03'
        $level1.sources[0].revision | Should -BeExactly "Archive SHA-256 $($first.sha256)"
        $second.packs.Count | Should -Be $first.packs.Count
        for ($index = 0; $index -lt $first.packs.Count; $index++) {
            [Convert]::ToBase64String($second.packs[$index]) | Should -BeExactly ([Convert]::ToBase64String($first.packs[$index]))
        }
        $root = Join-Path $TestDrive 'imported'
        (@(Import-IdsBaselinePackSet -Packs $first.packs -ImportedRoot $root).added -join ',') | Should -BeExactly 'True,True,True'
        (@(Import-IdsBaselinePackSet -Packs $second.packs -ImportedRoot $root).added -join ',') | Should -BeExactly 'False,False,False'
        @(Get-ChildItem -LiteralPath $root -Filter '*.json').Count | Should -Be 3
    }
}
```

- [ ] **Step 3: Run the new tests and see them fail**

Run:

```powershell
Invoke-Pester .\tests\BaselineArchive.Tests.ps1 -Output Detailed
```

Expected: `Tests Passed: 15, Failed: 29, Skipped: 0, Inconclusive: 0, NotRun: 0`.
The failing tests are:

- 12 cases that expect an `[ArgumentException]`. They fail with, for example,
  `Expected an exception with type [System.ArgumentException] and message like
  'The file is not a valid ZIP archive.' to be thrown, but the exception type
  was [System.Management.Automation.CommandNotFoundException] ...`. The cases
  are:
  - `rejects <label> bytes as an invalid ZIP archive` (2 cases);
  - `rejects archives over the <limit> limit` (2 cases);
  - `rejects the whole archive for the unsafe entry name <name>` (8 cases).
- `stops with an InvalidDataException after more than 64 MiB of JSON`, which
  fails the same way with `[System.IO.InvalidDataException]`.
- The other 16 new cases, with `The term 'ConvertFrom-IdsBaselineArchive' is
  not recognized as a name of a cmdlet, function, script file, or executable
  program.`

The 15 passing tests are Task 2's converter tests.

- [ ] **Step 4: Add the archive reader**

Append this code at the end of `lib\BaselineArchive.ps1`, after the closing `}`
of `ConvertTo-IdsBuildKitPacks` (about line 351). Leave one blank line before
it.

```powershell
function Read-IdsBaselineArchiveEntry {
    param($Entry, $Budget)
    # Reads at most 10 MiB + 1 bytes, so entries that understate their size
    # stay bounded; every byte read counts toward the archive budget.
    $limit = 10MB + 1
    $buffer = [byte[]]::new(81920)
    $content = [IO.MemoryStream]::new()
    $source = $Entry.Open()
    try {
        while ($content.Length -lt $limit -and $Budget.read -le 64MB) {
            $count = $source.Read($buffer, 0, [int][Math]::Min([long]$buffer.Length, $limit - $content.Length))
            if ($count -le 0) { break }
            $content.Write($buffer, 0, $count)
            $Budget.read += $count
        }
        return ,($content.ToArray())
    } finally {
        $source.Dispose()
        $content.Dispose()
    }
}

function ConvertFrom-IdsBaselineArchiveText {
    param([byte[]]$Bytes)
    if ($Bytes.Length -ge 3 -and $Bytes[0] -eq 0xEF -and $Bytes[1] -eq 0xBB -and $Bytes[2] -eq 0xBF) {
        return [Text.UTF8Encoding]::new($false, $true).GetString($Bytes, 3, $Bytes.Length - 3)
    }
    if ($Bytes.Length -ge 2 -and $Bytes[0] -eq 0xFF -and $Bytes[1] -eq 0xFE) {
        return [Text.UnicodeEncoding]::new($false, $false, $true).GetString($Bytes, 2, $Bytes.Length - 2)
    }
    if ($Bytes.Length -ge 2 -and $Bytes[0] -eq 0xFE -and $Bytes[1] -eq 0xFF) {
        return [Text.UnicodeEncoding]::new($true, $false, $true).GetString($Bytes, 2, $Bytes.Length - 2)
    }
    return [Text.UTF8Encoding]::new($false, $true).GetString($Bytes)
}

function Get-IdsBaselineArchivePolicies {
    param($Value)
    if ($Value -is [Collections.IDictionary] -and $Value.Contains('settings')) { return ,@(, $Value) }
    $list = $Value
    if ($Value -is [Collections.IDictionary] -and $Value.Contains('value')) { $list = $Value['value'] }
    if ($list -isnot [Collections.IList] -or $list.Count -eq 0) { return $null }
    foreach ($item in $list) {
        if ($item -isnot [Collections.IDictionary] -or -not $item.Contains('settings')) { return $null }
    }
    return ,@($list)
}

function ConvertFrom-IdsBaselineArchive {
    param([Parameter(Mandatory)][AllowEmptyCollection()][byte[]]$Bytes)
    Add-Type -AssemblyName System.IO.Compression
    $sha256 = Get-IdsBuildKitSha256 $Bytes
    $packs = [Collections.Generic.List[byte[]]]::new()
    $skipped = [Collections.Generic.List[object]]::new()
    $policies = [Collections.Generic.List[object]]::new()
    $ignored = 0
    $budget = @{ read = 0L }
    $unreadable = 'Could not be read (encrypted, corrupt or unsupported compression).'
    $stream = [IO.MemoryStream]::new($Bytes, $false)
    $archive = $null
    try {
        try {
            $archive = [IO.Compression.ZipArchive]::new($stream, [IO.Compression.ZipArchiveMode]::Read, $true)
            $entries = @($archive.Entries)
        } catch {
            # ZipArchive reports damage as InvalidDataException, which the API maps to 413.
            throw [ArgumentException]::new('The file is not a valid ZIP archive.')
        }
        if ($entries.Count -gt 1000) { throw [ArgumentException]::new('Archive entry limit exceeded (1,000 entries).') }
        $jsonCount = 0
        foreach ($entry in $entries) {
            $name = $entry.FullName
            if ($name.StartsWith('/') -or $name.StartsWith('\') -or $name.Contains(':') -or
                (($name -split '[/\\]') -contains '..')) {
                throw [ArgumentException]::new("Archive entry names must be relative without ':' or '..' segments.")
            }
            if ($name.EndsWith('.json', [StringComparison]::OrdinalIgnoreCase)) { $jsonCount++ }
        }
        if ($jsonCount -gt 500) { throw [ArgumentException]::new('Archive JSON entry limit exceeded (500 entries).') }

        foreach ($entry in $entries) {
            $name = $entry.FullName
            if ($name.EndsWith('/') -or $name.EndsWith('\')) { continue }
            if ($name.EndsWith('.zip', [StringComparison]::OrdinalIgnoreCase)) {
                $skipped.Add([pscustomobject]@{ entry = $name; reason = 'Nested ZIP archives are not opened; extract and upload the inner ZIP.' })
                continue
            }
            if (-not $name.EndsWith('.json', [StringComparison]::OrdinalIgnoreCase)) { $ignored++; continue }
            $encrypted = $entry.PSObject.Properties['IsEncrypted']
            if ($encrypted -and $encrypted.Value) {
                $skipped.Add([pscustomobject]@{ entry = $name; reason = $unreadable })
                continue
            }
            if ($entry.Length -gt 10MB) {
                $skipped.Add([pscustomobject]@{ entry = $name; reason = 'JSON entry exceeds the 10 MiB limit.' })
                continue
            }
            $content = $null
            try { $content = Read-IdsBaselineArchiveEntry $entry $budget }
            catch [IO.InvalidDataException], [IO.IOException], [NotSupportedException], [InvalidOperationException] { $content = $null }
            # Outside the entry catch: the budget fails the whole request.
            if ($budget.read -gt 64MB) { throw [IO.InvalidDataException]::new('Archive JSON read limit exceeded (64 MiB).') }
            if ($null -eq $content) {
                $skipped.Add([pscustomobject]@{ entry = $name; reason = $unreadable })
                continue
            }
            if ($content.Length -gt 10MB) {
                $skipped.Add([pscustomobject]@{ entry = $name; reason = 'JSON entry exceeds the 10 MiB limit.' })
                continue
            }
            if ($content.Length -ne $entry.Length) {
                $skipped.Add([pscustomobject]@{ entry = $name; reason = $unreadable })
                continue
            }
            try { $text = ConvertFrom-IdsBaselineArchiveText $content } catch {
                $skipped.Add([pscustomobject]@{ entry = $name; reason = 'Not valid UTF-8 or UTF-16 text.' })
                continue
            }
            $options = [System.Text.Json.JsonDocumentOptions]::new()
            $options.MaxDepth = 64
            try { $document = [System.Text.Json.JsonDocument]::Parse($text, $options) } catch {
                $skipped.Add([pscustomobject]@{ entry = $name; reason = 'Invalid JSON or nesting deeper than 64 levels.' })
                continue
            }
            try { $value = ConvertFrom-IdsPackJsonElement $document.RootElement } catch {
                $skipped.Add([pscustomobject]@{ entry = $name; reason = "Invalid JSON: $($_.Exception.Message)" })
                continue
            } finally { $document.Dispose() }
            if ($value -is [Collections.IDictionary] -and $value.Contains('schemaVersion')) {
                $packBytes = [Text.UTF8Encoding]::new($false).GetBytes($text)
                try { [void](Read-IdsBaselinePack -Bytes $packBytes) } catch {
                    $skipped.Add([pscustomobject]@{ entry = $name; reason = "Invalid rule pack: $($_.Exception.Message)" })
                    continue
                }
                $packs.Add($packBytes)
                continue
            }
            $found = Get-IdsBaselineArchivePolicies $value
            if ($null -eq $found) {
                $skipped.Add([pscustomobject]@{ entry = $name; reason = 'Not a Settings Catalog policy or rule pack.' })
                continue
            }
            foreach ($policy in $found) {
                $policies.Add([pscustomobject]@{ entry = $name; policy = $policy; lastWriteTime = $entry.LastWriteTime })
            }
        }
    } finally {
        if ($archive) { $archive.Dispose() }
        $stream.Dispose()
    }
    $converted = ConvertTo-IdsBuildKitPacks -Policies $policies.ToArray() -ArchiveSha256 $sha256
    foreach ($pack in $converted.packs) { $packs.Add($pack) }
    foreach ($item in $converted.skipped) { $skipped.Add($item) }
    return [pscustomobject]@{ packs = $packs.ToArray(); skipped = $skipped.ToArray(); ignored = $ignored; sha256 = $sha256 }
}
```

- [ ] **Step 5: Run the new tests and see them pass**

Run:

```powershell
Invoke-Pester .\tests\BaselineArchive.Tests.ps1 -Output Detailed
```

Expected: `Tests Passed: 44, Failed: 0, Skipped: 0, Inconclusive: 0, NotRun: 0`.

- [ ] **Step 6: Run the regression suite**

Run:

```powershell
Invoke-Pester .\tests\Package.Tests.ps1, .\tests\AssessmentPacks.Tests.ps1, .\tests\AssessmentIntegration.Tests.ps1 -Output Detailed
pwsh -NoProfile -File .\scripts\Test-Repository.ps1; $LASTEXITCODE
git --no-pager diff --stat
```

Expected:

- Pester shows `Tests Passed: 186, Failed: 0, Skipped: 0, Inconclusive: 0,
  NotRun: 0`: 17 package tests, 138 pack tests and 31 integration tests.
- `Test-Repository.ps1` prints `Repository guidance and local policy checks
  passed.` and then `0`. It may first print `Pull request target policy: not
  applicable without pull request event context.`
- The diff stat lists exactly these 3 files: `lib/BaselineArchive.ps1`,
  `tests/BaselineArchive.Tests.ps1` and `tests/TestHelpers/Assessment.ps1`. It
  shows `3 files changed, 438 insertions(+)`.

Optionally, check that no LF-only line endings slipped into the edited files:

```powershell
'lib\BaselineArchive.ps1','tests\BaselineArchive.Tests.ps1','tests\TestHelpers\Assessment.ps1' |
  ForEach-Object { '{0}: {1}' -f $_, ([regex]::Matches((Get-Content -Raw $_), '(?<!\r)\n')).Count }
```

Expected: every count is `0`.

- [ ] **Step 7: Commit**

Run:

```powershell
git add lib\BaselineArchive.ps1 tests\BaselineArchive.Tests.ps1 tests\TestHelpers\Assessment.ps1
git commit -m "feat: read CIS build-kit ZIP archives in memory" -m "Co-authored-by: Copilot App <223556219+Copilot@users.noreply.github.com>"
```

Expected: one commit with `3 files changed, 438 insertions(+)`. If the opt-in
pre-commit hook is installed, it passes.

### Task 4: Archive field on the pack import API

Let `POST /api/assessment/packs` accept exactly one of `content` (a JSON rule
pack, as today) or `archive` (a base64 ZIP). A new `Import-IdsAssessmentArchive`
decodes the archive, reads it with `ConvertFrom-IdsBaselineArchive` (Task 3),
checks every generated pack against the whole catalog and stores the set with
`Import-IdsBaselinePackSet` (Task 1). Both paths now report `origin:
'imported'` (spec decision 17). This is the "API" section of Part B of the
design spec, together with "Error handling"
(`docs\superpowers\specs\2026-10-29-assessment-wizard-and-cis-zip-import-design.md`).
Task 6 builds the UI on this contract and Task 7 documents it.

Notes for this task:

- Line numbers refer to the files before this task; Tasks 1–3 do not touch
  them. Find each edit by its exact current text; every "replace this text"
  snippet occurs exactly once in its file.
- Both files use CRLF line endings. Keep CRLF. The repository has no
  `.gitattributes`; with `core.autocrlf=true`, Git normalizes on commit.
- `Invoke-IdsAssessmentRoute` maps exceptions in this order:
  - `[IO.InvalidDataException]` → 413 with the message;
  - `[IO.IOException]` → 500 "Local assessment storage failed.";
  - `[InvalidOperationException]` → 500 "Assessment worker could not start.";
  - anything else → 400 with the message.
  - Plain-string `throw` therefore gives HTTP 400.
- Request rules:
  - `Assert-IdsAssessmentFields $fields @('content', 'archive') @()` keeps
    rejecting unknown fields with 'Unknown assessment input field.'
  - Then exactly one field must be present; otherwise 'Provide exactly one of
    content or archive.' (400).
- The `content` path is unchanged, except that the pack gets an `origin =
  'imported'` NoteProperty (`-Force`) before `Get-IdsAssessmentPackMetadata`.
  That function copies it through `Copy-IdsReportRecord`.
- The `archive` path:
  1. The value must be a string whose length is a multiple of 4 and that
     matches `\A[A-Za-z0-9+/]*={0,2}\z`. Otherwise: 'Archive must be strict
     base64 text.' (400).
  2. More than 44,739,244 characters → `[IO.InvalidDataException]` 'Archive
     byte limit exceeded (32 MiB).' (413). 44,739,244 characters decode to at
     most 32 MiB + 1 byte.
  3. Decoded with `[Convert]::FromBase64String`:
     - 0 bytes → 'Archive is empty.' (400);
     - more than 32 MiB → the same 413 message.
  4. `ConvertFrom-IdsBaselineArchive` reads the archive.
  5. No packs → HTTP 400 `{ error; skipped; skippedCount; ignored }`, with the
     error "The archive contains no importable rule packs or Settings Catalog
     policies. PDF, Excel, XCCDF/OVAL, Group Policy and OMA-URI content is not
     supported."
  6. Every generated pack is checked against `Get-IdsAssessmentCatalog`, which
     holds the bundled and the imported packs. The same id and version with a
     different SHA-256 → "Pack `<id>@<version>` already exists with different
     bytes; nothing was imported." (400), and nothing is written.
     `Import-IdsBaselinePackSet` sees only imported packs, so this check is
     what protects bundled identities.
  7. `Import-IdsBaselinePackSet -Packs $result.packs -ImportedRoot
     $State.Config.ImportedPackRoot` stores the set. Two different packs with
     the same identity in one archive fail there with "Pack set contains
     different packs with the same ID/version: `<id>@<version>`." (400).
  8. HTTP 201 returns `{ packs; added; skipped; skippedCount; ignored; archive
     = @{ sha256 } }`:
     - Each pack is the `Get-IdsAssessmentPackMetadata` output (no `controls`,
       no `path`), plus `origin = 'imported'`, `controlCount` and `added`.
     - `skipped` holds at most 100 `@{ entry; reason }` items, with entry
       names cut to 260 characters.
     - `skippedCount` is the total number of skipped entries.
- The archive branch sets `$response.status` and `$response.body`, then uses
  `break` to leave the `switch`, like the existing `'GET /api/assessment'`
  case.
- `IntuneDocsStudio.ps1` sends the body with `Send-IdsJson -Depth 64`, which
  uses `ConvertTo-Json`. `packs` and `skipped` are built with `@(...)`, so a
  one-item list stays a JSON array. The tests serialize the body the same way.
- Testing notes:
  - The 44,739,248-character test request is about 43 MiB, under the route's
    64 MiB request limit, so it reaches the length check.
  - The decoded-size test calls `Import-IdsAssessmentArchive` directly, with
    exactly 44,739,244 characters. That text passes the length check and
    decodes to 32 MiB + 1 byte. Through the route, both checks return the same
    message, so a route test could not tell them apart.
- `tests\AssessmentApi.Tests.ps1` line 3 gains `'AssessmentCollection',
  'AssessmentSettings', 'BaselineArchive'` after `'BaselinePacks'`. The file
  loads each listed module only if it exists, and it already dot-sources
  `tests\TestHelpers\Assessment.ps1`.
- The new tests build a fresh `$state` for each test:
  - `Config.Port` is 7654, matching `New-ApiRequest`;
  - `Config.ImportedPackRoot` is a new folder in `$TestDrive`.
  - The bundled catalog has 4 packs, so the catalog lists 6 after a 2-pack
    archive import.

**Files:**

- Modify: `lib\AssessmentApi.ps1`:
  - a new function before line 51, `function Invoke-IdsAssessmentRoute {`;
  - about lines 91–110, the `'POST /api/assessment/packs'` case.
- Test: `tests\AssessmentApi.Tests.ps1` (line 3, the module load list; a new
  `Describe` after line 164)

**Interfaces:**

- Consumes:
  - From Task 1: `Import-IdsBaselinePackSet -Packs <byte[][]> -ImportedRoot
    <string>` → one `[pscustomobject]@{ pack; added }` per unique pack, in
    input order.
  - From Task 2: the test helper `New-IdsTestBuildKitPolicy([string]$Name =
    'Synthetic L1 policy', [string]$Platforms = 'windows10',
    [object[]]$Instances = @(), [object[]]$Definitions = @())`.
  - From Task 3:
    - `ConvertFrom-IdsBaselineArchive -Bytes <byte[]>` →
      `[pscustomobject]@{ packs = <byte[][]>; skipped = <object[] of { entry;
      reason }>; ignored = <int>; sha256 = <hex> }`. It throws
      `[ArgumentException]` (400) or `[IO.InvalidDataException]` (413).
    - The test helper `New-IdsTestZipBytes([Collections.IDictionary]$Entries,
      [string]$CompressionLevel = 'Optimal', [DateTimeOffset]$LastWriteTime)`.
  - Existing:
    - `Read-IdsAssessmentRequestJson($Request, $MaxBytes)`;
    - `Assert-IdsAssessmentFields($Value, [string[]]$Allowed, [string[]]$Required
      = @())`;
    - `Get-IdsAssessmentCatalog([hashtable]$State, [string]$Root)` →
      `{ packs; errors }`, the bundled and imported packs with `origin`, `path`
      and `sha256`;
    - `Get-IdsAssessmentPackMetadata($Pack)`, `Read-IdsBaselinePack -Bytes`,
      `Initialize-IdsAssessment([hashtable]$State)`;
    - the test helpers `New-ApiRequest`, `New-IdsTestPackBytes` and
      `New-IdsTestSettingInstance`.
- Produces:
  - `Import-IdsAssessmentArchive($Archive, [hashtable]$State, [string]$Root)` →
    `[pscustomobject]@{ status = 201 or 400; body }`. It throws plain strings
    (400) or `[IO.InvalidDataException]` (413).
  - The HTTP contract that Tasks 6 and 7 rely on. `POST /api/assessment/packs`
    takes exactly one of `{ content }` or `{ archive }`:
    - `{ content }` → 201 `{ pack }`, where `pack` carries the metadata,
      `selectionId` and `origin: 'imported'`;
    - `{ archive }` → 201 `{ packs: [{ ...metadata, origin: 'imported',
      controlCount, added }], added, skipped: [{ entry, reason }] (at most
      100), skippedCount, ignored, archive: { sha256 } }`;
    - → 400 `{ error, skipped, skippedCount, ignored }` when the archive has
      nothing importable;
    - → 400 `{ error }` for invalid input or a conflict;
    - → 413 `{ error }` over a limit.
  - Messages:
    - 'Provide exactly one of content or archive.'
    - 'Archive must be strict base64 text.'
    - 'Archive is empty.'
    - 'Archive byte limit exceeded (32 MiB).'
    - "Pack `<id>@<version>` already exists with different bytes; nothing was
      imported."
    - the nothing-importable error above.

- [ ] **Step 1: Load the archive modules in the API tests**

In `tests\AssessmentApi.Tests.ps1`, replace this line (line 3):

```powershell
    foreach ($module in 'Http', 'BaselinePacks', 'AssessmentRules', 'AssessmentReports', 'Assessment', 'AssessmentApi') {
```

with:

```powershell
    foreach ($module in 'Http', 'BaselinePacks', 'AssessmentCollection', 'AssessmentSettings', 'BaselineArchive', 'AssessmentRules', 'AssessmentReports', 'Assessment', 'AssessmentApi') {
```

- [ ] **Step 2: Append the archive import tests**

Append this code at the end of `tests\AssessmentApi.Tests.ps1`, after the
closing `}` of `Describe 'Assessment JSON response depth'` (about line 164).
Leave one blank line before it.

```powershell
Describe 'Assessment pack archive imports' {
    BeforeAll {
        function Invoke-TestPackImport([hashtable]$State, [hashtable]$Fields) {
            $text = ConvertTo-Json -InputObject $Fields -Compress
            return Invoke-IdsAssessmentRoute POST /api/assessment/packs (New-ApiRequest $text) $State $repo
        }
        function New-TestKitPolicyJson([string]$Name, [string]$Id, $Value) {
            $policy = New-IdsTestBuildKitPolicy -Name $Name -Instances @(New-IdsTestSettingInstance -Id $Id -Value @{ value = $Value })
            return ConvertTo-Json -InputObject $policy -Depth 64 -Compress
        }
        function Get-TestImportedFiles([hashtable]$State) {
            $root = $State.Config.ImportedPackRoot
            if (-not (Test-Path -LiteralPath $root)) { return @() }
            return @(Get-ChildItem -LiteralPath $root -Filter '*.json' -File)
        }
        $nothingImportable = 'The archive contains no importable rule packs or Settings Catalog policies. ' +
            'PDF, Excel, XCCDF/OVAL, Group Policy and OMA-URI content is not supported.'
    }
    BeforeEach {
        $state = [hashtable]::Synchronized(@{
            Auth = $null; Export = @{ running = $false }; Browser = @{ running = $false }
            Config = @{ Port = 7654; ImportedPackRoot = (Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))); OutputPath = "$TestDrive\export" }
        })
        Initialize-IdsAssessment $state
    }

    It 'requires exactly one of content or archive' {
        foreach ($fields in @(@{}, @{ content = '{}'; archive = 'AAAA' })) {
            $response = Invoke-TestPackImport $state $fields
            $response.status | Should -Be 400
            $response.body.error | Should -BeExactly 'Provide exactly one of content or archive.'
        }
    }

    It 'rejects archive text with <label>' -ForEach @(
        @{ label = 'a number instead of text'; value = 5 }
        @{ label = 'characters outside base64'; value = 'AB$D' }
        @{ label = 'whitespace'; value = 'QUJ RA==' }
        @{ label = 'padding inside the text'; value = 'QU=D' }
        @{ label = 'a length that is not a multiple of 4'; value = 'QUJDRA' }
        @{ label = 'three padding characters'; value = 'Q===' }
    ) {
        $response = Invoke-TestPackImport $state @{ archive = $value }
        $response.status | Should -Be 400
        $response.body.error | Should -BeExactly 'Archive must be strict base64 text.'
    }

    It 'rejects an empty archive' {
        $response = Invoke-TestPackImport $state @{ archive = '' }
        $response.status | Should -Be 400
        $response.body.error | Should -BeExactly 'Archive is empty.'
    }

    It 'returns 413 for archive text longer than 44,739,244 characters' {
        $response = Invoke-TestPackImport $state @{ archive = ('A' * 44739248) }
        $response.status | Should -Be 413
        $response.body.error | Should -BeExactly 'Archive byte limit exceeded (32 MiB).'
    }

    It 'rejects archive text that decodes to more than 32 MiB' {
        # 44,739,244 unpadded characters decode to 32 MiB + 1 byte.
        { Import-IdsAssessmentArchive ('A' * 44739244) $state $repo } |
            Should -Throw -ExceptionType ([IO.InvalidDataException]) -ExpectedMessage 'Archive byte limit exceeded (32 MiB).'
    }

    It 'returns 413 when the archive exceeds the 64 MiB JSON budget' {
        $entries = [ordered]@{}
        # 0xFF bytes are not valid UTF-8, so no entry reaches the JSON parser.
        $filler = [byte[]]::new(10000000)
        [Array]::Fill($filler, [byte]255)
        for ($index = 0; $index -lt 7; $index++) { $entries["kit/filler$index.json"] = $filler }
        $response = Invoke-TestPackImport $state @{ archive = [Convert]::ToBase64String((New-IdsTestZipBytes $entries)) }
        $response.status | Should -Be 413
        $response.body.error | Should -BeExactly 'Archive JSON read limit exceeded (64 MiB).'
        @(Get-TestImportedFiles $state).Count | Should -Be 0
    }

    It 'rejects bytes that are not a ZIP archive' {
        $archive = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes('not a zip archive'))
        $response = Invoke-TestPackImport $state @{ archive = $archive }
        $response.status | Should -Be 400
        $response.body.error | Should -BeExactly 'The file is not a valid ZIP archive.'
    }

    It 'answers 400 with skipped and ignored entries when nothing is importable' {
        $zip = New-IdsTestZipBytes ([ordered]@{ 'kit/readme.pdf' = 'synthetic'; 'kit/notes.json' = '{"title":"Synthetic notes"}' })
        $response = Invoke-TestPackImport $state @{ archive = [Convert]::ToBase64String($zip) }
        $response.status | Should -Be 400
        $json = ConvertTo-Json -InputObject $response.body -Depth 64 | ConvertFrom-Json
        $json.error | Should -BeExactly $nothingImportable
        ($json.skipped -is [array]) | Should -BeTrue
        "$($json.skipped[0].entry) => $($json.skipped[0].reason)" |
            Should -BeExactly 'kit/notes.json => Not a Settings Catalog policy or rule pack.'
        $json.skippedCount | Should -Be 1
        $json.ignored | Should -Be 1
        @(Get-TestImportedFiles $state).Count | Should -Be 0
    }

    It 'limits the skipped list to 100 items and truncates entry names to 260 characters' {
        $entries = [ordered]@{ 'kit/L1/policy.json' = (New-TestKitPolicyJson 'Synthetic L1 policy' 'syn.level1' 1) }
        $long = 'kit/' + ('n' * 300) + '.json'
        $entries[$long] = '{"title":"Synthetic notes"}'
        for ($index = 0; $index -lt 120; $index++) { $entries["kit/notes$index.json"] = '{"title":"Synthetic notes"}' }
        $response = Invoke-TestPackImport $state @{ archive = [Convert]::ToBase64String((New-IdsTestZipBytes $entries)) }
        $response.status | Should -Be 201
        $response.body.skipped.Count | Should -Be 100
        $response.body.skippedCount | Should -Be 121
        $response.body.skipped[0].entry | Should -BeExactly $long.Substring(0, 260)
        $response.body.skipped[1].entry | Should -BeExactly 'kit/notes0.json'
    }

    It 'imports a build-kit archive, reports the summary and is idempotent' {
        $zip = New-IdsTestZipBytes ([ordered]@{
            'kit/readme.pdf' = 'synthetic'
            'kit/notes.json' = '{"title":"Synthetic notes"}'
            'kit/L2/policy.json' = (New-TestKitPolicyJson 'Synthetic L2 policy' 'syn.level2' 'synthetic')
            'kit/L1/policy.json' = (New-TestKitPolicyJson 'Synthetic L1 policy' 'syn.level1' 1)
        })
        $archive = [Convert]::ToBase64String($zip)
        $sha256 = (Get-FileHash -InputStream ([IO.MemoryStream]::new($zip)) -Algorithm SHA256).Hash.ToLowerInvariant()
        $first = Invoke-TestPackImport $state @{ archive = $archive }
        $first.status | Should -Be 201
        $text = ConvertTo-Json -InputObject $first.body -Depth 64
        $text | Should -Not -Match '"controls"|"path"'
        $json = $text | ConvertFrom-Json
        (@($json.packs | ForEach-Object { "$($_.id)|$($_.origin)|$($_.controlCount)|$($_.added)" }) -join ',') |
            Should -BeExactly 'cis.windows11.l1|imported|1|True,cis.windows11.l2|imported|1|True'
        $json.packs[0].selectionId | Should -Match '^cis\.windows11\.l1@1\.0\.0\+[0-9a-f]{12}#[0-9a-f]{64}$'
        $json.added | Should -Be 2
        ($json.skipped -is [array]) | Should -BeTrue
        "$($json.skipped[0].entry) => $($json.skipped[0].reason)" |
            Should -BeExactly 'kit/notes.json => Not a Settings Catalog policy or rule pack.'
        $json.skippedCount | Should -Be 1
        $json.ignored | Should -Be 1
        $json.archive.sha256 | Should -BeExactly $sha256
        @(Get-TestImportedFiles $state).Count | Should -Be 2

        $second = Invoke-TestPackImport $state @{ archive = $archive }
        $second.status | Should -Be 201
        (@($second.body.packs | ForEach-Object { "$($_.id)|$($_.added)" }) -join ',') |
            Should -BeExactly 'cis.windows11.l1|False,cis.windows11.l2|False'
        $second.body.added | Should -Be 0
        @(Get-TestImportedFiles $state).Count | Should -Be 2

        $catalog = Invoke-IdsAssessmentRoute GET /api/assessment/packs (New-ApiRequest) $state $repo
        $catalog.body.packs.Count | Should -Be 6
        $listed = @($catalog.body.packs | Where-Object { $_.id -ceq 'cis.windows11.l1' })
        $listed.Count | Should -Be 1
        $listed[0].origin | Should -BeExactly 'imported'
        $listed[0].selectionId | Should -BeExactly $json.packs[0].selectionId
    }

    It 'rejects a conflict with an imported pack before writing anything' {
        $content = [Text.Encoding]::UTF8.GetString((New-IdsTestPackBytes))
        (Invoke-TestPackImport $state @{ content = $content }).status | Should -Be 201
        $zip = New-IdsTestZipBytes ([ordered]@{
            'kit/L1/policy.json' = (New-TestKitPolicyJson 'Synthetic L1 policy' 'syn.level1' 1)
            'packs/changed.json' = $content.Replace('Synthetic required setting', 'Changed')
        })
        $response = Invoke-TestPackImport $state @{ archive = [Convert]::ToBase64String($zip) }
        $response.status | Should -Be 400
        $response.body.error | Should -BeExactly 'Pack synthetic-pack@1.0.0 already exists with different bytes; nothing was imported.'
        @(Get-TestImportedFiles $state).Count | Should -Be 1
    }

    It 'rejects a conflict with a bundled pack before writing anything' {
        $bundled = (Get-IdsAssessmentCatalog $state $repo).packs[0]
        $changed = [IO.File]::ReadAllText($bundled.path).Replace($bundled.controls[0].title, 'Synthetic changed title')
        $zip = New-IdsTestZipBytes ([ordered]@{
            'kit/L1/policy.json' = (New-TestKitPolicyJson 'Synthetic L1 policy' 'syn.level1' 1)
            'packs/changed.json' = $changed
        })
        $response = Invoke-TestPackImport $state @{ archive = [Convert]::ToBase64String($zip) }
        $response.status | Should -Be 400
        $response.body.error |
            Should -BeExactly "Pack $($bundled.id)@$($bundled.version) already exists with different bytes; nothing was imported."
        @(Get-TestImportedFiles $state).Count | Should -Be 0
        $catalog = Get-IdsAssessmentCatalog $state $repo
        $catalog.packs.Count | Should -Be 4
        $catalog.errors.Count | Should -Be 0
    }

    It 'rejects two different packs with the same identity in one archive' {
        $content = [Text.Encoding]::UTF8.GetString((New-IdsTestPackBytes))
        $zip = New-IdsTestZipBytes ([ordered]@{
            'packs/original.json' = $content
            'packs/changed.json' = $content.Replace('Synthetic required setting', 'Changed')
            'kit/L1/policy.json' = (New-TestKitPolicyJson 'Synthetic L1 policy' 'syn.level1' 1)
        })
        $response = Invoke-TestPackImport $state @{ archive = [Convert]::ToBase64String($zip) }
        $response.status | Should -Be 400
        $response.body.error | Should -BeExactly 'Pack set contains different packs with the same ID/version: synthetic-pack@1.0.0.'
        @(Get-TestImportedFiles $state).Count | Should -Be 0
    }

    It 'reports imported origin for single JSON pack imports' {
        $content = [Text.Encoding]::UTF8.GetString((New-IdsTestPackBytes))
        $response = Invoke-TestPackImport $state @{ content = $content }
        $response.status | Should -Be 201
        $response.body.pack.origin | Should -BeExactly 'imported'
        $catalog = Invoke-IdsAssessmentRoute GET /api/assessment/packs (New-ApiRequest) $state $repo
        @($catalog.body.packs | Where-Object { $_.id -ceq 'synthetic-pack' }).origin | Should -BeExactly 'imported'
    }
}
```

- [ ] **Step 3: Run the new tests and see them fail**

Run:

```powershell
Invoke-Pester .\tests\AssessmentApi.Tests.ps1 -Output Detailed
```

Expected: `Tests Passed: 14, Failed: 19, Skipped: 0, Inconclusive: 0, NotRun: 0`.
The failing tests are:

- 13 cases with `Expected strings to be the same, but they were different.`
  The request still answers 400, but with the old message:
  - `requires exactly one of content or archive`;
  - `rejects archive text with <label>` (6 cases);
  - `rejects an empty archive`;
  - `rejects bytes that are not a ZIP archive`;
  - `answers 400 with skipped and ignored entries when nothing is importable`;
  - `rejects a conflict with an imported pack before writing anything`;
  - `rejects a conflict with a bundled pack before writing anything`;
  - `rejects two different packs with the same identity in one archive`.
- `returns 413 for archive text longer than 44,739,244 characters` and
  `returns 413 when the archive exceeds the 64 MiB JSON budget`, with
  `Expected 413, but got 400.`
- `rejects archive text that decodes to more than 32 MiB`, with `Expected an
  exception with type [System.IO.InvalidDataException] ...`. The exception
  type was `[System.Management.Automation.CommandNotFoundException]`, for
  `Import-IdsAssessmentArchive`.
- `limits the skipped list to 100 items and truncates entry names to 260
  characters` and `imports a build-kit archive, reports the summary and is
  idempotent`, with `Expected 201, but got 400.`
- `reports imported origin for single JSON pack imports`, with `Expected
  exactly 'imported', but got $null.`

The 14 existing tests pass.

- [ ] **Step 4: Add the archive import function**

In `lib\AssessmentApi.ps1`, insert this code directly before the line
`function Invoke-IdsAssessmentRoute {` (about line 51), followed by one blank
line. It goes after `Get-IdsAssessmentPackMetadata` and the blank line that
follows it.

```powershell
function Import-IdsAssessmentArchive {
    param($Archive, [hashtable]$State, [string]$Root)
    if ($Archive -isnot [string] -or $Archive.Length % 4 -ne 0 -or $Archive -cnotmatch '\A[A-Za-z0-9+/]*={0,2}\z') {
        throw 'Archive must be strict base64 text.'
    }
    # 44,739,244 base64 characters decode to at most 32 MiB + 1 byte.
    if ($Archive.Length -gt 44739244) { throw [IO.InvalidDataException]::new('Archive byte limit exceeded (32 MiB).') }
    $bytes = [Convert]::FromBase64String($Archive)
    if ($bytes.Length -eq 0) { throw 'Archive is empty.' }
    if ($bytes.Length -gt 32MB) { throw [IO.InvalidDataException]::new('Archive byte limit exceeded (32 MiB).') }
    $result = ConvertFrom-IdsBaselineArchive -Bytes $bytes
    $skipped = @($result.skipped | Select-Object -First 100 | ForEach-Object {
        $entry = [string]$_.entry
        if ($entry.Length -gt 260) { $entry = $entry.Substring(0, 260) }
        @{ entry = $entry; reason = $_.reason }
    })
    if ($result.packs.Count -eq 0) {
        return [pscustomobject]@{ status = 400; body = @{
            error = 'The archive contains no importable rule packs or Settings Catalog policies. ' +
                'PDF, Excel, XCCDF/OVAL, Group Policy and OMA-URI content is not supported.'
            skipped = $skipped; skippedCount = $result.skipped.Count; ignored = $result.ignored
        } }
    }
    # Import-IdsBaselinePackSet sees only imported packs; bundled identities
    # are checked here so nothing is written when any pack conflicts.
    $catalog = Get-IdsAssessmentCatalog $State $Root
    foreach ($packBytes in $result.packs) {
        $candidate = Read-IdsBaselinePack -Bytes $packBytes
        foreach ($existing in $catalog.packs) {
            if ($existing.id -ceq $candidate.id -and $existing.version -ceq $candidate.version -and $existing.sha256 -cne $candidate.sha256) {
                throw "Pack $($candidate.id)@$($candidate.version) already exists with different bytes; nothing was imported."
            }
        }
    }
    $imported = @(Import-IdsBaselinePackSet -Packs $result.packs -ImportedRoot $State.Config.ImportedPackRoot)
    $packs = @(foreach ($item in $imported) {
        $item.pack | Add-Member -NotePropertyName origin -NotePropertyValue 'imported' -Force
        $metadata = Get-IdsAssessmentPackMetadata $item.pack
        $metadata | Add-Member NoteProperty controlCount @($item.pack.controls).Count
        $metadata | Add-Member NoteProperty added $item.added
        $metadata
    })
    return [pscustomobject]@{ status = 201; body = @{
        packs = $packs; added = @($imported | Where-Object { $_.added }).Count
        skipped = $skipped; skippedCount = $result.skipped.Count; ignored = $result.ignored
        archive = @{ sha256 = $result.sha256 }
    } }
}
```

- [ ] **Step 5: Accept exactly one of content or archive**

In `lib\AssessmentApi.ps1`, inside the `switch` of `Invoke-IdsAssessmentRoute`,
replace the whole `'POST /api/assessment/packs'` case (about lines 91–110). The
text to replace is:

```powershell
            'POST /api/assessment/packs' {
                $body = Read-IdsAssessmentRequestJson $Request 64MB
                $fields = @{}
                foreach ($property in $body.PSObject.Properties) { $fields[$property.Name] = $property.Value }
                Assert-IdsAssessmentFields $fields @('content') @('content')
                if ($body.content -isnot [string]) { throw 'Pack content must be original UTF-8 JSON text.' }
                $encoding = [Text.UTF8Encoding]::new($false, $true)
                if ($encoding.GetByteCount($body.content) -gt 10MB) { throw [IO.InvalidDataException]::new('Decoded pack byte limit exceeded (10 MiB).') }
                $bytes = $encoding.GetBytes($body.content)
                $candidate = Read-IdsBaselinePack -Bytes $bytes
                $catalog = Get-IdsAssessmentCatalog $State $Root
                foreach ($existing in $catalog.packs) {
                    if ($existing.id -ceq $candidate.id -and $existing.version -ceq $candidate.version -and $existing.sha256 -cne $candidate.sha256) {
                        throw 'Pack ID/version already exists with different bytes.'
                    }
                }
                $pack = Import-IdsBaselinePack -Bytes $bytes -ImportedRoot $State.Config.ImportedPackRoot
                $response.status = 201
                $response.body = @{ pack = Get-IdsAssessmentPackMetadata $pack }
            }
```

Replace it with:

```powershell
            'POST /api/assessment/packs' {
                $body = Read-IdsAssessmentRequestJson $Request 64MB
                $fields = @{}
                foreach ($property in $body.PSObject.Properties) { $fields[$property.Name] = $property.Value }
                Assert-IdsAssessmentFields $fields @('content', 'archive') @()
                if ($fields.Count -ne 1) { throw 'Provide exactly one of content or archive.' }
                if ($fields.ContainsKey('archive')) {
                    $imported = Import-IdsAssessmentArchive $fields['archive'] $State $Root
                    $response.status = $imported.status; $response.body = $imported.body
                    break
                }
                if ($body.content -isnot [string]) { throw 'Pack content must be original UTF-8 JSON text.' }
                $encoding = [Text.UTF8Encoding]::new($false, $true)
                if ($encoding.GetByteCount($body.content) -gt 10MB) { throw [IO.InvalidDataException]::new('Decoded pack byte limit exceeded (10 MiB).') }
                $bytes = $encoding.GetBytes($body.content)
                $candidate = Read-IdsBaselinePack -Bytes $bytes
                $catalog = Get-IdsAssessmentCatalog $State $Root
                foreach ($existing in $catalog.packs) {
                    if ($existing.id -ceq $candidate.id -and $existing.version -ceq $candidate.version -and $existing.sha256 -cne $candidate.sha256) {
                        throw 'Pack ID/version already exists with different bytes.'
                    }
                }
                $pack = Import-IdsBaselinePack -Bytes $bytes -ImportedRoot $State.Config.ImportedPackRoot
                $pack | Add-Member -NotePropertyName origin -NotePropertyValue 'imported' -Force
                $response.status = 201
                $response.body = @{ pack = Get-IdsAssessmentPackMetadata $pack }
            }
```

- [ ] **Step 6: Run the new tests and see them pass**

Run:

```powershell
Invoke-Pester .\tests\AssessmentApi.Tests.ps1 -Output Detailed
```

Expected: `Tests Passed: 33, Failed: 0, Skipped: 0, Inconclusive: 0, NotRun: 0`.

- [ ] **Step 7: Run the regression suite**

Run:

```powershell
Invoke-Pester .\tests\AssessmentPacks.Tests.ps1, .\tests\BaselineArchive.Tests.ps1, .\tests\Package.Tests.ps1, .\tests\AssessmentIntegration.Tests.ps1, .\tests\Runtime.Tests.ps1 -Output Detailed
pwsh -NoProfile -File .\scripts\Test-Repository.ps1; $LASTEXITCODE
git --no-pager diff --stat
```

Expected:

- Pester shows `Tests Passed: 244, Failed: 0, Skipped: 0, Inconclusive: 0,
  NotRun: 0`: 138 pack tests, 44 archive tests, 17 package tests, 31
  integration tests and 14 runtime tests.
- `Test-Repository.ps1` prints `Repository guidance and local policy checks
  passed.` and then `0`. It may first print `Pull request target policy: not
  applicable without pull request event context.`
- The diff stat lists exactly these 2 files: `lib/AssessmentApi.ps1` and
  `tests/AssessmentApi.Tests.ps1`. It shows `2 files changed, 263
  insertions(+), 2 deletions(-)`.

Optionally, check that no LF-only line endings slipped into the edited files:

```powershell
'lib\AssessmentApi.ps1','tests\AssessmentApi.Tests.ps1' |
  ForEach-Object { '{0}: {1}' -f $_, ([regex]::Matches((Get-Content -Raw $_), '(?<!\r)\n')).Count }
```

Expected: every count is `0`.

- [ ] **Step 8: Commit**

Run:

```powershell
git add lib\AssessmentApi.ps1 tests\AssessmentApi.Tests.ps1
git commit -m "feat: import CIS build-kit archives through the pack API" -m "Co-authored-by: Copilot App <223556219+Copilot@users.noreply.github.com>"
```

Expected: one commit with `2 files changed, 263 insertions(+), 2
deletions(-)`. If the opt-in pre-commit hook is installed, it passes.


### Task 5: Assessment wizard

Turn the **Assess policies** view into a five-step wizard: Platforms, Baselines,
Context, Review & run, Results. It gets a numbered stepper, validation per step,
a plain-text review, a **New assessment** button and an **Import rule packs**
card that is visible on steps 1–2 only. Steps are client state, not routes.
Every existing element ID is kept. The documentation workflow and its stepper
do not change. This is Part A of the design spec
(`docs\superpowers\specs\2026-10-29-assessment-wizard-and-cis-zip-import-design.md`).
Task 6 adds ZIP import and rewrites the catalog note.

Notes for this task:

- Line numbers refer to the files before this task. Earlier edits in the same
  file shift later lines, so find each edit by its exact current text. Every
  "replace this text" snippet occurs exactly once in its file.
- All five files use CRLF line endings. Keep CRLF. The repository has no
  `.gitattributes`; with `core.autocrlf=true`, Git normalizes on commit.
- The UI tests run `web\app.js` in a Node `vm` with a fake DOM:
  `assessmentDashboard` in `tests\assessment-ui.test.js` and `shell` in
  `tests\app-shell-ui.test.js`.
  - The fake DOM does not parse `index.html`, so start-up must call
    `setAssessmentStep('platforms')` itself.
  - An element keeps one handler per event.
  - `classList` has `add`, `remove` and `contains`, but no `toggle`. Use
    `setHidden` or `classList.add`/`remove` only.
- `tests\app-shell-ui.test.js` requires every literal `$('id')` in
  `web\app.js` to exist exactly once in `web\index.html`. Step 6 adds every new
  ID to the markup.
- Focus moves to the new step's heading (`tabindex="-1"`) only after a user
  action: Next, Back, **New assessment**, or admission (HTTP 202).
  - Start-up, a background refresh and `clearAssessment()` change the step
    without moving focus.
  - A blocked Next writes its message to `assessmentError`, scrolls the message
    into view and leaves focus on the button.
- **Assess selected policies** keeps its own validation and messages, and it
  works from any step, because existing tests click `btnAssessmentRun` without
  stepping. A failed run stays on the current step.
- `refreshAssessment()` runs only at start-up (`start()`), from **Refresh
  assessment**, after admission and from the polling timer.
  - It shows step 5 for a running assessment, and for a completed assessment
    whose results rendered.
  - An error keeps the current step.
  - A 404 or stale idle state already calls `clearAssessment()`, which now
    returns to step 1.
- **New assessment** is disabled while an assessment runs. It keeps the
  platforms, packs, context, destination and previous results, and returns to
  step 1.
- The review shows enrollment and ownership through JS label maps, because the
  fake DOM has no `options` or `selectedIndex`. A test reads the `<option>`
  labels from `index.html` and checks every one.
- Two existing tests change, because the import success line moves from
  `assessmentProgress` to the new `assessmentImportSummary`:
  - the JSON import test gets 2 assertions;
  - the stale-reset test gets 1 assertion.
  No other existing test changes.
- The import card keeps the JSON label, the `accept` attribute and the
  **Import pack** button text. `README.md`, `QUICKSTART.md`,
  `docs\assessment-rule-packs.md` and `docs\operations.md` name that button.
  Task 6 changes the label and `accept` for ZIP files and rewrites the catalog
  note.

**Files:**

- Modify: `web\index.html` (about lines 303–413, the `#cardAssessment` block
  inside `#viewAssess`)
- Modify: `web\app.js`:
  - about lines 655–666, `updateAssessmentSelection`, plus a new block after
    line 666;
  - line 678, `syncJobAdmission`;
  - lines 704–709, `clearAssessment`;
  - lines 767–782, `refreshAssessment`;
  - lines 802–805 and 842–843, the run handler;
  - lines 867–869 and 886, the import handler;
  - lines 996–997, start-up.
- Modify: `web\style.css` (about line 440, the assessment styles; about lines
  469–477, the 900 px media query)
- Test: `tests\assessment-ui.test.js`:
  - about lines 13–25 and 62, the harness;
  - lines 224–225, the import test;
  - line 577, the stale-reset test;
  - new tests after line 740.
- Test: `tests\app-shell-ui.test.js` (two new tests before line 313)

**Interfaces:**

- Consumes:
  - Existing `web\app.js` helpers:
    - `$`, `setHidden(id, hidden)`, `showAssessmentError(message)`, `syncJobAdmission()`;
    - `assessmentPlatformBoxes()`, `assessmentPackBoxes()`;
    - `assessmentIdentity(pack)` (`id@version#sha256`), `assessmentOsId(platform)`;
    - `assessmentPlatforms` (platform key → display name), `assessmentPacks`, `assessmentBusy`;
    - `clearAssessment()`, `refreshAssessment()`, `renderAssessmentResult(body)`, `startAssessmentPolling()`.
  - Existing element IDs, all kept:
    - `cardAssessment`, `assessmentError`;
    - catalog and packs: `assessmentCatalogNote`, `assessmentCatalogErrors`, `assessmentPlatforms`, `assessmentProfile`, `assessmentPacks`;
    - import: `assessmentImportFile`, `btnAssessmentImport`;
    - context: `assessmentOsWindows11`, `assessmentOsMacos`, `assessmentOsIosIpados`, `assessmentOsAndroidEnterprise`, `assessmentEnrollment`, `assessmentIosOwnership`;
    - run: `assessmentOutputPath`, `btnAssessmentRun`, `btnAssessmentRefresh`, `assessmentBar`, `assessmentProgress`;
    - results: `assessmentReportPaths`, `assessmentLimitations`, `assessmentSummary`, `assessmentContextResult`, `assessmentPackResult`, `assessmentIssues`, `assessmentPolicies`, `assessmentStatusFilter`, `assessmentResults`;
    - headings: `baselinesTitle`, `contextTitle`, `runAssessmentTitle`, `resultsTitle`.
  - The API, unchanged:
    - `GET /api/assessment` → `{ running, done, percent, phase, partial, error }`;
    - `GET /api/assessment/results`;
    - `POST /api/assessment` → HTTP 202 `{ started: true }`;
    - `POST /api/assessment/packs` with `{ content }` → HTTP 201 `{ pack }`.
  - Test helpers in `tests\assessment-ui.test.js`: `assessmentDashboard(respond)`, `syntheticPacks()`, `boxes(d, root)`, `renderCatalog(d, packs)`, `connectedState()`, `selectAll(d)`.
- Produces:
  - Element IDs:
    - stepper items `assessStepPlatforms`, `assessStepBaselines`, `assessStepContext`, `assessStepReview`, `assessStepResults`;
    - panels `assessPanelPlatforms`, `assessPanelBaselines`, `assessPanelContext`, `assessPanelReview`, `assessPanelResults`, and the heading `platformsTitle`;
    - buttons `btnAssessPlatformsNext`, `btnAssessBaselinesBack`, `btnAssessBaselinesNext`, `btnAssessContextBack`, `btnAssessContextNext`, `btnAssessReviewBack`, `btnAssessNew`, `btnAssessmentSelectAll`, `btnAssessmentSelectNone`;
    - `assessmentPacksEmpty`;
    - context labels `assessmentContextWindows11`, `assessmentContextMacos`, `assessmentContextIosIpados`, `assessmentContextAndroidEnterprise`, `assessmentContextEnrollment`, `assessmentContextIosOwnership`;
    - `assessmentContextWarning`, `assessmentReview`;
    - the import card `assessImportPanel` with heading `assessImportTitle`, and `assessmentImportSummary`.
  - `web\app.js` constants: `assessmentSteps`, `assessmentContextFields`, `assessmentEnrollmentLabels`, `assessmentOwnershipLabels`, `assessmentWindowsWarning`.
  - `web\app.js` functions:
    - `setAssessmentStep(step, focus)`;
    - `assessmentSelection()` → `{ platforms, packs }`, counting checked and enabled boxes only;
    - `assessmentSelectionError()` → a message or `null`;
    - `selectAssessmentPacks(checked)`, `updateAssessmentContext()`, `renderAssessmentReview()`;
    - `blockAssessmentStep(message)`, `moveAssessmentStep(step)`.
  - Messages:
    - "Choose at least one platform to assess."
    - "Every selected platform requires a selected applicable pack; choose at least one platform."
    - "Select 1–64 packs."
    - the empty-pack message and the Windows 11 build warning.
  - Test harness additions that Task 6 uses: the element `id`, `getAttribute`, `d.focused()`, and the helpers `stepIds`, `panelIds`, `isHidden`, `click`, `windowsWarning`, `expectStep`.

- [ ] **Step 1: Extend the assessment test harness**

The harness stays backward-compatible:

- Elements know their ID. Elements from `createElement` get a `Symbol` ID.
- Elements keep their attributes.
- `focus()` records the element ID, and `d.focused()` returns the last focused
  ID, or `null`.

In `tests\assessment-ui.test.js`, inside `assessmentDashboard`, replace this
text (about lines 13–25):

```js
  const alerts = [];
  function element(id) {
    if (!elements.has(id)) {
      const classes = new Set();
      const el = {
        value: '', checked: false, disabled: false, children: [], options: [], handlers: {},
        files: [], textContent: '', style: {}, dataset: {},
        classList: { add(name) { classes.add(name); }, remove(name) { classes.delete(name); },
          contains(name) { return classes.has(name); } },
        addEventListener(event, handler) { this.handlers[event] = handler; },
        appendChild(child) { this.children.push(child); },
        setAttribute() {}, removeAttribute() {}, focus() {},
        scrollIntoView() {}
```

with:

```js
  const alerts = [];
  let focused = null;
  function element(id) {
    if (!elements.has(id)) {
      const classes = new Set();
      const attributes = new Map();
      const el = {
        id, value: '', checked: false, disabled: false, children: [], options: [], handlers: {},
        files: [], textContent: '', style: {}, dataset: {},
        classList: { add(name) { classes.add(name); }, remove(name) { classes.delete(name); },
          contains(name) { return classes.has(name); } },
        addEventListener(event, handler) { this.handlers[event] = handler; },
        appendChild(child) { this.children.push(child); },
        setAttribute(name, value) { attributes.set(name, String(value)); },
        getAttribute(name) { return attributes.has(name) ? attributes.get(name) : null; },
        removeAttribute(name) { attributes.delete(name); },
        focus() { focused = id; },
        scrollIntoView() {}
```

At the end of the same function, replace this text (about line 62):

```js
  return { element, requests, context, timers, alerts,
```

with:

```js
  return { element, requests, context, timers, alerts, focused: () => focused,
```

- [ ] **Step 2: Assert that the import success line moves to the import summary**

In the test `import sends original JSON text and preserves selected pack and
export options on validation failure`, replace this text (about lines 224–225):

```js
  assert.equal(boxes(d, 'assessmentPacks')[0].checked, true);
  reject = true;
```

with:

```js
  assert.equal(boxes(d, 'assessmentPacks')[0].checked, true);
  assert.match(d.element('assessmentImportSummary').textContent, /locally/);
  assert.equal(d.element('assessmentProgress').textContent, '');
  reject = true;
```

In the test `stale import completion and assessment admission cannot
repopulate a reset session`, replace this text (about line 577):

```js
    assert.equal(d.element('assessmentProgress').textContent, '', operation);
```

with:

```js
    assert.equal(d.element('assessmentProgress').textContent, '', operation);
    assert.equal(d.element('assessmentImportSummary').textContent, '', operation);
```

- [ ] **Step 3: Append the wizard tests**

Append this code at the end of `tests\assessment-ui.test.js`, after the closing
`});` of the last test, `shutdown honors server 409 and permits stopping after a
previously observed export finishes` (about line 740). Leave one blank line
before it.

`expectStep(d, number, focusedHeading)` checks four things:

- only panel `number` is visible;
- the stepper marks earlier items `done`, the current item `active` with
  `aria-current="step"`, and later items `''`;
- the import card is visible on steps 1–2 only;
- when `focusedHeading` is given, the last focused element ID.

```js
// --- Assessment wizard -------------------------------------------------------

const stepIds = ['assessStepPlatforms', 'assessStepBaselines', 'assessStepContext', 'assessStepReview',
  'assessStepResults'];
const panelIds = ['assessPanelPlatforms', 'assessPanelBaselines', 'assessPanelContext', 'assessPanelReview',
  'assessPanelResults'];
const isHidden = (d, id) => d.element(id).classList.contains('hidden');
const click = (d, id) => d.element(id).handlers.click();
const windowsWarning = 'Windows policies targeting Windows 10 and later, such as the Settings Catalog policies ' +
  'that CIS build-kit packs map to, are assessed only when a Windows 11 build is entered (for example 10.0.22631 ' +
  'or 10.0.26100); otherwise their controls are reported as not assessed.';

function expectStep(d, number, focusedHeading) {
  assert.deepEqual(panelIds.filter((id) => !isHidden(d, id)), [panelIds[number - 1]]);
  assert.deepEqual(stepIds.map((id) => d.element(id).className),
    stepIds.map((_, i) => (i + 1 < number ? 'done' : i + 1 === number ? 'active' : '')));
  assert.deepEqual(stepIds.map((id) => d.element(id).getAttribute('aria-current')),
    stepIds.map((_, i) => (i + 1 === number ? 'step' : null)));
  assert.equal(isHidden(d, 'assessImportPanel'), number > 2);
  if (focusedHeading !== undefined) assert.equal(d.focused(), focusedHeading);
}

test('wizard Next and Back validate the current step, mark the stepper and focus the new heading', async () => {
  const d = assessmentDashboard((url) => (url === '/api/state' ? connectedState() : {}));
  await new Promise(setImmediate);
  renderCatalog(d);
  expectStep(d, 1, null);
  click(d, 'btnAssessPlatformsNext');
  assert.equal(d.element('assessmentError').textContent, 'Choose at least one platform to assess.');
  assert.equal(isHidden(d, 'assessmentError'), false);
  expectStep(d, 1, null);
  const platforms = boxes(d, 'assessmentPlatforms');
  platforms[0].checked = true;
  platforms[1].checked = true;
  platforms[0].handlers.change();
  click(d, 'btnAssessPlatformsNext');
  assert.equal(isHidden(d, 'assessmentError'), true);
  expectStep(d, 2, 'baselinesTitle');
  boxes(d, 'assessmentPacks')[0].checked = true;
  click(d, 'btnAssessBaselinesNext');
  assert.equal(d.element('assessmentError').textContent,
    'Every selected platform requires a selected applicable pack; choose at least one platform.');
  expectStep(d, 2, 'baselinesTitle');
  boxes(d, 'assessmentPacks')[1].checked = true;
  click(d, 'btnAssessBaselinesNext');
  assert.equal(isHidden(d, 'assessmentError'), true);
  expectStep(d, 3, 'contextTitle');
  click(d, 'btnAssessContextNext');
  expectStep(d, 4, 'runAssessmentTitle');
  click(d, 'btnAssessReviewBack');
  expectStep(d, 3, 'contextTitle');
  click(d, 'btnAssessContextBack');
  expectStep(d, 2, 'baselinesTitle');
  click(d, 'btnAssessBaselinesBack');
  expectStep(d, 1, 'platformsTitle');
  assert.deepEqual(boxes(d, 'assessmentPacks').map((b) => b.checked), [true, true, false, false]);
  renderCatalog(d, Array.from({ length: 65 }, (_, i) => ({ ...syntheticPacks()[0], id: `synthetic-bulk-${i}` })));
  click(d, 'btnAssessPlatformsNext');
  click(d, 'btnAssessmentSelectAll');
  click(d, 'btnAssessBaselinesNext');
  assert.equal(d.element('assessmentError').textContent, 'Select 1–64 packs.');
  expectStep(d, 2);
});

test('background refresh shows a running or completed assessment without moving focus; errors keep the step', async () => {
  for (const progress of [{ running: true, percent: 20, phase: 'Collecting' }, { done: true, percent: 100 }]) {
    const d = assessmentDashboard((url) => {
      if (url === '/api/state') return connectedState();
      if (url === '/api/assessment') return progress;
      if (url === '/api/assessment/results') return { summaries: [], controls: [{ controlId: 'SYN-BOOT' }] };
      return {};
    });
    await new Promise(setImmediate);
    expectStep(d, 5, null);
  }
  let failing = false;
  const d = assessmentDashboard((url) => {
    if (url === '/api/state') return connectedState();
    if (url === '/api/assessment') return failing ? { done: true, error: 'Synthetic report failure.' } : {};
    return {};
  });
  await new Promise(setImmediate);
  expectStep(d, 1, null);
  d.run("setAssessmentStep('context')");
  failing = true;
  await d.run('refreshAssessment()');
  expectStep(d, 3, null);
  assert.match(d.element('assessmentError').textContent, /Synthetic report failure/);
});

test('admission moves to results with focus and New assessment waits for the run, then keeps every choice', async () => {
  let status = 409;
  let started = false;
  let running = false;
  const d = assessmentDashboard((url, r) => {
    if (url === '/api/state') return connectedState();
    if (url === '/api/assessment' && r.method === 'POST') {
      if (status === 409) return { httpStatus: 409, body: { error: 'An export is already running.' } };
      started = true;
      running = true;
      return { httpStatus: 202, body: { started: true } };
    }
    if (url === '/api/assessment') {
      return { running, done: started && !running, percent: running ? 30 : 100, phase: 'Synthetic' };
    }
    if (url === '/api/assessment/results') return { summaries: [], controls: [{ controlId: 'SYN-NEW' }] };
    return {};
  });
  await selectAll(d);
  d.element('assessmentOsMacos').value = '14.0';
  d.element('assessmentEnrollment').value = 'fullyManaged';
  click(d, 'btnAssessPlatformsNext');
  click(d, 'btnAssessBaselinesNext');
  click(d, 'btnAssessContextNext');
  expectStep(d, 4, 'runAssessmentTitle');
  await click(d, 'btnAssessmentRun');
  assert.match(d.element('assessmentError').textContent, /409.*already running/);
  expectStep(d, 4, 'runAssessmentTitle');
  status = 202;
  await click(d, 'btnAssessmentRun');
  expectStep(d, 5, 'resultsTitle');
  assert.equal(d.element('btnAssessNew').disabled, true);
  click(d, 'btnAssessNew');
  expectStep(d, 5, 'resultsTitle');
  running = false;
  await Array.from(d.timers.values())[0]();
  assert.match(d.element('assessmentResults').innerHTML, /SYN-NEW/);
  assert.equal(d.element('btnAssessNew').disabled, false);
  expectStep(d, 5, 'resultsTitle');
  click(d, 'btnAssessNew');
  expectStep(d, 1, 'platformsTitle');
  assert.equal(boxes(d, 'assessmentPlatforms').every((b) => b.checked), true);
  assert.equal(boxes(d, 'assessmentPacks').every((b) => b.checked), true);
  assert.equal(d.element('assessmentOsMacos').value, '14.0');
  assert.equal(d.element('assessmentEnrollment').value, 'fullyManaged');
  assert.equal(d.element('assessmentOutputPath').value, ' C:\\SyntheticReports ');
  assert.match(d.element('assessmentResults').innerHTML, /SYN-NEW/);
});

test('clearing the workspace returns to step 1 and clears the import summary, review and warning', async () => {
  const d = assessmentDashboard((url) => (url === '/api/state' ? connectedState() : {}));
  await selectAll(d);
  click(d, 'btnAssessPlatformsNext');
  click(d, 'btnAssessBaselinesNext');
  click(d, 'btnAssessContextNext');
  d.element('assessmentImportSummary').textContent = 'Synthetic import summary';
  assert.notEqual(d.element('assessmentReview').textContent, '');
  assert.equal(isHidden(d, 'assessmentContextWarning'), false);
  const focused = d.focused();
  d.run('clearWorkspace()');
  expectStep(d, 1, focused);
  for (const id of ['assessmentImportSummary', 'assessmentReview', 'assessmentContextWarning']) {
    assert.equal(d.element(id).textContent, '', id);
  }
  assert.equal(isHidden(d, 'assessmentContextWarning'), true);
});

test('pack rows outside the selected platforms or profile are hidden, with an empty state and scoped Select all/none', () => {
  const d = assessmentDashboard();
  renderCatalog(d);
  const rowsHidden = () => d.element('assessmentPacks').children.map((row) => row.classList.contains('hidden'));
  const checked = () => boxes(d, 'assessmentPacks').map((b) => b.checked);
  const empty = 'No rule pack matches the selected platforms and profile. ' +
    'Choose other platforms or a different profile, or import a pack below.';
  assert.deepEqual(rowsHidden(), [true, true, true, true]);
  assert.equal(d.element('assessmentPacksEmpty').textContent, empty);
  assert.equal(isHidden(d, 'assessmentPacksEmpty'), false);
  const platforms = boxes(d, 'assessmentPlatforms');
  platforms[0].checked = true;
  platforms[3].checked = true;
  platforms[0].handlers.change();
  assert.deepEqual(rowsHidden(), [false, true, true, false]);
  assert.equal(isHidden(d, 'assessmentPacksEmpty'), true);
  assert.equal(d.element('assessmentPacksEmpty').textContent, '');
  click(d, 'btnAssessmentSelectAll');
  assert.deepEqual(checked(), [true, false, false, true]);
  click(d, 'btnAssessmentSelectNone');
  assert.deepEqual(checked(), [false, false, false, false]);
  d.element('assessmentProfile').value = 'Imported test profile';
  d.element('assessmentProfile').handlers.change();
  assert.deepEqual(rowsHidden(), [true, true, true, false]);
  click(d, 'btnAssessmentSelectAll');
  assert.deepEqual(checked(), [false, false, false, true]);
  platforms[3].checked = false;
  platforms[3].handlers.change();
  assert.deepEqual(rowsHidden(), [true, true, true, true]);
  assert.deepEqual(checked(), [false, false, false, false]);
  assert.equal(d.element('assessmentPacksEmpty').textContent, empty);
  assert.equal(isHidden(d, 'assessmentPacksEmpty'), false);
  const html = fs.readFileSync(path.join(__dirname, '..', 'web', 'index.html'), 'utf8');
  assert.match(html, /<div id="assessmentPacks" class="assessment-packs"><\/div>\s*<p id="assessmentPacksEmpty"/);
});

test('context shows only the selected platforms\' fields and warns while the Windows 11 build is blank', () => {
  const d = assessmentDashboard();
  renderCatalog(d);
  const fields = {
    windows11: ['assessmentContextWindows11'],
    macos: ['assessmentContextMacos'],
    iosIpados: ['assessmentContextIosIpados', 'assessmentContextIosOwnership'],
    androidEnterprise: ['assessmentContextAndroidEnterprise', 'assessmentContextEnrollment']
  };
  const platforms = boxes(d, 'assessmentPlatforms');
  Object.keys(fields).forEach((key, i) => {
    platforms.forEach((box, j) => { box.checked = j === i; });
    platforms[0].handlers.change();
    click(d, 'btnAssessPlatformsNext');
    boxes(d, 'assessmentPacks')[i].checked = true;
    click(d, 'btnAssessBaselinesNext');
    expectStep(d, 3, 'contextTitle');
    for (const [platform, ids] of Object.entries(fields)) {
      for (const id of ids) assert.equal(isHidden(d, id), platform !== key, `${key}: ${id}`);
    }
    assert.equal(isHidden(d, 'assessmentContextWarning'), key !== 'windows11', key);
    click(d, 'btnAssessContextBack');
    click(d, 'btnAssessBaselinesBack');
  });
  platforms.forEach((box) => { box.checked = true; });
  platforms[0].handlers.change();
  click(d, 'btnAssessPlatformsNext');
  click(d, 'btnAssessmentSelectAll');
  click(d, 'btnAssessBaselinesNext');
  expectStep(d, 3, 'contextTitle');
  for (const id of Object.values(fields).flat()) assert.equal(isHidden(d, id), false, id);
  assert.equal(d.element('assessmentContextWarning').textContent, windowsWarning);
  d.element('assessmentOsWindows11').value = '10.0.26100';
  d.element('assessmentOsWindows11').handlers.input();
  assert.equal(isHidden(d, 'assessmentContextWarning'), true);
  assert.equal(d.element('assessmentContextWarning').textContent, '');
  d.element('assessmentOsWindows11').value = '   ';
  d.element('assessmentOsWindows11').handlers.input();
  assert.equal(isHidden(d, 'assessmentContextWarning'), false);
  click(d, 'btnAssessContextNext');
  expectStep(d, 4, 'runAssessmentTitle');
});

test('the review lists platforms, packs and every context value as plain text', async () => {
  const d = assessmentDashboard((url) => (url === '/api/state' ? connectedState() : {}));
  await selectAll(d);
  d.element('assessmentOsMacos').value = ' 14.0 ';
  d.element('assessmentEnrollment').value = 'corporateOwnedWorkProfile';
  click(d, 'btnAssessPlatformsNext');
  click(d, 'btnAssessBaselinesNext');
  click(d, 'btnAssessContextNext');
  expectStep(d, 4, 'runAssessmentTitle');
  assert.equal(d.element('assessmentReview').textContent, [
    'Platforms: Windows 11, macOS, iOS/iPadOS, Android Enterprise',
    '',
    'Rule packs:',
    'synthetic-windows11 @ 1.0.0 — Windows 11 · Test profile',
    'synthetic-macos @ 1.0.0 — macOS · Test profile',
    'synthetic-iosipados @ 1.0.0 — iOS/iPadOS · Test profile',
    'synthetic-androidenterprise @ 1.0.0 — Android Enterprise · Imported test profile',
    '',
    'Context (user-selected, not discovered device inventory):',
    'Windows 11 — OS version: Unknown',
    'macOS — OS version: 14.0',
    'iOS/iPadOS — OS version: Unknown; ownership scope: Unknown',
    'Android Enterprise — OS version: Unknown; enrollment mode: Corporate-owned work profile',
    '',
    windowsWarning
  ].join('\n'));
  assert.equal(d.element('assessmentReview').innerHTML, '');
  d.element('assessmentOsWindows11').value = '10.0.22631';
  click(d, 'btnAssessReviewBack');
  click(d, 'btnAssessContextNext');
  assert.match(d.element('assessmentReview').textContent, /Windows 11 — OS version: 10\.0\.22631/);
  assert.equal(d.element('assessmentReview').textContent.includes('Windows policies targeting'), false);
  const html = fs.readFileSync(path.join(__dirname, '..', 'web', 'index.html'), 'utf8');
  for (const select of ['assessmentEnrollment', 'assessmentIosOwnership']) {
    const options = html.match(new RegExp(`id="${select}">([\\s\\S]*?)</select>`))[1];
    const labelled = [...options.matchAll(/<option value="(\w+)">([^<]+)<\/option>/g)];
    assert.ok(labelled.length >= 2, select);
    for (const [, value, label] of labelled) {
      d.element(select).value = value;
      d.run('renderAssessmentReview()');
      assert.ok(d.element('assessmentReview').textContent.includes(label), `${select}: ${value}`);
    }
  }
});
```

- [ ] **Step 4: Add the stepper and markup tests to the shell suite**

These tests use the module-level `html` and `css` strings (`web\index.html` and
`web\style.css`) and the existing helpers `shell`, `stateOnly` and `signedIn`.
In `tests\app-shell-ui.test.js`, insert this code directly before the line
`test('every element the script uses exists exactly once in the page', () => {`
(about line 313), followed by one blank line:

```js
test('the assessment stepper has five numbered steps and wraps at 900 px; the documentation stepper is unchanged', () => {
  const narrow = css.match(/@media \(max-width: 900px\) \{([\s\S]*?)\n\}/);
  assert.ok(narrow, '900 px media query');
  assert.match(narrow[1], /\.stepper\.wide \{ flex-wrap: wrap; \}/);
  assert.match(narrow[1], /\.stepper\.wide li \{ flex: 1 1 140px; \}/);
  assert.match(html, /<ol class="stepper" aria-label="Export steps">/);
  const wizard = html.match(/<ol class="stepper wide" aria-label="Assessment steps">([\s\S]*?)<\/ol>/);
  assert.ok(wizard, 'assessment stepper');
  const items = [...wizard[1].matchAll(
    /<li id="(\w+)"(?: class="active")?><span class="step-num" aria-hidden="true">(\d)<\/span>([^<]+)<\/li>/g
  )].map((m) => [m[1], m[2], m[3]]);
  assert.deepEqual(items, [
    ['assessStepPlatforms', '1', 'Platforms'], ['assessStepBaselines', '2', 'Baselines'],
    ['assessStepContext', '3', 'Context'], ['assessStepReview', '4', 'Review &amp; run'],
    ['assessStepResults', '5', 'Results']
  ]);
  assert.match(wizard[1], /<li id="assessStepPlatforms" class="active">/);
});

test('the assessment wizard opens on step 1 with the import card, and every wizard element exists once', async () => {
  const d = shell({ hash: '#/assess', respond: stateOnly(signedIn()) });
  await d.settle();
  assert.deepEqual(d.visibleViews(), ['viewAssess']);
  const steps = ['assessStepPlatforms', 'assessStepBaselines', 'assessStepContext', 'assessStepReview',
    'assessStepResults'];
  assert.deepEqual(steps.map((id) => [d.element(id).className, d.element(id).getAttribute('aria-current')]),
    [['active', 'step'], ['', null], ['', null], ['', null], ['', null]]);
  const panels = ['assessPanelPlatforms', 'assessPanelBaselines', 'assessPanelContext', 'assessPanelReview',
    'assessPanelResults', 'assessImportPanel'];
  assert.deepEqual(panels.filter((id) => d.visible(id)), ['assessPanelPlatforms', 'assessImportPanel']);
  assert.equal(d.focused(), null);
  d.run("updateAssessmentContext(); renderAssessmentReview(); setAssessmentStep('results', true)");
  assert.equal(d.focused(), 'resultsTitle');
  assert.equal(d.visible('assessImportPanel'), false);
  const headings = ['platformsTitle', 'baselinesTitle', 'contextTitle', 'runAssessmentTitle', 'resultsTitle'];
  for (const id of headings) assert.match(html, new RegExp(`<h3 id="${id}" class="card-title" tabindex="-1">`), id);
  const added = [...steps, ...panels, ...headings, 'assessImportTitle', 'btnAssessPlatformsNext',
    'btnAssessBaselinesBack', 'btnAssessBaselinesNext', 'btnAssessContextBack', 'btnAssessContextNext',
    'btnAssessReviewBack', 'btnAssessNew', 'btnAssessmentSelectAll', 'btnAssessmentSelectNone',
    'assessmentPacksEmpty', 'assessmentContextWarning', 'assessmentReview', 'assessmentImportSummary',
    'assessmentContextWindows11', 'assessmentContextMacos', 'assessmentContextIosIpados',
    'assessmentContextAndroidEnterprise', 'assessmentContextEnrollment', 'assessmentContextIosOwnership'];
  for (const id of added) assert.equal(html.split(` id="${id}"`).length - 1, 1, id);
});
```

- [ ] **Step 5: Run the new tests and see them fail**

Run:

```powershell
node --test .\tests\assessment-ui.test.js .\tests\app-shell-ui.test.js
```

Expected: the summary shows `ℹ tests 51`, `ℹ pass 41` and `ℹ fail 10`. The
failing tests are:

- the 7 new wizard tests in `tests\assessment-ui.test.js`. They fail with
  `AssertionError [ERR_ASSERTION]: Expected values to be strictly deep-equal:`
  (no step state yet) or `TypeError [Error]: d.element(...).handlers.click is
  not a function` (no wizard buttons yet).
- `import sends original JSON text and preserves selected pack and export
  options on validation failure`, with `The input did not match the regular
  expression /locally/`.
- `the assessment stepper has five numbered steps and wraps at 900 px; the
  documentation stepper is unchanged`, with `The input did not match the
  regular expression /\.stepper\.wide \{ flex-wrap: wrap; \}/`.
- `the assessment wizard opens on step 1 with the import card, and every wizard
  element exists once`, with `Expected values to be strictly deep-equal:`.

The other 41 tests pass: 25 existing assessment tests and 16 existing shell
tests.

- [ ] **Step 6: Restructure the assessment view as five panels and an import card**

In `web\index.html`, inside `<section id="viewAssess" ...>`, replace the whole
`#cardAssessment` block (about lines 303–413). It starts at the line after the
blank line that follows the page head's `</header>`. It ends with the `    </div>`
directly before the `  </section>` that closes `#viewAssess`. Keep that
`  </section>`, the blank line and `</main>`. The block to replace is:

```html
    <div id="cardAssessment" class="stack">
      <section class="card" aria-labelledby="baselinesTitle">
        <h3 id="baselinesTitle" class="card-title">Baselines</h3>
        <div id="assessmentCatalogNote" class="notice"></div>
        <p id="assessmentCatalogErrors" class="muted assessment-text" role="status"></p>
        <fieldset>
          <legend>Target platforms</legend>
          <div id="assessmentPlatforms" class="options"></div>
        </fieldset>
        <label>Benchmark profile filter
          <select id="assessmentProfile"><option value="">All available profiles</option></select>
          <small>Select exact pack versions/profiles below; unavailable combinations cannot run.</small>
        </label>
        <fieldset>
          <legend>Rule packs, versions and profiles</legend>
          <div id="assessmentPacks" class="assessment-packs"></div>
        </fieldset>
        <details class="disclosure">
          <summary>Import a rule pack</summary>
          <div class="disclosure-body">
            <label>Import a local rule pack (JSON)
              <input type="file" id="assessmentImportFile" accept=".json,application/json">
              <small>Customer-owned/licensed CIS content is not bundled or downloaded. Maximum 10 MiB UTF-8 JSON,
                32 nesting levels, 20,000 controls, 32,768 characters per string. The server validates the original text.</small>
            </label>
            <button class="btn" id="btnAssessmentImport">Import pack</button>
          </div>
        </details>
      </section>

      <section class="card" aria-labelledby="contextTitle">
        <h3 id="contextTitle" class="card-title">User-selected applicability context <span class="muted">(optional)</span></h3>
        <p class="muted">Not discovered device inventory. Leave unknown values blank; controls requiring unknown context
          remain not assessed. The catalog does not include per-control applicability bounds.</p>
        <div class="grid2">
          <label>Windows 11 OS version <input type="text" id="assessmentOsWindows11" placeholder="Unknown (for example 10.0.22000)"></label>
          <label>macOS version <input type="text" id="assessmentOsMacos" placeholder="Unknown (for example 14.0)"></label>
          <label>iOS/iPadOS version <input type="text" id="assessmentOsIosIpados" placeholder="Unknown"></label>
          <label>Android Enterprise OS version <input type="text" id="assessmentOsAndroidEnterprise" placeholder="Unknown"></label>
        </div>
        <div class="grid2">
          <label>Android Enterprise enrollment mode (user-selected)
            <select id="assessmentEnrollment">
              <option value="">Unknown</option>
              <option value="workProfile">Personally-owned work profile</option>
              <option value="fullyManaged">Fully managed</option>
              <option value="dedicated">Dedicated</option>
              <option value="corporateOwnedWorkProfile">Corporate-owned work profile</option>
            </select>
          </label>
          <label>iOS/iPadOS ownership scope (user-selected comparison context)
            <select id="assessmentIosOwnership">
              <option value="">Unknown</option>
              <option value="personallyOwned">Personally owned</option>
              <option value="corporateOwned">Corporate owned (excluded by personal-only guidance)</option>
            </select>
            <small>This is explicit comparison context, not discovered ownership or effective assignment.</small>
          </label>
        </div>
      </section>

      <section class="card" aria-labelledby="runAssessmentTitle">
        <h3 id="runAssessmentTitle" class="card-title">Run</h3>
        <label>Assessment report destination
          <input type="text" id="assessmentOutputPath" spellcheck="false" placeholder="Absolute local folder, separate from application and export">
          <small>A new run subdirectory contains assessment.md and assessment.json. Installation/export overlap is rejected by the server.</small>
        </label>
        <div class="row">
          <button class="btn primary" id="btnAssessmentRun" disabled>Assess selected policies</button>
          <button class="btn ghost" id="btnAssessmentRefresh">Refresh assessment</button>
        </div>
        <p id="assessmentError" class="error hidden" role="alert"></p>
        <div class="progress"><div id="assessmentBar" class="bar"></div></div>
        <p id="assessmentProgress" class="phase" role="status" aria-live="polite"></p>
      </section>

      <section class="card" aria-labelledby="resultsTitle">
        <h3 id="resultsTitle" class="card-title">Results</h3>
        <p id="assessmentReportPaths" class="assessment-text"></p>
        <p id="assessmentLimitations" class="muted"></p>
        <div id="assessmentSummary"></div>
        <details class="disclosure">
          <summary>Assessment context, pack identities and collection completeness</summary>
          <div class="disclosure-body">
            <p id="assessmentContextResult" class="assessment-text"></p>
            <p id="assessmentPackResult" class="assessment-text"></p>
            <p id="assessmentIssues" class="assessment-text"></p>
            <div id="assessmentPolicies"></div>
          </div>
        </details>
        <label class="filter">Filter evidence by status
          <select id="assessmentStatusFilter">
            <option value="">All statuses</option>
            <option value="aligned">Aligned</option>
            <option value="misaligned">Misaligned</option>
            <option value="missing">Missing</option>
            <option value="potentialConflict">Potential conflict</option>
            <option value="notApplicable">Not applicable</option>
            <option value="notAssessed">Not assessed</option>
          </select>
        </label>
        <div class="assessment-table-wrap">
          <table class="assessment-table">
            <caption>Configured policy evidence — not effective device targeting</caption>
            <thead><tr><th scope="col">Control / references</th><th scope="col">Status / reason</th>
              <th scope="col">Expected / configured values</th><th scope="col">Source policies / assignments</th></tr></thead>
            <tbody id="assessmentResults"></tbody>
          </table>
        </div>
      </section>
    </div>
```

Replace it with the block below. In the new layout:

- The stepper and `assessmentError` come first. The stepper copies the
  documentation stepper markup (`<ol class="stepper">`, `step-num` spans) and
  adds the `wide` class.
- Every panel heading has `tabindex="-1"`, so focus can move to it.
- Panels 2–5 start hidden.
- `assessmentPacksEmpty` sits outside `#assessmentPacks`, so row `i` stays
  pack `i`.
- The wizard buttons sit in `.actions` divs, like `#cardConfigure`.
- The results panel puts **New assessment** and **Refresh assessment** in a
  `.row` under the progress line.
- `assessmentCatalogErrors` moves into the import card.

```html
    <ol class="stepper wide" aria-label="Assessment steps">
      <li id="assessStepPlatforms" class="active"><span class="step-num" aria-hidden="true">1</span>Platforms</li>
      <li id="assessStepBaselines"><span class="step-num" aria-hidden="true">2</span>Baselines</li>
      <li id="assessStepContext"><span class="step-num" aria-hidden="true">3</span>Context</li>
      <li id="assessStepReview"><span class="step-num" aria-hidden="true">4</span>Review &amp; run</li>
      <li id="assessStepResults"><span class="step-num" aria-hidden="true">5</span>Results</li>
    </ol>

    <p id="assessmentError" class="error hidden" role="alert"></p>

    <div id="cardAssessment" class="stack">
      <section class="card" id="assessPanelPlatforms" aria-labelledby="platformsTitle">
        <h3 id="platformsTitle" class="card-title" tabindex="-1">Choose platforms</h3>
        <fieldset>
          <legend>Target platforms</legend>
          <div id="assessmentPlatforms" class="options"></div>
        </fieldset>
        <div class="actions">
          <button class="btn primary" id="btnAssessPlatformsNext">Next</button>
        </div>
      </section>

      <section class="card hidden" id="assessPanelBaselines" aria-labelledby="baselinesTitle">
        <h3 id="baselinesTitle" class="card-title" tabindex="-1">Baselines</h3>
        <div id="assessmentCatalogNote" class="notice"></div>
        <label>Benchmark profile filter
          <select id="assessmentProfile"><option value="">All available profiles</option></select>
          <small>Select exact pack versions/profiles below; unavailable combinations cannot run.</small>
        </label>
        <fieldset>
          <legend>Rule packs, versions and profiles</legend>
          <div class="assessment-pack-actions">
            <button class="btn small ghost" id="btnAssessmentSelectAll">Select all</button>
            <button class="btn small ghost" id="btnAssessmentSelectNone">Select none</button>
          </div>
          <div id="assessmentPacks" class="assessment-packs"></div>
          <p id="assessmentPacksEmpty" class="muted hidden"></p>
        </fieldset>
        <div class="actions">
          <button class="btn ghost" id="btnAssessBaselinesBack">Back</button>
          <button class="btn primary" id="btnAssessBaselinesNext">Next</button>
        </div>
      </section>

      <section class="card hidden" id="assessPanelContext" aria-labelledby="contextTitle">
        <h3 id="contextTitle" class="card-title" tabindex="-1">User-selected applicability context <span class="muted">(optional)</span></h3>
        <p class="muted">Not discovered device inventory. Leave unknown values blank; controls requiring unknown context
          remain not assessed. The catalog does not include per-control applicability bounds.</p>
        <div class="grid2">
          <label id="assessmentContextWindows11">Windows 11 OS version <input type="text" id="assessmentOsWindows11" placeholder="Unknown (for example 10.0.22000)"></label>
          <label id="assessmentContextMacos">macOS version <input type="text" id="assessmentOsMacos" placeholder="Unknown (for example 14.0)"></label>
          <label id="assessmentContextIosIpados">iOS/iPadOS version <input type="text" id="assessmentOsIosIpados" placeholder="Unknown"></label>
          <label id="assessmentContextAndroidEnterprise">Android Enterprise OS version <input type="text" id="assessmentOsAndroidEnterprise" placeholder="Unknown"></label>
        </div>
        <div class="grid2">
          <label id="assessmentContextEnrollment">Android Enterprise enrollment mode (user-selected)
            <select id="assessmentEnrollment">
              <option value="">Unknown</option>
              <option value="workProfile">Personally-owned work profile</option>
              <option value="fullyManaged">Fully managed</option>
              <option value="dedicated">Dedicated</option>
              <option value="corporateOwnedWorkProfile">Corporate-owned work profile</option>
            </select>
          </label>
          <label id="assessmentContextIosOwnership">iOS/iPadOS ownership scope (user-selected comparison context)
            <select id="assessmentIosOwnership">
              <option value="">Unknown</option>
              <option value="personallyOwned">Personally owned</option>
              <option value="corporateOwned">Corporate owned (excluded by personal-only guidance)</option>
            </select>
            <small>This is explicit comparison context, not discovered ownership or effective assignment.</small>
          </label>
        </div>
        <p id="assessmentContextWarning" class="notice hidden"></p>
        <div class="actions">
          <button class="btn ghost" id="btnAssessContextBack">Back</button>
          <button class="btn primary" id="btnAssessContextNext">Next</button>
        </div>
      </section>

      <section class="card hidden" id="assessPanelReview" aria-labelledby="runAssessmentTitle">
        <h3 id="runAssessmentTitle" class="card-title" tabindex="-1">Review and run</h3>
        <p id="assessmentReview" class="assessment-text"></p>
        <label>Assessment report destination
          <input type="text" id="assessmentOutputPath" spellcheck="false" placeholder="Absolute local folder, separate from application and export">
          <small>A new run subdirectory contains assessment.md and assessment.json. Installation/export overlap is rejected by the server.</small>
        </label>
        <div class="actions">
          <button class="btn ghost" id="btnAssessReviewBack">Back</button>
          <button class="btn primary" id="btnAssessmentRun" disabled>Assess selected policies</button>
        </div>
      </section>

      <section class="card hidden" id="assessPanelResults" aria-labelledby="resultsTitle">
        <h3 id="resultsTitle" class="card-title" tabindex="-1">Results</h3>
        <div class="progress"><div id="assessmentBar" class="bar"></div></div>
        <p id="assessmentProgress" class="phase" role="status" aria-live="polite"></p>
        <div class="row">
          <button class="btn primary" id="btnAssessNew">New assessment</button>
          <button class="btn ghost" id="btnAssessmentRefresh">Refresh assessment</button>
        </div>
        <p id="assessmentReportPaths" class="assessment-text"></p>
        <p id="assessmentLimitations" class="muted"></p>
        <div id="assessmentSummary"></div>
        <details class="disclosure">
          <summary>Assessment context, pack identities and collection completeness</summary>
          <div class="disclosure-body">
            <p id="assessmentContextResult" class="assessment-text"></p>
            <p id="assessmentPackResult" class="assessment-text"></p>
            <p id="assessmentIssues" class="assessment-text"></p>
            <div id="assessmentPolicies"></div>
          </div>
        </details>
        <label class="filter">Filter evidence by status
          <select id="assessmentStatusFilter">
            <option value="">All statuses</option>
            <option value="aligned">Aligned</option>
            <option value="misaligned">Misaligned</option>
            <option value="missing">Missing</option>
            <option value="potentialConflict">Potential conflict</option>
            <option value="notApplicable">Not applicable</option>
            <option value="notAssessed">Not assessed</option>
          </select>
        </label>
        <div class="assessment-table-wrap">
          <table class="assessment-table">
            <caption>Configured policy evidence — not effective device targeting</caption>
            <thead><tr><th scope="col">Control / references</th><th scope="col">Status / reason</th>
              <th scope="col">Expected / configured values</th><th scope="col">Source policies / assignments</th></tr></thead>
            <tbody id="assessmentResults"></tbody>
          </table>
        </div>
      </section>

      <section class="card" id="assessImportPanel" aria-labelledby="assessImportTitle">
        <h3 id="assessImportTitle" class="card-title">Import rule packs</h3>
        <label>Import a local rule pack (JSON)
          <input type="file" id="assessmentImportFile" accept=".json,application/json">
          <small>Customer-owned/licensed CIS content is not bundled or downloaded. Maximum 10 MiB UTF-8 JSON,
            32 nesting levels, 20,000 controls, 32,768 characters per string. The server validates the original text.</small>
        </label>
        <button class="btn" id="btnAssessmentImport">Import pack</button>
        <p id="assessmentImportSummary" class="assessment-text" role="status"></p>
        <p id="assessmentCatalogErrors" class="muted assessment-text" role="status"></p>
      </section>
    </div>
```

Confirm that every existing element ID is still present exactly once. Run:

```powershell
$old = [regex]::Matches((git --no-pager show HEAD:web/index.html | Out-String), '\sid="([^"]+)"') | ForEach-Object { $_.Groups[1].Value }
$new = [regex]::Matches((Get-Content -Raw .\web\index.html), '\sid="([^"]+)"') | ForEach-Object { $_.Groups[1].Value }
$old | Where-Object { @($new -ceq $_).Count -ne 1 } | ForEach-Object { "Missing or duplicated: $_" }
"$($old.Count) -> $($new.Count) ids"
```

Expected: only `123 -> 155 ids`.

- [ ] **Step 7: Add the wizard styles**

The first edit spaces three elements: the error line under the stepper, the
catalog note above the profile filter, and the Select all/none row. In
`web\style.css`, under `/* --- Assessment --- */`, replace this text (about
line 440):

```css
.assessment-packs { display: grid; gap: 12px; }
```

with:

```css
#assessmentError { margin: 0 0 20px; }
#assessmentCatalogNote { margin: 0 0 16px; }
.assessment-pack-actions { display: flex; flex-wrap: wrap; gap: 8px; margin: 0 0 12px; }
.assessment-packs { display: grid; gap: 12px; }
```

The five-step stepper wraps on narrow screens. The documentation stepper (no
`wide` class) does not change. At the end of the `@media (max-width: 900px)`
block, replace this text (about lines 476–479):

```css
  .sections { grid-template-columns: repeat(2, minmax(0, 1fr)); }
}

@media (max-width: 640px) {
```

with:

```css
  .sections { grid-template-columns: repeat(2, minmax(0, 1fr)); }
  .stepper.wide { flex-wrap: wrap; }
  .stepper.wide li { flex: 1 1 140px; }
}

@media (max-width: 640px) {
```

- [ ] **Step 8: Hide unavailable pack rows and show the empty state**

Rows are disabled, unchecked and hidden when their platform is not selected or
their profile does not match the filter. When no row is enabled,
`assessmentPacksEmpty` shows the empty-state text. In `web\app.js`, replace this
text (about lines 655–664):

```js
function updateAssessmentSelection() {
  const platforms = assessmentPlatformBoxes().filter((b) => b.checked).map((b) => b.value);
  const profile = $('assessmentProfile').value;
  assessmentPackBoxes().forEach((b, i) => {
    const pack = assessmentPacks[i];
    b.disabled = !platforms.includes(pack.platform) || (!!profile && profile !== pack.profile);
    if (b.disabled) b.checked = false;
  });
  syncJobAdmission();
}
```

with:

```js
function updateAssessmentSelection() {
  const platforms = assessmentPlatformBoxes().filter((b) => b.checked).map((b) => b.value);
  const profile = $('assessmentProfile').value;
  let enabled = 0;
  // Row i is pack i; the empty state sits outside #assessmentPacks to keep that mapping.
  Array.from($('assessmentPacks').children).forEach((label, i) => {
    const box = label.children[0];
    const pack = assessmentPacks[i];
    box.disabled = !platforms.includes(pack.platform) || (!!profile && profile !== pack.profile);
    if (box.disabled) {
      box.checked = false;
      label.classList.add('hidden');
    } else {
      enabled++;
      label.classList.remove('hidden');
    }
  });
  $('assessmentPacksEmpty').textContent = enabled ? '' : 'No rule pack matches the selected platforms and profile. ' +
    'Choose other platforms or a different profile, or import a pack below.';
  setHidden('assessmentPacksEmpty', enabled > 0);
  syncJobAdmission();
}
```

- [ ] **Step 9: Add the wizard state, helpers and navigation handlers**

What the block does:

- `setAssessmentStep(step, focus)` mirrors `setDocumentStep`:
  - earlier stepper items get `done`;
  - the current item gets `active` and `aria-current="step"`;
  - later items get `''`;
  - only the current panel is shown;
  - the import card is shown on steps 1–2 only;
  - with `focus`, it scrolls to the top and focuses the heading.
- `assessmentSelection()` counts checked and enabled boxes only.
- `assessmentSelectionError()` is used by the Baselines Next button only. The
  run handler keeps its own messages.
- `moveAssessmentStep(step)`:
  - clears the error;
  - prepares step 3 (context fields and warning) or step 4 (review);
  - moves focus to the new heading.
- `blockAssessmentStep(message)` shows the message and scrolls it into view.
  Focus stays on the button.
- **New assessment** ignores clicks while an assessment runs. Step 10 also
  disables the button.

In `web\app.js`, find this text, which directly follows the function from
Step 8:

```js
$('assessmentProfile').addEventListener('change', updateAssessmentSelection);

function showAssessmentError(message) {
```

Insert this block between the blank line and
`function showAssessmentError(message) {`, followed by one blank line:

```js
// Wizard steps are client state, not routes, so the current step survives navigating Home and back.
const assessmentSteps = {
  platforms: ['assessStepPlatforms', 'assessPanelPlatforms', 'platformsTitle'],
  baselines: ['assessStepBaselines', 'assessPanelBaselines', 'baselinesTitle'],
  context: ['assessStepContext', 'assessPanelContext', 'contextTitle'],
  review: ['assessStepReview', 'assessPanelReview', 'runAssessmentTitle'],
  results: ['assessStepResults', 'assessPanelResults', 'resultsTitle']
};
const assessmentContextFields = {
  windows11: ['assessmentContextWindows11'],
  macos: ['assessmentContextMacos'],
  iosIpados: ['assessmentContextIosIpados', 'assessmentContextIosOwnership'],
  androidEnterprise: ['assessmentContextAndroidEnterprise', 'assessmentContextEnrollment']
};
// These mirror the <option> labels in index.html; the review must not depend on selectedIndex.
const assessmentEnrollmentLabels = {
  workProfile: 'Personally-owned work profile', fullyManaged: 'Fully managed', dedicated: 'Dedicated',
  corporateOwnedWorkProfile: 'Corporate-owned work profile'
};
const assessmentOwnershipLabels = {
  personallyOwned: 'Personally owned', corporateOwned: 'Corporate owned (excluded by personal-only guidance)'
};
const assessmentWindowsWarning = 'Windows policies targeting Windows 10 and later, such as the Settings Catalog ' +
  'policies that CIS build-kit packs map to, are assessed only when a Windows 11 build is entered ' +
  '(for example 10.0.22631 or 10.0.26100); otherwise their controls are reported as not assessed.';

function setAssessmentStep(step, focus) {
  const order = Object.keys(assessmentSteps);
  const current = order.indexOf(step);
  order.forEach((name, i) => {
    const [item, panel] = assessmentSteps[name];
    $(item).className = i < current ? 'done' : i === current ? 'active' : '';
    if (i === current) $(item).setAttribute('aria-current', 'step');
    else $(item).removeAttribute('aria-current');
    setHidden(panel, i !== current);
  });
  setHidden('assessImportPanel', current > 1);
  if (!focus) return;
  window.scrollTo(0, 0);
  $(assessmentSteps[step][2]).focus({ preventScroll: true });
}

function assessmentSelection() {
  const platforms = assessmentPlatformBoxes().filter((b) => b.checked && !b.disabled).map((b) => b.value);
  const identities = new Set(assessmentPackBoxes().filter((b) => b.checked && !b.disabled).map((b) => b.value));
  return { platforms, packs: assessmentPacks.filter((p) => identities.has(assessmentIdentity(p))) };
}

function assessmentSelectionError() {
  const { platforms, packs } = assessmentSelection();
  if (!platforms.length || platforms.some((p) => !packs.some((pack) => pack.platform === p))) {
    return 'Every selected platform requires a selected applicable pack; choose at least one platform.';
  }
  return !packs.length || packs.length > 64 ? 'Select 1–64 packs.' : null;
}

function selectAssessmentPacks(checked) {
  assessmentPackBoxes().forEach((b) => { if (!b.disabled) b.checked = checked; });
  updateAssessmentSelection();
}

function updateAssessmentContext() {
  const { platforms } = assessmentSelection();
  Object.entries(assessmentContextFields).forEach(([platform, ids]) => {
    ids.forEach((id) => setHidden(id, !platforms.includes(platform)));
  });
  const warn = platforms.includes('windows11') && !$('assessmentOsWindows11').value.trim();
  $('assessmentContextWarning').textContent = warn ? assessmentWindowsWarning : '';
  setHidden('assessmentContextWarning', !warn);
}

function renderAssessmentReview() {
  const { platforms, packs } = assessmentSelection();
  const context = platforms.map((p) => {
    let line = `${assessmentPlatforms[p]} — OS version: ${$(assessmentOsId(p)).value.trim() || 'Unknown'}`;
    if (p === 'iosIpados') {
      line += '; ownership scope: ' + (assessmentOwnershipLabels[$('assessmentIosOwnership').value] || 'Unknown');
    }
    if (p === 'androidEnterprise') {
      line += '; enrollment mode: ' + (assessmentEnrollmentLabels[$('assessmentEnrollment').value] || 'Unknown');
    }
    return line;
  });
  const lines = [
    'Platforms: ' + (platforms.map((p) => assessmentPlatforms[p]).join(', ') || 'none'),
    '',
    'Rule packs:',
    ...(packs.length ? packs.map((p) => `${p.id} @ ${p.version} — ${assessmentPlatforms[p.platform]} · ${p.profile}`)
      : ['none']),
    '',
    'Context (user-selected, not discovered device inventory):',
    ...context
  ];
  if (platforms.includes('windows11') && !$('assessmentOsWindows11').value.trim()) {
    lines.push('', assessmentWindowsWarning);
  }
  $('assessmentReview').textContent = lines.join('\n');
}

function blockAssessmentStep(message) {
  showAssessmentError(message);
  $('assessmentError').scrollIntoView({ block: 'nearest' });
}

function moveAssessmentStep(step) {
  showAssessmentError(null);
  if (step === 'context') updateAssessmentContext();
  if (step === 'review') renderAssessmentReview();
  setAssessmentStep(step, true);
}

$('btnAssessmentSelectAll').addEventListener('click', () => selectAssessmentPacks(true));
$('btnAssessmentSelectNone').addEventListener('click', () => selectAssessmentPacks(false));
$('assessmentOsWindows11').addEventListener('input', updateAssessmentContext);
$('btnAssessPlatformsNext').addEventListener('click', () => {
  if (!assessmentSelection().platforms.length) blockAssessmentStep('Choose at least one platform to assess.');
  else moveAssessmentStep('baselines');
});
$('btnAssessBaselinesBack').addEventListener('click', () => moveAssessmentStep('platforms'));
$('btnAssessBaselinesNext').addEventListener('click', () => {
  const error = assessmentSelectionError();
  if (error) blockAssessmentStep(error);
  else moveAssessmentStep('context');
});
$('btnAssessContextBack').addEventListener('click', () => moveAssessmentStep('baselines'));
$('btnAssessContextNext').addEventListener('click', () => moveAssessmentStep('review'));
$('btnAssessReviewBack').addEventListener('click', () => moveAssessmentStep('context'));
$('btnAssessNew').addEventListener('click', () => {
  if (!assessmentBusy) moveAssessmentStep('platforms');
});
```

- [ ] **Step 10: Disable New assessment while running, and reset the wizard on clear**

In `web\app.js`, in `syncJobAdmission()`, replace this text (about line 678):

```js
  $('btnAssessmentImport').disabled = busy || assessmentImporting;
```

with:

```js
  $('btnAssessmentImport').disabled = busy || assessmentImporting;
  $('btnAssessNew').disabled = assessmentBusy;
```

`clearAssessment()` runs on sign-out, on workspace changes, and on a 404 or
stale idle state. It now also clears the import summary, the review and the
Windows warning, and returns to step 1 without moving focus. Replace this text
at the end of `clearAssessment()` (about lines 706–710):

```js
  $('assessmentIosOwnership').value = '';
  showAssessmentError(null);
  syncJobAdmission();
}
```

with:

```js
  $('assessmentIosOwnership').value = '';
  ['assessmentImportSummary', 'assessmentReview', 'assessmentContextWarning'].forEach((id) => { $(id).textContent = ''; });
  setHidden('assessmentContextWarning', true);
  showAssessmentError(null);
  setAssessmentStep('platforms');
  syncJobAdmission();
}
```

- [ ] **Step 11: Show step 5 for running, completed and admitted assessments**

In `refreshAssessment()`, a running assessment shows step 5 without moving
focus. Replace this text (about lines 767–770):

```js
      clearAssessmentEvidence();
      throw new Error(progress.error);
    }
    if (progress.done) {
```

with:

```js
      clearAssessmentEvidence();
      throw new Error(progress.error);
    }
    if (progress.running) setAssessmentStep('results');
    if (progress.done) {
```

A completed assessment shows step 5 only after its results render. A results
error throws before this line, so the step does not change. Replace this text
(about lines 781–782):

```js
      renderAssessmentResult(results.body);
      $('assessmentBar').style.width = percent + '%';
```

with:

```js
      renderAssessmentResult(results.body);
      setAssessmentStep('results');
      $('assessmentBar').style.width = percent + '%';
```

In the `btnAssessmentRun` click handler, read the selection through the shared
helper. The validation and messages that follow stay unchanged. After Step 9,
the `const platforms` and `const identities` lines also appear inside
`assessmentSelection()`, so match the snippet from the `Sign in` line. Replace
this text (about lines 802–805):

```js
  if (!state?.auth?.connected) { showAssessmentError('Sign in before assessing policies.'); return; }
  const platforms = assessmentPlatformBoxes().filter((b) => b.checked && !b.disabled).map((b) => b.value);
  const identities = new Set(assessmentPackBoxes().filter((b) => b.checked && !b.disabled).map((b) => b.value));
  const selectedPacks = assessmentPacks.filter((p) => identities.has(assessmentIdentity(p)));
```

with:

```js
  if (!state?.auth?.connected) { showAssessmentError('Sign in before assessing policies.'); return; }
  const { platforms, packs: selectedPacks } = assessmentSelection();
```

Admission (HTTP 202) is a user action, so it moves focus to the Results
heading. A failed run throws before this line and stays on the current step.
Replace this text (about lines 842–843):

```js
    $('assessmentProgress').textContent = 'Assessment admitted. Collecting policy evidence…';
    startAssessmentPolling();
```

with:

```js
    $('assessmentProgress').textContent = 'Assessment admitted. Collecting policy evidence…';
    setAssessmentStep('results', true);
    startAssessmentPolling();
```

- [ ] **Step 12: Write import results to the import card, and start on step 1**

In the `btnAssessmentImport` click handler, clear the previous summary when an
import starts. Replace this text (about lines 867–869):

```js
  showAssessmentError(null);
  try {
    const file = $('assessmentImportFile').files[0];
```

with:

```js
  showAssessmentError(null);
  $('assessmentImportSummary').textContent = '';
  try {
    const file = $('assessmentImportFile').files[0];
```

Then replace this text (about line 886):

```js
    $('assessmentProgress').textContent = 'Pack validated and imported locally. Select its platform/profile to assess.';
```

with:

```js
    $('assessmentImportSummary').textContent =
      'Pack validated and imported locally. Select its platform/profile to assess.';
```

At start-up, set step 1 next to the documentation step. `setDocumentStep('configure');`
occurs three times in the file; this snippet with `start();` occurs once.
Replace this text (about lines 996–998):

```js
  setDocumentStep('configure');
  start();
})();
```

with:

```js
  setDocumentStep('configure');
  setAssessmentStep('platforms');
  start();
})();
```

- [ ] **Step 13: Run the new tests and see them pass**

Run:

```powershell
node --test .\tests\assessment-ui.test.js .\tests\app-shell-ui.test.js
```

Expected: `ℹ tests 51`, `ℹ pass 51`, `ℹ fail 0`.

- [ ] **Step 14: Run the regression suite**

Run:

```powershell
node --test .\tests\publishing-ui.test.js .\tests\assessment-ui.test.js .\tests\app-shell-ui.test.js
pwsh -NoProfile -File .\scripts\Test-Repository.ps1; $LASTEXITCODE
git --no-pager diff --stat
```

Expected:

- The Node summary shows `ℹ tests 58`, `ℹ pass 58`, `ℹ fail 0`: 9 new tests,
  plus the 49 that passed before this task.
- `Test-Repository.ps1` prints `Repository guidance and local policy checks
  passed.` and then `0`. It may first print `Pull request target policy: not
  applicable without pull request event context.`
- The diff stat lists exactly these 5 files: `tests/app-shell-ui.test.js`,
  `tests/assessment-ui.test.js`, `web/app.js`, `web/index.html` and
  `web/style.css`. It shows `5 files changed, 567 insertions(+), 42
  deletions(-)`.

Optionally, check that no LF-only line endings slipped into the edited files:

```powershell
'web\index.html','web\app.js','web\style.css','tests\assessment-ui.test.js','tests\app-shell-ui.test.js' |
  ForEach-Object { '{0}: {1}' -f $_, ([regex]::Matches((Get-Content -Raw $_), '(?<!\r)\n')).Count }
```

Expected: every count is `0`.

- [ ] **Step 15: Commit**

Run:

```powershell
git add web\index.html web\app.js web\style.css tests\assessment-ui.test.js tests\app-shell-ui.test.js
git commit -m "feat: add the five-step assessment wizard" -m "Co-authored-by: Copilot App <223556219+Copilot@users.noreply.github.com>"
```

Expected: one commit with `5 files changed`. If the opt-in pre-commit hook is
installed, it passes.

### Task 6: ZIP rule-pack import in the UI

Let the **Import rule packs** card accept a licensed CIS Intune build-kit ZIP
archive as well as a JSON rule pack. The browser reads the ZIP, base64-encodes
it and posts `{ archive }` to the existing `POST /api/assessment/packs`
endpoint. Task 4 adds the server side.

The import summary lists:

- every imported pack;
- the skipped archive entries;
- the count of ignored files.

Imported packs merge into the catalog without being selected, and catalog
errors are kept. The catalog note now names the supported import formats.

This task covers the import card, the error handling and the import response
shape in Part B of the design spec
(`docs\superpowers\specs\2026-10-29-assessment-wizard-and-cis-zip-import-design.md`).

Notes for this task:

- Line numbers refer to the files after Task 5. Find each edit by its exact
  current text; every "replace this text" snippet occurs exactly once in its
  file.
- All three files use CRLF line endings. Keep CRLF.
- The UI tests fake the API, so this task does not depend on Tasks 1–4.
- The UI tests run `web\app.js` in a Node `vm` with a fake DOM built by
  `assessmentDashboard(respond)` in `tests\assessment-ui.test.js`.
  - `respond(url, request)` returns `{ httpStatus, body }`.
  - Files are plain objects with `name`, `size`, and `text()` and/or
    `arrayBuffer()`.
  - Task 5 added `click(d, id)`, which calls the element's click handler and
    returns its promise, and the handler clears `assessmentImportSummary` when
    an import starts.
  - The VM context exposes only the globals the harness passes, so Step 1 adds
    Node's `btoa`.
- The file type is decided by name only:
  - `/\.zip$/i` is a ZIP archive and `/\.json$/i` is a JSON rule pack.
  - Any other name, including `kit.zip.txt`, and no file at all get "Choose a
    JSON rule pack (at most 10 MiB) or a ZIP archive (at most 32 MiB)."
  - Sizes are checked before any read. A rejected file is never read.
- Base64 encoding:
  - The bytes become a binary string in 0x8000-byte chunks
    (`String.fromCharCode.apply`), which keeps the call within argument
    limits.
  - `btoa` then runs once over the whole string. Encoding each chunk
    separately would put padding mid-stream, because 0x8000 is not a multiple
    of 3.
- Both response shapes are normalized to a list: `{ pack }` for JSON and
  `{ packs, ... }` for a ZIP.
- Summary wording:
  - Singular and plural forms replace "(s)": "1 rule pack", "2 rule packs",
    "1 control", "1 archive entry", "1 other file was ignored".
  - A numeric top-level `added` adds the line "N new, M already present."
- An error response with a `skipped` array is the HTTP 400 for an archive with
  nothing importable.
  - The error shows in `assessmentError`.
  - The summary shows "Nothing was imported." with the skipped and ignored
    lines.
  - Other failures (413, network, 401) keep their existing behavior, and the
    summary stays empty.
- No existing test assertion changes; the harness gains `btoa` only.
  - The existing bounds test checks only that `.pdf`, oversized and empty JSON
    files are not read, and that a decoded pack over 10 MiB matches `/10 MiB/`.
  - It keeps passing, because it does not assert the `.pdf` message text.
- The catalog note is rewritten in this task because it names the ZIP import.
  - It states that CIS content is never bundled, that a licensed CIS Intune
    build-kit ZIP or a schema-1 JSON rule pack can be imported, and that PDF
    and Excel benchmarks are not supported.
  - It keeps every word the existing catalog test requires
    (case-insensitive): "unavailable", "five bundled checks", "legacy",
    "personal", "beta", "deprecated" and "modern".

**Files:**

- Modify: `web\app.js`:
  - about line 574, the assessment state variables;
  - lines 587–596, `renderAssessmentPacks` (catalog note and catalog errors);
  - a new block before line 1009, the `btnAssessmentImport` click handler;
  - lines 1018–1036, the handler's `try` body.
- Modify: `web\index.html` (about lines 439–442, the import label inside
  `#assessImportPanel`)
- Test: `tests\assessment-ui.test.js`:
  - about line 53, the harness VM context;
  - new tests after line 1029.

**Interfaces:**

- Consumes:
  - From Task 5:
    - the import card `assessImportPanel`, containing `assessmentImportFile`,
      `btnAssessmentImport`, `assessmentImportSummary` (`role="status"`) and
      `assessmentCatalogErrors`;
    - the test helper `click(d, id)`.
  - Existing `web\app.js`:
    - `$`, `post(url, body)`, `showAssessmentError(message)`;
    - `assessmentIdentity(pack)` (`id@version#sha256`), `assessmentPlatforms`
      (platform key → display name), `assessmentPacks`;
    - `renderAssessmentPacks(catalog)`, which keeps checked boxes by identity;
    - `assessmentSessionFailure(r)`, `assessmentGeneration`,
      `assessmentCatalogRequest`.
  - Existing test helpers in `tests\assessment-ui.test.js`:
    - `assessmentDashboard(respond)`, `boxes(d, root)`;
    - `renderCatalog(d, packs = syntheticPacks())`, which runs
      `renderAssessmentPacks({ packs, errors: [] })`;
    - `syntheticPacks()`: four packs (`windows11`, `macos`, `iosIpados`,
      `androidEnterprise`) with id `synthetic-<platform lowercase>`, version
      `1.0.0`, sha256 `<index digit × 64>` and profile `Test profile`. Pack 3
      is an imported CIS pack with profile `Imported test profile`.
  - API (Task 4 implements it; the tests fake it). `POST /api/assessment/packs`:
    - with `{ content }` (the JSON text) → HTTP 201 `{ pack }`;
    - with `{ archive }` (base64 ZIP bytes) → HTTP 201 `{ packs: [{ ...pack
      metadata, origin: 'imported', controlCount, added }], added, skipped:
      [{ entry, reason }] (at most 100), skippedCount, ignored, archive: {
      sha256 } }`;
    - → HTTP 400 `{ error, skipped, skippedCount, ignored }` when an archive
      has nothing importable;
    - → HTTP 413 `{ error }` when the body is too large;
    - → HTTP 401 when the session expired (existing handling).
- Produces:
  - `web\app.js`:
    - the module variable `assessmentCatalogIssues` (the errors of the last
      rendered catalog);
    - `assessmentArchiveBase64(buffer)`;
    - `assessmentSkippedLines(body)` → string lines;
    - `assessmentImportReport(body, packs)` → summary text.
  - `assessmentImportFile`:
    - `accept=".json,.zip,application/json,application/zip,application/x-zip-compressed"`;
    - the label "Import a rule pack (JSON) or a CIS Intune build-kit archive
      (ZIP)".
  - Messages: "Choose a nonempty ZIP archive, at most 32 MiB.", "Choose a JSON
    rule pack (at most 10 MiB) or a ZIP archive (at most 32 MiB).", "Nothing
    was imported." and the summary lines.

- [ ] **Step 1: Give the test harness `btoa`**

In `tests\assessment-ui.test.js`, inside `assessmentDashboard`, replace this
text (about line 53):

```js
    URLSearchParams, TextEncoder,
```

with:

```js
    URLSearchParams, TextEncoder, btoa,
```

- [ ] **Step 2: Append the ZIP import tests**

Append this code at the end of `tests\assessment-ui.test.js`, after the closing
`});` of the last test, `the review lists platforms, packs and every context
value as plain text` (about line 1029). Leave one blank line before it.

The four tests cover:

1. The `accept` attribute and the catalog note.
2. A ZIP import:
   - the payload is two full 0x8000-byte chunks plus 5 bytes, which exercises
     the chunking;
   - the exact summary text, written with `textContent` only;
   - the merge by identity, which keeps an already-present pack's selection
     and leaves the new pack unselected;
   - the catalog errors are kept.
3. Type and size checks before any read, the accepted 32 MiB boundary, and a
   reset during a ZIP read, which sends nothing.
4. The HTTP 400 skipped list, a 413 that leaves the summary empty, and the
   unchanged JSON `{ content }` import.

```js
// --- ZIP rule-pack import ----------------------------------------------------

const importTypeMessage = 'Choose a JSON rule pack (at most 10 MiB) or a ZIP archive (at most 32 MiB).';
const importedNotice = 'Select the platforms and packs to assess; imports are never selected automatically.';

test('the import card accepts JSON and ZIP files and the catalog note names the supported formats', () => {
  const html = fs.readFileSync(path.join(__dirname, '..', 'web', 'index.html'), 'utf8');
  assert.match(html,
    /id="assessmentImportFile" accept="\.json,\.zip,application\/json,application\/zip,application\/x-zip-compressed"/);
  const d = assessmentDashboard();
  renderCatalog(d);
  const note = d.element('assessmentCatalogNote').textContent;
  for (const phrase of ['never bundled', 'licensed CIS Intune build-kit ZIP', 'schema-1 JSON rule pack',
    'PDF and Excel benchmarks are not supported']) {
    assert.ok(note.includes(phrase), phrase);
  }
});

test('ZIP import posts base64, lists the result and merges packs without selecting them or dropping catalog errors', async () => {
  const bytes = Array.from({ length: 0x8000 * 2 + 5 }, (_, i) => (i * 7) & 0xff);
  const present = { ...syntheticPacks()[0], origin: 'imported', controlCount: 2, added: false };
  const created = { ...syntheticPacks()[0], id: 'synthetic-kit-level-1', version: '1.0.0+abc123',
    sha256: 'c'.repeat(64), origin: 'imported', framework: 'CIS', profile: 'Level 1', controlCount: 1, added: true };
  const skipped = Array.from({ length: 12 }, (_, i) => ({
    entry: `kit/<extra-${i}>.json`, reason: 'Not a Settings Catalog policy or rule pack.' }));
  const d = assessmentDashboard((url, r) => (url === '/api/assessment/packs' && r.method === 'POST'
    ? { httpStatus: 201, body: { packs: [present, created], added: 1, skipped, skippedCount: 14, ignored: 3,
      archive: { sha256: 'd'.repeat(64) } } }
    : {}));
  d.run(`renderAssessmentPacks(${JSON.stringify({ packs: syntheticPacks(),
    errors: [{ origin: 'imported', reason: 'Synthetic invalid pack.' }] })})`);
  boxes(d, 'assessmentPlatforms')[0].checked = true;
  boxes(d, 'assessmentPlatforms')[0].handlers.change();
  boxes(d, 'assessmentPacks')[0].checked = true;
  let reads = 0;
  d.element('assessmentImportFile').files = [{ name: 'Synthetic-Kit.ZIP', size: bytes.length,
    arrayBuffer: async () => { reads++; return Uint8Array.from(bytes).buffer; },
    text: async () => { throw new Error('A ZIP archive must not be read as text.'); } }];
  await click(d, 'btnAssessmentImport');
  assert.equal(d.element('assessmentError').textContent, '');
  assert.equal(reads, 1);
  assert.deepEqual(d.requests.find((r) => r.method === 'POST').payload,
    { archive: Buffer.from(bytes).toString('base64') });
  assert.equal(d.element('assessmentImportSummary').textContent, [
    `Imported 2 rule packs locally. ${importedNotice}`,
    '1 new, 1 already present.',
    'synthetic-windows11 @ 1.0.0 — Windows 11 · Test profile · 2 controls · already present',
    'synthetic-kit-level-1 @ 1.0.0+abc123 — Windows 11 · Level 1 · 1 control · new',
    'Skipped 14 archive entries:',
    ...skipped.slice(0, 10).map((s) => `${s.entry}: ${s.reason}`),
    '…and 4 more.',
    '3 other files were ignored (not JSON).'
  ].join('\n'));
  assert.equal(d.element('assessmentImportSummary').innerHTML, '');
  assert.equal(d.element('assessmentProgress').textContent, '');
  const rows = Object.fromEntries(boxes(d, 'assessmentPacks').map((b) => [b.value, b]));
  assert.equal(Object.keys(rows).length, 5);
  assert.equal(rows[`synthetic-windows11@1.0.0#${'0'.repeat(64)}`].checked, true);
  const added = rows[`synthetic-kit-level-1@1.0.0+abc123#${'c'.repeat(64)}`];
  assert.equal(added.disabled, false);
  assert.equal(added.checked, false);
  assert.equal(d.element('assessmentCatalogErrors').textContent, 'imported: Synthetic invalid pack.');
});

test('import checks the file type and size before reading, and a reset during a ZIP read sends nothing', async () => {
  const d = assessmentDashboard();
  let reads = 0;
  const read = async () => { reads++; return new ArrayBuffer(1); };
  const zipMessage = 'Choose a nonempty ZIP archive, at most 32 MiB.';
  for (const [file, message] of [
    [undefined, importTypeMessage],
    [{ name: 'benchmark.pdf', size: 2 }, importTypeMessage],
    [{ name: 'benchmark.xlsx', size: 2 }, importTypeMessage],
    [{ name: 'kit.zip.txt', size: 2 }, importTypeMessage],
    [{ name: 'kit.zip', size: 0 }, zipMessage],
    [{ name: 'kit.ZIP', size: 32 * 1024 * 1024 + 1 }, zipMessage],
    [{ name: 'pack.JSON', size: 10 * 1024 * 1024 + 1 }, 'Choose a nonempty JSON rule pack, at most 10 MiB.']
  ]) {
    d.element('assessmentImportFile').files = file ? [{ ...file, arrayBuffer: read, text: read }] : [];
    await click(d, 'btnAssessmentImport');
    assert.equal(d.element('assessmentError').textContent, message, file?.name || 'no file');
  }
  assert.equal(reads, 0);
  assert.equal(d.requests.filter((r) => r.method === 'POST').length, 0);
  d.element('assessmentImportFile').files = [{ name: 'kit.Zip', size: 32 * 1024 * 1024,
    arrayBuffer: async () => Uint8Array.from([0, 127, 128, 255]).buffer }];
  await click(d, 'btnAssessmentImport');
  assert.deepEqual(d.requests.find((r) => r.method === 'POST').payload,
    { archive: Buffer.from([0, 127, 128, 255]).toString('base64') });
  let release;
  d.element('assessmentImportFile').files = [{ name: 'kit.zip', size: 1,
    arrayBuffer: () => new Promise((resolve) => { release = resolve; }) }];
  const pending = click(d, 'btnAssessmentImport');
  d.run('clearAssessment()');
  release(Uint8Array.from([1]).buffer);
  await pending;
  assert.equal(d.requests.filter((r) => r.method === 'POST').length, 1);
  assert.equal(d.element('btnAssessmentImport').disabled, false);
});

test('an archive with nothing importable shows the error and the skipped and ignored files, and imports nothing', async () => {
  let response;
  const d = assessmentDashboard((url, r) => (url === '/api/assessment/packs' && r.method === 'POST' ? response : {}));
  renderCatalog(d);
  response = { httpStatus: 400, body: {
    error: 'The archive contains no importable rule packs or Settings Catalog policies. ' +
      'PDF, Excel, XCCDF/OVAL, Group Policy and OMA-URI content is not supported.',
    skipped: [{ entry: 'kit/<notes>.json', reason: 'Not a Settings Catalog policy or rule pack.' }],
    skippedCount: 1, ignored: 1 } };
  d.element('assessmentImportFile').files = [{ name: 'kit.zip', size: 3,
    arrayBuffer: async () => Uint8Array.from([1, 2, 3]).buffer }];
  await click(d, 'btnAssessmentImport');
  assert.match(d.element('assessmentError').textContent, /^400: The archive contains no importable rule packs/);
  assert.equal(d.element('assessmentImportSummary').textContent, [
    'Nothing was imported.',
    'Skipped 1 archive entry:',
    'kit/<notes>.json: Not a Settings Catalog policy or rule pack.',
    '1 other file was ignored (not JSON).'
  ].join('\n'));
  assert.equal(boxes(d, 'assessmentPacks').length, 4);
  response = { httpStatus: 413, body: { error: 'Synthetic archive limit exceeded.' } };
  await click(d, 'btnAssessmentImport');
  assert.equal(d.element('assessmentError').textContent, '413: Synthetic archive limit exceeded.');
  assert.equal(d.element('assessmentImportSummary').textContent, '');
  response = { httpStatus: 201, body: { pack: { ...syntheticPacks()[1], id: 'synthetic-json',
    sha256: 'e'.repeat(64), origin: 'imported' } } };
  d.element('assessmentImportFile').files = [{ name: 'pack.json', size: 2, text: async () => '{}' }];
  await click(d, 'btnAssessmentImport');
  assert.deepEqual(d.requests.filter((r) => r.method === 'POST').at(-1).payload, { content: '{}' });
  assert.equal(d.element('assessmentError').textContent, '');
  assert.equal(d.element('assessmentImportSummary').textContent,
    `Imported 1 rule pack locally. ${importedNotice}\nsynthetic-json @ 1.0.0 — macOS · Test profile`);
  assert.equal(boxes(d, 'assessmentPacks').length, 5);
});
```

- [ ] **Step 3: Run the new tests and see them fail**

Run:

```powershell
node --test .\tests\assessment-ui.test.js
```

Expected: the summary shows `ℹ tests 37`, `ℹ pass 33` and `ℹ fail 4`. All 4
new tests fail:

- `the import card accepts JSON and ZIP files and the catalog note names the
  supported formats` fails with `The input did not match the regular
  expression /id="assessmentImportFile" accept="\.json,\.zip,...`.
- `ZIP import posts base64, lists the result and merges packs without
  selecting them or dropping catalog errors` fails with `Expected values to be
  strictly equal`: `assessmentError` holds `Choose a nonempty JSON rule pack,
  at most 10 MiB.` instead of `''`.
- `import checks the file type and size before reading, and a reset during a
  ZIP read sends nothing` fails with `AssertionError [ERR_ASSERTION]: no file`.
- `an archive with nothing importable shows the error and the skipped and
  ignored files, and imports nothing` fails with `The input did not match the
  regular expression /^400: The archive contains no importable rule packs/`.

The 33 tests that existed after Task 5 pass.

- [ ] **Step 4: Accept ZIP archives in the import card**

In `web\index.html`, inside `#assessImportPanel`, replace this text (about
lines 439–442):

```html
        <label>Import a local rule pack (JSON)
          <input type="file" id="assessmentImportFile" accept=".json,application/json">
          <small>Customer-owned/licensed CIS content is not bundled or downloaded. Maximum 10 MiB UTF-8 JSON,
            32 nesting levels, 20,000 controls, 32,768 characters per string. The server validates the original text.</small>
```

with:

```html
        <label>Import a rule pack (JSON) or a CIS Intune build-kit archive (ZIP)
          <input type="file" id="assessmentImportFile" accept=".json,.zip,application/json,application/zip,application/x-zip-compressed">
          <small>Customer-owned/licensed CIS content is not bundled or downloaded. JSON: at most 10 MiB UTF-8,
            32 nesting levels, 20,000 controls, 32,768 characters per string; the server validates the original text.
            ZIP: at most 32 MiB, read in memory and never extracted; its Settings Catalog policies and schema-1 packs
            become local rule packs. PDF and Excel benchmarks are not supported.</small>
```

The `</label>`, the **Import pack** button, `assessmentImportSummary` and
`assessmentCatalogErrors` that follow stay unchanged.

- [ ] **Step 5: Keep catalog errors and rewrite the catalog note**

A merge after an import re-renders the catalog. Today it passes `errors: []`
and drops the catalog errors, so the last catalog's errors now live in a module
variable. In `web\app.js`, replace this text (about line 574):

```js
let assessmentCatalogRequest = 0;
```

with:

```js
let assessmentCatalogRequest = 0;
let assessmentCatalogIssues = [];
```

In `renderAssessmentPacks(catalog)`, replace this text (about lines 587–589):

```js
  assessmentPacks = catalog.packs || [];
  $('assessmentCatalogNote').textContent =
    'Unavailable platform/profile combinations are disabled; CIS requires your own licensed JSON pack, not a PDF or Intune export. ' +
```

with:

```js
  assessmentPacks = catalog.packs || [];
  assessmentCatalogIssues = catalog.errors || [];
  $('assessmentCatalogNote').textContent =
    'CIS content is never bundled or downloaded. Import your own licensed CIS Intune build-kit ZIP or a ' +
    'schema-1 JSON rule pack below; PDF and Excel benchmarks are not supported. ' +
    'Unavailable platform/profile combinations are disabled. ' +
```

The remaining lines of the note, from `'The Microsoft catalog contains five
bundled checks total, all partial inventories: ' +`, stay unchanged. Then
replace this text (about line 596):

```js
  $('assessmentCatalogErrors').textContent = (catalog.errors || []).map((e) => `${e.origin}: ${e.reason}`).join('\n');
```

with:

```js
  $('assessmentCatalogErrors').textContent = assessmentCatalogIssues.map((e) => `${e.origin}: ${e.reason}`).join('\n');
```

- [ ] **Step 6: Add the base64 and summary helpers**

The three helpers:

- `assessmentArchiveBase64(buffer)` turns the archive bytes into base64.
- `assessmentSkippedLines(body)`:
  - lists at most 10 skipped entries as `entry: reason`;
  - counts from `skippedCount` (the server returns at most 100 entries), then
    adds "…and N more.";
  - ends with the ignored-files line.
- `assessmentImportReport(body, packs)` builds the success summary. The control
  count and the new/already-present marker appear only when the response
  carries `controlCount` and `added`, so a JSON import shows just
  `id @ version — Platform · profile`.

In `web\app.js`, find this text (about lines 1005–1009):

```js
  await loadAssessmentCatalog();
  await refreshAssessment();
});

$('btnAssessmentImport').addEventListener('click', async () => {
```

Insert this block between the blank line and
`$('btnAssessmentImport').addEventListener('click', async () => {`, followed by
one blank line:

```js
function assessmentArchiveBase64(buffer) {
  const bytes = new Uint8Array(buffer);
  let binary = '';
  // Chunking keeps fromCharCode within argument limits; btoa runs once because 0x8000 is not a multiple of 3.
  for (let i = 0; i < bytes.length; i += 0x8000) {
    binary += String.fromCharCode.apply(null, bytes.subarray(i, i + 0x8000));
  }
  return btoa(binary);
}

function assessmentSkippedLines(body) {
  const skipped = Array.isArray(body?.skipped) ? body.skipped : [];
  const total = Number.isInteger(body?.skippedCount) ? body.skippedCount : skipped.length;
  const lines = [];
  if (total > 0) {
    lines.push(`Skipped ${total} archive ${total === 1 ? 'entry' : 'entries'}:`);
    skipped.slice(0, 10).forEach((s) => lines.push(`${s.entry}: ${s.reason}`));
    const shown = Math.min(skipped.length, 10);
    if (total > shown) lines.push(`…and ${total - shown} more.`);
  }
  if (body?.ignored > 0) {
    lines.push(`${body.ignored} other ${body.ignored === 1 ? 'file was' : 'files were'} ignored (not JSON).`);
  }
  return lines;
}

function assessmentImportReport(body, packs) {
  const lines = [`Imported ${packs.length} rule ${packs.length === 1 ? 'pack' : 'packs'} locally. ` +
    'Select the platforms and packs to assess; imports are never selected automatically.'];
  if (typeof body.added === 'number') lines.push(`${body.added} new, ${packs.length - body.added} already present.`);
  packs.forEach((p) => {
    let line = `${p.id} @ ${p.version} — ${assessmentPlatforms[p.platform]} · ${p.profile}`;
    if (typeof p.controlCount === 'number') {
      line += ` · ${p.controlCount} ${p.controlCount === 1 ? 'control' : 'controls'}`;
    }
    if (typeof p.added === 'boolean') line += p.added ? ' · new' : ' · already present';
    lines.push(line);
  });
  return [...lines, ...assessmentSkippedLines(body)].join('\n');
}
```

- [ ] **Step 7: Read and post ZIP archives in the import handler**

What the new `try` body does:

- It picks the branch by file name and checks the size before reading.
- A ZIP is read with `arrayBuffer()` and posted as `{ archive }`.
- A JSON pack keeps its existing checks, messages and `{ content }` post.
- After each read and post, it re-checks the generation, so a reset during an
  import sends and renders nothing.
- On success, it removes catalog packs with the same identity, appends the
  imported packs and re-renders with the kept catalog errors.
  `renderAssessmentPacks` keeps checked boxes by identity and never checks a
  new pack.

In the `btnAssessmentImport` click handler, replace this text (about lines
1018–1036):

```js
    const file = $('assessmentImportFile').files[0];
    if (!file || !/\.json$/i.test(file.name) || !file.size || file.size > 10 * 1024 * 1024) {
      throw new Error('Choose a nonempty JSON rule pack, at most 10 MiB.');
    }
    const content = await file.text();
    if (generation !== assessmentGeneration) return;
    if (new TextEncoder().encode(content).length > 10 * 1024 * 1024) {
      throw new Error('Decoded UTF-8 pack exceeds 10 MiB.');
    }
    const r = await post('/api/assessment/packs', { content });
    if (generation !== assessmentGeneration) return;
    if (assessmentSessionFailure(r)) return;
    if (!r.ok || !r.body?.pack) throw new Error(`${r.status}: ${r.body?.error || 'Pack import failed.'}`);
    assessmentCatalogRequest++;
    const identity = assessmentIdentity(r.body.pack);
    const packs = assessmentPacks.filter((p) => assessmentIdentity(p) !== identity);
    renderAssessmentPacks({ packs: [...packs, r.body.pack], errors: [] });
    $('assessmentImportSummary').textContent =
      'Pack validated and imported locally. Select its platform/profile to assess.';
```

with:

```js
    const file = $('assessmentImportFile').files[0];
    let payload;
    if (file && /\.zip$/i.test(file.name)) {
      if (!file.size || file.size > 32 * 1024 * 1024) throw new Error('Choose a nonempty ZIP archive, at most 32 MiB.');
      const buffer = await file.arrayBuffer();
      if (generation !== assessmentGeneration) return;
      payload = { archive: assessmentArchiveBase64(buffer) };
    } else if (file && /\.json$/i.test(file.name)) {
      if (!file.size || file.size > 10 * 1024 * 1024) throw new Error('Choose a nonempty JSON rule pack, at most 10 MiB.');
      const content = await file.text();
      if (generation !== assessmentGeneration) return;
      if (new TextEncoder().encode(content).length > 10 * 1024 * 1024) {
        throw new Error('Decoded UTF-8 pack exceeds 10 MiB.');
      }
      payload = { content };
    } else {
      throw new Error('Choose a JSON rule pack (at most 10 MiB) or a ZIP archive (at most 32 MiB).');
    }
    const r = await post('/api/assessment/packs', payload);
    if (generation !== assessmentGeneration) return;
    if (assessmentSessionFailure(r)) return;
    const imported = Array.isArray(r.body?.packs) ? r.body.packs : r.body?.pack ? [r.body.pack] : null;
    if (!r.ok || !imported) {
      if (Array.isArray(r.body?.skipped)) {
        $('assessmentImportSummary').textContent =
          ['Nothing was imported.', ...assessmentSkippedLines(r.body)].join('\n');
      }
      throw new Error(`${r.status}: ${r.body?.error || 'Pack import failed.'}`);
    }
    assessmentCatalogRequest++;
    const identities = new Set(imported.map(assessmentIdentity));
    const packs = assessmentPacks.filter((p) => !identities.has(assessmentIdentity(p)));
    renderAssessmentPacks({ packs: [...packs, ...imported], errors: assessmentCatalogIssues });
    $('assessmentImportSummary').textContent = assessmentImportReport(r.body, imported);
```

The `} catch (e) {` and `} finally {` blocks that follow stay unchanged.

- [ ] **Step 8: Run the new tests and see them pass**

Run:

```powershell
node --test .\tests\assessment-ui.test.js
```

Expected: `ℹ tests 37`, `ℹ pass 37`, `ℹ fail 0`.

- [ ] **Step 9: Run the regression suite**

Run:

```powershell
node --test .\tests\publishing-ui.test.js .\tests\assessment-ui.test.js .\tests\app-shell-ui.test.js
pwsh -NoProfile -File .\scripts\Test-Repository.ps1; $LASTEXITCODE
git --no-pager diff --stat
```

Expected:

- The Node summary shows `ℹ tests 62`, `ℹ pass 62`, `ℹ fail 0`: 4 new tests,
  plus the 58 that passed after Task 5.
- `Test-Repository.ps1` prints `Repository guidance and local policy checks
  passed.` and then `0`. It may first print `Pull request target policy: not
  applicable without pull request event context.`
- The diff stat lists exactly these 3 files: `tests/assessment-ui.test.js`,
  `web/app.js` and `web/index.html`. It shows `3 files changed, 218
  insertions(+), 21 deletions(-)`.

Optionally, check that no LF-only line endings slipped into the edited files:

```powershell
'web\index.html','web\app.js','tests\assessment-ui.test.js' |
  ForEach-Object { '{0}: {1}' -f $_, ([regex]::Matches((Get-Content -Raw $_), '(?<!\r)\n')).Count }
```

Expected: every count is `0`.

- [ ] **Step 10: Commit**

Run:

```powershell
git add web\index.html web\app.js tests\assessment-ui.test.js
git commit -m "feat: import CIS build-kit ZIP archives in the assessment UI" -m "Co-authored-by: Copilot App <223556219+Copilot@users.noreply.github.com>"
```

Expected: one commit with `3 files changed`. If the opt-in pre-commit hook is
installed, it passes.

### Task 7: Documentation

Document the shipped wizard and CIS build-kit ZIP import in the four operator
documents. Every value comes from the design spec
(`docs\superpowers\specs\2026-10-29-assessment-wizard-and-cis-zip-import-design.md`)
and from Tasks 1–6. The documents must not claim CIS conformance or
certification, and they state that the build-kit layout is unverified and the
converter is defensive.

Notes for this task:

- Line numbers refer to the files before this task. Earlier edits in the same
  file shift later lines; find each edit by its exact current text.
- The four files use CRLF line endings. Keep CRLF. The repository has no
  `.gitattributes`; with `core.autocrlf=true`, Git normalizes on commit.
- No test or script checks the content of these documents.
  `scripts\Test-Repository.ps1` checks only the agent guidance files, the
  `docs\baseline-adoption.md` rows and `VERSION`. `tests\Package.Tests.ps1`
  checks only that the four documents ship in the package. The opt-in
  pre-commit hook runs `scripts\Test-Repository.ps1` only. There is no Markdown
  lint, link checker or Node test for documents. `Build-Package.ps1` scans the
  shipped `.md` files for `onmicrosoft.com` names, GUIDs and `eyJ` tokens, so
  the new text must contain none (Step 18).
- In these documents, "ZIP" alone means the application package. New text
  always says "build-kit ZIP" or "CIS build-kit ZIP".
- Leave the bundled-catalog callouts, the application update sections and the
  line "Import returns the validated pack without catalog-only metadata."
  unchanged. No document states the package file count.

**Files:**

- Modify: `docs\assessment-rule-packs.md` (about lines 28–68 workflow and
  storage, a new section before line 95, lines 103 and 108–116 API, lines
  357–362 PowerShell interfaces)
- Modify: `README.md` (about lines 98–117 and 126–131)
- Modify: `QUICKSTART.md` (about lines 87–108 and 116–120)
- Modify: `docs\operations.md` (about lines 35–39, 60–72, 108–110 and 206–213)

**Interfaces:**

- Consumes:
  - Task 1: `Import-IdsBaselinePackSet -Packs <byte[][]> -ImportedRoot <path>`,
    which returns `{ pack; added }` per pack and writes nothing when any pack
    conflicts.
  - Tasks 2–3: `ConvertTo-IdsBuildKitPacks` and
    `ConvertFrom-IdsBaselineArchive -Bytes <byte[]>`, which returns
    `{ packs; skipped; ignored; sha256 }` with the spec's archive limits,
    recognized content and conversion rules.
  - Task 4: the `archive` field of `POST /api/assessment/packs`, its `201`
    response, its errors and the `origin: "imported"` metadata.
  - Tasks 5–6: the five-step wizard, step validation and messages, the
    Windows 11 build warning, the review summary, **New assessment** and the
    **Import rule packs** card.
- Produces: none.

- [ ] **Step 1: Confirm the shipped labels and messages**

The new text quotes labels and messages from Tasks 1–6. Confirm them before
editing.

Run:

```powershell
$ui = (Get-Content -Raw .\web\index.html, .\web\app.js) -join "`n"
'Assess policies', 'Platforms', 'Baselines', 'Context', 'Review (&|&amp;) run',
'Results', 'Import rule packs', 'Import pack', 'Next', 'Back',
'Assess selected policies', 'New assessment' | Where-Object {
    $ui -notmatch ('(>\s*' + $_ + '\s*<)|([''"`]' + $_ + '[''"`])')
} | ForEach-Object { "Missing label: $_" }
$code = (Get-Content -Raw .\web\app.js, .\lib\AssessmentApi.ps1,
    .\lib\BaselineArchive.ps1, .\lib\BaselinePacks.ps1) -join "`n"
'Choose at least one platform to assess.',
'Every selected platform requires a selected applicable pack; choose at least one platform.',
'Select 1–64 packs.',
'Provide exactly one of content or archive.',
'The file is not a valid ZIP archive.',
'Nested ZIP archives are not opened; extract and upload the inner ZIP.',
'Could not be read (encrypted, corrupt or unsupported compression).',
'Not a Settings Catalog policy or rule pack.',
'contains no importable rule packs or Settings Catalog policies.',
'Group Policy and OMA-URI content is not supported.',
'Unclassified build kit policies',
'Unknown (customer-supplied build kit)',
'Next Generation Windows Security (NG)',
'https://workbench.cisecurity.org/',
'Local assessment storage failed.' | Where-Object { -not $code.Contains($_) } |
    ForEach-Object { "Missing message: $_" }
```

Expected: no output. If a line prints, the shipped wording differs from the
spec. Use the shipped wording in every new text below, and record the
difference in the pull request body.

- [ ] **Step 2: Rewrite the rule-pack workflow as the wizard**

In `docs\assessment-rule-packs.md`, under `## Customer workflow and
interpretation`, replace this text (about lines 28–58):

```markdown
1. Sign in through the existing read-only sign-in and verify the tenant on Home.
2. In **Assess policies**, select platforms and exact pack versions/profiles.
   Read the baseline/recommendations distinction, source revisions, SHA-256
   identity, origin, and inventory coverage before assessing. Customer imports
   have author-declared framework/classification labels, not application-reviewed
   Microsoft authority. Only the reviewed bundled catalog receives that distinction.
3. If using CIS, obtain a licensed, reviewed pack in the schema below. Select
   its local JSON file and click **Import pack**. No PDF parsing, raw Intune
   export conversion, automatic extraction/download, or bundled CIS content is
   provided. Customers own rights to their imported material. Schema validation
   is not verification of the benchmark content or mapping correctness.
4. Enter known OS versions, Android enrollment mode and optional iOS/iPadOS
   ownership comparison scope; leave unknowns unknown.
   Windows uses a numeric OS build such as `10.0.22000`, not just `11`; the
   macOS FileVault check requires 10.13+. Android's bundled check applies only
   to `workProfile`, not fully managed, dedicated, or corporate-owned modes.
   The bundled iOS rule requires explicitly selected `personallyOwned` context;
   its default is **Unknown** (not assessed), and `corporateOwned` is excluded.
   These selections do not establish discovered ownership or assignment reach.
   A supplied Windows 11 target build can scope compatible unrestricted
   Windows-family profiles without claiming Windows 11 inventory. Documented
   `deviceManagementApplicabilityRuleOsVersion` include/exclude ranges are honored.
   Malformed/unsupported conditions, edition and device-mode restrictions cannot
   establish a pass. Missing target context remains not assessed.
5. Choose an absolute report root disjoint from the installation and
   documentation export roots. Click **Assess selected policies**; an export
   and assessment cannot run together. Wait before identity changes/reset/stop.
6. Inspect summary counts, filter controls by status, review expected/configured
   typed values, per-policy evidence, assignment completeness and collection
   issues. Open the displayed Markdown/JSON report pair. Both describe the same
   evidence, sources, pack versions/hashes, and scope limitations.
```

with:

```markdown
**Assess policies** is a five-step wizard: **Platforms**, **Baselines**,
**Context**, **Review & run** and **Results**. **Next** checks the current step;
**Back** returns without checks. The stepper shows progress and is not
clickable. Errors appear directly below the stepper. The wizard keeps its step
when you visit Home. After a page reload, a running or completed assessment
opens **Results**. Sign-in, sign-out, **Forget saved session** and a session or
workspace reset return the wizard to **Platforms** and clear the import summary.

1. Sign in through the existing read-only sign-in and verify the tenant on Home,
   then open **Assess policies**.
2. **Platforms.** Select the platforms to assess. A platform without an
   available pack stays disabled until you import one. **Next** requires at
   least one platform: "Choose at least one platform to assess."
3. **Import rule packs.** This card appears on **Platforms** and **Baselines**
   only. It accepts the licensed CIS Intune build-kit ZIP that you downloaded
   from CIS (1 byte to 32 MiB) or one schema-1 JSON rule pack (at most 10 MiB).
   Select the file and click **Import pack**. The browser checks the file type
   and size first; problems appear below the stepper and nothing is sent. The
   card's status line reports the result. For a build-kit ZIP, it lists the
   generated packs with their control counts, how many were new or already
   present, the first skipped entries with reasons, and how many files were
   ignored. The card also shows catalog errors, such as an invalid imported
   pack. See [CIS build-kit ZIP import](#cis-build-kit-zip-import). Imported
   packs are never selected automatically. No PDF, Excel, XCCDF/OVAL, Group
   Policy/ADMX or OMA-URI content is parsed, and no CIS content is downloaded
   or bundled. Customers own rights to their imported material. Schema
   validation and conversion are not verification of the benchmark content or
   mapping correctness.
4. **Baselines.** Select exact pack versions/profiles. **Next** requires a
   selected applicable pack for every selected platform and 1–64 packs in
   total: "Every selected platform requires a selected applicable pack; choose
   at least one platform." or "Select 1–64 packs." Packs for unselected
   platforms, or outside the profile filter, are hidden. If no pack is shown,
   the step explains how to change the filter or import a pack.
   Read the baseline/recommendations distinction, source revisions, SHA-256
   identity, origin, and inventory coverage before assessing. Customer imports
   have author-declared framework/classification labels, not application-reviewed
   Microsoft authority. Only the reviewed bundled catalog receives that distinction.
5. **Context.** Only the fields for the selected platforms are shown. Enter
   known OS versions, Android enrollment mode and optional iOS/iPadOS
   ownership comparison scope; leave unknowns unknown.
   Windows uses a numeric OS build such as `10.0.22000`, not just `11`; the
   macOS FileVault check requires 10.13+. Android's bundled check applies only
   to `workProfile`, not fully managed, dedicated, or corporate-owned modes.
   The bundled iOS rule requires explicitly selected `personallyOwned` context;
   its default is **Unknown** (not assessed), and `corporateOwned` is excluded.
   These selections do not establish discovered ownership or assignment reach.
   A supplied Windows 11 target build can scope compatible unrestricted
   Windows-family profiles without claiming Windows 11 inventory. Documented
   `deviceManagementApplicabilityRuleOsVersion` include/exclude ranges are honored.
   Malformed/unsupported conditions, edition and device-mode restrictions cannot
   establish a pass. Missing target context remains not assessed.
   When Windows 11 is selected and its build is blank, a non-blocking warning
   explains that Windows policies targeting Windows 10 and later, such as the
   Settings Catalog policies that CIS build-kit packs map to, are assessed only
   when a Windows 11 build is entered (for example `10.0.22631` or
   `10.0.26100`). Otherwise their controls are reported as not assessed.
6. **Review & run.** Check the plain-text summary: the selected platforms, each
   pack as `id @ version` with its platform and profile, every context value
   (**Unknown** when blank), and the Windows 11 warning when it applies. Choose
   an absolute report root disjoint from the installation and documentation
   export roots. Click **Assess selected policies**; an export and assessment
   cannot run together. Wait before identity changes/reset/stop. If the server
   rejects the run, the wizard stays on **Review & run** and shows the error.
7. **Results.** Progress appears first, then the results. Inspect summary
   counts, filter controls by status, review expected/configured typed values,
   per-policy evidence, assignment completeness and collection issues. Open the
   displayed Markdown/JSON report pair. Both describe the same evidence,
   sources, pack versions/hashes, and scope limitations. A failed run shows its
   error below the stepper. **New assessment** returns to **Platforms** and
   keeps the selected platforms, packs, context and report destination. The
   previous results remain until the next run clears them. **New assessment**
   is disabled while an assessment runs.
```

- [ ] **Step 3: Describe where ZIP-generated packs are stored**

In `docs\assessment-rule-packs.md`, replace this text (about lines 60–68):

```markdown
Imported files are stored under
`%LOCALAPPDATA%\IntuneDocsStudio\AssessmentPacks`, outside the installation and
source tree, and survive application updates. Session reset clears active tenant
results, not imported files or saved reports. Reports go **only** to the chosen
report root, in a new run directory; neither reports nor imports are product
resources. No automatic uploads, commits, or Git pushes occur. Back them up only
as customer-owned data, subject to licensing/access controls, never with tokens,
credentials, or portal browser profiles. See [operator procedures](operations.md)
for updates, legacy development-folder handling, and restore.
```

with:

```markdown
Imported files are stored under
`%LOCALAPPDATA%\IntuneDocsStudio\AssessmentPacks`, outside the installation and
source tree, and survive application updates. Packs generated from a CIS
build-kit ZIP are stored there as `<sha256>.json`, exactly like JSON imports.
The ZIP itself is never written to disk or kept, so keep your licensed
download. Session reset clears active tenant results, not imported files or
saved reports. Reports go **only** to the chosen report root, in a new run
directory; neither reports nor imports are product resources. No automatic
uploads, commits, or Git pushes occur. Back them up only as customer-owned
data, subject to licensing/access controls, never with tokens, credentials, or
portal browser profiles. See [operator procedures](operations.md) for updates,
legacy development-folder handling, and restore.
```

- [ ] **Step 4: Add the CIS build-kit ZIP import section**

In `docs\assessment-rule-packs.md`, replace this text (about lines 93–95):

```markdown
Manual controls need human review outside this automation.

## Local assessment API
```

with:

```markdown
Manual controls need human review outside this automation.

## CIS build-kit ZIP import

CIS members can download Intune **build kits**: ZIP archives of Intune Settings
Catalog policies in Microsoft Graph JSON form. The **Import rule packs** card
accepts such a licensed download and converts it into local schema-1 rule
packs. The application never downloads CIS content and bundles none.

No licensed build kit was available when this import was built, so the exact
archive layout is unverified. The converter is therefore defensive. It walks
every `.json` entry, recognizes Settings Catalog policies and schema-1 rule
packs, and reports everything else as skipped or ignored with a reason. Read
the import summary after every import.

Packs converted from Settings Catalog policies get framework `CIS` and
classification `baseline`. The application assigns these labels; it cannot
verify that an archive came from CIS, so import only your own licensed
download. A converted pack records the values configured in the build kit. It
is not a complete benchmark, and an assessment against it does not establish
CIS conformance or certification.

### Reading the archive

The server reads the archive in memory with `System.IO.Compression`. Nothing is
extracted to disk, and the archive itself is never stored. Only validated packs
are written.

| Limit or rule | Behavior |
|---|---|
| Archive size | 1 byte to 32 MiB. An empty archive returns `400`; a larger one returns `413`. |
| Not a valid ZIP | `400`: "The file is not a valid ZIP archive." |
| Entry count | At most 1,000 entries and at most 500 `.json` entries; otherwise `400`. |
| Entry name with a `..` segment, a leading `/` or `\`, or a `:` | The whole archive is rejected with `400`, although nothing is extracted. |
| Directory | Ignored and not counted. |
| Non-JSON file (PDF, XLSX, XML, …) | Counted in `ignored`. |
| Nested `.zip` | Skipped: "Nested ZIP archives are not opened; extract and upload the inner ZIP." |
| Encrypted, corrupt or unsupported compression | Skipped: "Could not be read (encrypted, corrupt or unsupported compression)." |
| JSON entry over 10 MiB (declared or actual size) | Skipped with a reason. |
| More than 64 MiB of JSON read in total | `413`, as a decompression-bomb guard. |

JSON entries may use UTF-8, with or without a BOM, or UTF-16 LE/BE with a BOM.
This applies only inside an archive; a JSON file imported directly must still
be UTF-8 without a BOM. Entries are parsed with `System.Text.Json` with a
nesting limit of 64 levels. Duplicate member names, or strings longer than
32,768 characters, skip the entry. Any other failure in one entry also skips
only that entry, with a reason. The archive-level limits above fail the whole
request.

### Recognized content

Two kinds of JSON entry are recognized:

1. **Schema-1 rule pack**: an object with a top-level `schemaVersion`. The
   entry is re-encoded as UTF-8 without a BOM and validated like a JSON import,
   including every [named limit](#encoding-and-named-resource-limits). The
   stored pack and its SHA-256 identity use the re-encoded bytes. An invalid
   pack is skipped with a reason.
2. **Settings Catalog policies**: an object with `settings`, an array of such
   objects, or `{ "value": [ … ] }`. They are converted as described below.

Anything else is skipped: "Not a Settings Catalog policy or rule pack." PDF,
Excel, XCCDF/OVAL, Group Policy (GPO/ADMX), OMA-URI and legacy
device-configuration content is not supported.

### Converting Settings Catalog policies

- **Name**: `name`, else `displayName`, else the entry's file name.
- **Platform**: the mapping that tenant collection uses. `windows10`,
  `windows11` and `windows10AndLater` become `windows11`; `macOS` becomes
  `macos`; `iOS` becomes `iosIpados`; `androidEnterprise` stays
  `androidEnterprise`. Other or combined platforms are skipped.
- **Level**: the policy name must contain exactly one distinct CIS profile
  token. `L1`, `L2`, `BL` and `NG` count only as standalone, case-sensitive
  tokens. "Level 1" and "Level 2" match in any case. Otherwise the policy goes
  into "Unclassified build kit policies".
- **Grouping**: one pack per platform and level.

| Level token in the policy name | Profile label | Pack ID |
|---|---|---|
| `L1` or "Level 1" | Level 1 (L1) | `cis.<platform>.l1` |
| `L2` or "Level 2" | Level 2 (L2) | `cis.<platform>.l2` |
| `BL` | BitLocker (BL) | `cis.<platform>.bl` |
| `NG` | Next Generation Windows Security (NG) | `cis.<platform>.ng` |
| None, or more than one distinct token | Unclassified build kit policies | `cis.<platform>.build-kit` |

Pack IDs are lower case, for example `cis.windows11.l1` or
`cis.iosipados.build-kit`.

**Controls.** Each setting instance goes through the normalizer that reads
tenant Settings Catalog policies. Every supported, configured, non-secret
setting with a value type becomes one control:

- `id` is the setting definition ID. `title` is the definition's display name
  when the policy includes `settingDefinitions`; otherwise it is the setting ID.
- `reference` names the source policies and archive entries, at most five, then
  "and N more".
- The single mapping uses family `settingsCatalog`, policy type
  `deviceManagementConfigurationPolicy`, the `settingId`, `property: null`,
  `instancePath: null` (any instance) and the observed `valueType`.
- The operator is `eq` for scalar values and `setEquals` for string and number
  sets, with `caseSensitive: true`. `expected` is the value configured in the
  build kit.
- A choice setting yields one control for the choice and one for each
  configured child. A group collection yields controls for its children only.

These settings are skipped with a reason:

- A setting ID that occurs more than once in any policy of the pack. Repeated
  instances cannot be expressed as one any-instance check, so the setting is
  skipped for the whole pack.
- A setting ID with different values in two policies of one pack. Equal values
  merge into one control that references both policies.
- Secret, unsupported, template-default and not-configured settings.

A group without controls produces no pack.

### Generated pack metadata

| Field | Value |
|---|---|
| `schemaVersion` | `1` |
| `id` | `cis.<platform>.<slug>`, lower case |
| `version` | `1.0.0+` followed by the first 12 hexadecimal characters of the SHA-256 of the pack serialized with version `1.0.0` |
| `platform` | The group's platform |
| `framework`, `classification`, `profile` | `CIS`, `baseline` and the profile label |
| `frameworkVersion` | The single distinct `vX.Y.Z` in the pack's policy names, else in its entry paths; otherwise "Unknown (customer-supplied build kit)" |
| `sourceRevision` | Names the archive SHA-256 |
| `sources` | One source, `cis-build-kit`, with URL `https://workbench.cisecurity.org/`, a `revision` with the archive SHA-256, and `retrievedOn` set to the newest timestamp of the entries used (`yyyy-MM-dd`) |
| `coverage` | `inventory: partial`, `totalSourceControls: null` |

Identical input produces a byte-identical pack. Importing the same archive
again adds nothing; the summary reports its packs as already present. An
archive with different bytes, for example the same files zipped again, yields
new versions, because the source revision names the archive SHA-256. Earlier
versions stay in the catalog; select the intended version on **Baselines**.
Generated packs must stay within 10 MiB and are validated like any other pack
before import.

## Local assessment API
```

- [ ] **Step 5: Update the import route row**

In `docs\assessment-rule-packs.md`, under `## Local assessment API`, replace
this text (about line 103):

```markdown
| `POST /api/assessment/packs` | `201 { pack: metadata }` |
```

with:

```markdown
| `POST /api/assessment/packs` | `201 { pack: metadata }` for `content`; `201 { packs, added, skipped, skippedCount, ignored, archive }` for `archive` |
```

- [ ] **Step 6: Document the `content` and `archive` import fields**

In `docs\assessment-rule-packs.md`, replace this text (about lines 108–116):

```markdown
POST requests require `Content-Type: application/json` (optionally
`charset=utf-8`), and `Origin` and `Host` matching the configured localhost
listener. Imports accept only `{ "content": "original UTF-8 JSON text" }`,
never a server-side file path. The import envelope is bounded to 64 MiB,
including chunked/unknown-length streams; decoded pack content remains bounded
to 10 MiB **before** pack parsing. Imported bytes are stored locally under
`%LOCALAPPDATA%\IntuneDocsStudio\AssessmentPacks`, outside the installation.
An ID/version collision with different bytes, including a bundled identity,
is rejected without replacing the valid catalog entry.
```

with:

````markdown
POST requests require `Content-Type: application/json` (optionally
`charset=utf-8`), and `Origin` and `Host` matching the configured localhost
listener. A pack import contains exactly one of two fields, never a server-side
file path:

- `content`: the original UTF-8 JSON text of one schema-1 pack. Decoded
  content is bounded to 10 MiB **before** pack parsing. Success returns
  `201 { pack }`.
- `archive`: a ZIP archive in strict base64: only `A–Z`, `a–z`, `0–9`, `+` and
  `/`, at most two `=` padding characters, and a length that is a multiple of
  4. The text is at most 44,739,244 characters and decodes to 1 byte–32 MiB.
  See [CIS build-kit ZIP import](#cis-build-kit-zip-import).

A body with neither or both fields returns `400` "Provide exactly one of
content or archive." The import envelope is bounded to 64 MiB, including
chunked/unknown-length streams. Imported bytes are stored locally under
`%LOCALAPPDATA%\IntuneDocsStudio\AssessmentPacks`, outside the installation.
An ID/version collision with different bytes, including a bundled identity,
is rejected without replacing the valid catalog entry. Returned pack metadata
carries `origin: "imported"` for both fields, as the catalog reports after a
reload. Pack import also works signed out. The dashboard disables imports while
an export or assessment runs. The local server handles one request at a time,
so a large import briefly delays progress polling.

For an archive, the server converts it and checks every generated pack against
the current catalog before writing anything. It then imports the set and
returns `201`:

```json
{
  "packs": [ { "...pack metadata": "...", "controlCount": 212, "added": true } ],
  "added": 1,
  "skipped": [
    {
      "entry": "kit/readme.json",
      "reason": "Not a Settings Catalog policy or rule pack."
    }
  ],
  "skippedCount": 1,
  "ignored": 4,
  "archive": { "sha256": "<hex>" }
}
```

- `packs`: metadata for each generated pack, with its `controlCount`. `added`
  is `false` when an identical pack was already stored.
- `added`: the number of packs newly stored by this request.
- `skipped`: at most 100 skipped items, each with its `entry` and `reason`.
  Entry names are truncated to 260 characters. `skippedCount` holds the total.
- `ignored`: the number of non-JSON files.
- `archive.sha256`: the SHA-256 of the uploaded archive.

When nothing is importable, the server returns `400` with `skipped`,
`skippedCount` and `ignored`, and the error "The archive contains no importable
rule packs or Settings Catalog policies. PDF, Excel, XCCDF/OVAL, Group Policy
and OMA-URI content is not supported."

| Situation | Status | Message |
|---|---|---|
| Neither or both of `content` and `archive` | `400` | "Provide exactly one of content or archive." |
| Invalid base64, empty archive, unsafe entry name, or too many entries | `400` | Describes the problem. |
| Not a valid ZIP | `400` | "The file is not a valid ZIP archive." |
| Nothing importable | `400` | The message above. |
| Two different packs with the same ID and version in one archive | `400` | Names the pack ID and version; nothing is written. |
| Conflict with an existing pack | `400` | Names the pack ID and version; nothing is written. |
| Archive over 32 MiB, or more than 64 MiB of JSON | `413` | Describes the problem. |
| Storage failure | `500` | "Local assessment storage failed." |

A storage failure can happen after some packs were written. Those packs stay
imported, and each is complete and valid; the request still fails with `500`.
Import the same archive again: stored packs are reported as already present,
and the rest are added.
````

- [ ] **Step 7: Document the batch import and archive reader functions**

In `docs\assessment-rule-packs.md`, under the PowerShell interface bullets,
replace this text (about lines 357–362):

```markdown
- Reimporting identical bytes for an existing imported ID/version is
  idempotent. Different bytes for that imported ID/version are rejected; a new
  revision requires a new version. A malformed/conflicting imported catalog
  blocks imports until repaired, without replacing existing packs. Combined
  catalog checks also expose collisions with bundled content. Import returns
  the validated pack without catalog-only metadata.
```

with:

```markdown
- Reimporting identical bytes for an existing imported ID/version is
  idempotent. Different bytes for that imported ID/version are rejected; a new
  revision requires a new version. A malformed/conflicting imported catalog
  blocks imports until repaired, without replacing existing packs. Combined
  catalog checks also expose collisions with bundled content. Import returns
  the validated pack without catalog-only metadata.
- `Import-IdsBaselinePackSet -Packs [byte[][]] -ImportedRoot [string]` imports
  several packs at once. It validates every pack, drops byte-identical
  duplicates, and rejects two different packs with the same ID/version. It
  applies the same root checks, takes `.import.lock` once, reads the imported
  catalog once, and rejects every conflict before writing anything. Each new
  pack is then written through a staged file and a non-overwriting move, as
  above. It returns `{ pack; added }` for each pack. `Import-IdsBaselinePack`
  is a one-pack call of this function with the same error messages. If storage
  fails partway, packs already moved stay imported; each is complete and valid.
- `ConvertFrom-IdsBaselineArchive -Bytes [byte[]]` in `lib\BaselineArchive.ps1`
  reads a ZIP archive in memory and returns
  `{ packs = <byte[][]>; skipped; ignored; sha256 }`. It extracts and writes
  nothing. See [CIS build-kit ZIP import](#cis-build-kit-zip-import) for its
  limits and conversion rules.
```

- [ ] **Step 8: Rewrite the README assessment steps as the wizard**

In `README.md`, after the "Only five checks…" callout, replace this text (about
lines 98–117):

```markdown
1. Sign in, confirm the tenant on Home, and open **Assess policies**.
2. Select target platforms, exact rule-pack versions/profiles, and read their
   classification, partial coverage, source revisions, and SHA-256 identities.
3. Optionally select a licensed, reviewed **schema-1 JSON** CIS pack and click
   **Import pack**. PDFs and arbitrary Intune exports are not accepted; CIS content
   is neither bundled nor downloaded. See the [import reference](docs/assessment-rule-packs.md)
   for all fields, supported operators, and named limits.
4. Enter known OS versions (Windows uses a build version such as `10.0.22000`)
   and Android enrollment mode. Explicitly select iOS/iPadOS **Personally owned**
   only for that comparison scope; ownership defaults to **Unknown**. Unknown
   applicability remains **not assessed**. These are user-selected comparison
   context, not discovered inventory, ownership, or effective assignment.
   A Windows 11 build can scope compatible unrestricted Windows-family profiles;
   real policy include/exclude rules still apply. Unsupported conditions block.
5. Choose an absolute **assessment report destination**, separate from both the
   installation and documentation export folders, then **Assess selected policies**.
   One export or assessment can run at a time; wait before sign-out, reset, or stop.
6. Read the summary, filter evidence by status, inspect policy/assignment evidence,
   collection issues and reasons, then open the displayed `assessment.md` and
   `assessment.json` paths. Each run creates a new report subdirectory.
```

with:

```markdown
The assessment is a five-step wizard: **Platforms**, **Baselines**, **Context**,
**Review & run** and **Results**. **Next** checks each step, and errors appear
below the stepper.

1. Sign in, confirm the tenant on Home, and open **Assess policies**. On
   **Platforms**, select at least one target platform.
2. Optionally import packs in the **Import rule packs** card on **Platforms** or
   **Baselines**. Select the licensed CIS Intune build-kit ZIP you downloaded from
   CIS (at most 32 MiB) or one licensed, reviewed **schema-1 JSON** rule pack (at
   most 10 MiB), then click **Import pack**. The ZIP is read in memory, and its
   Settings Catalog policies become local rule packs. The card lists the packs and
   any skipped or ignored files. Imported packs are never selected automatically.
   A single JSON file must be a schema-1 rule pack; Settings Catalog JSON is
   converted only from a build-kit ZIP. Converted packs are labeled CIS without
   verifying the source, so import only your licensed download. PDFs, Excel,
   XCCDF/OVAL, Group Policy and OMA-URI content are not supported; CIS content is
   neither bundled nor downloaded. See the [import reference](docs/assessment-rule-packs.md)
   for all fields, supported operators, named limits, and ZIP conversion rules.
3. On **Baselines**, select 1–64 exact rule-pack versions/profiles, with an
   applicable pack for every selected platform. Read their classification,
   partial coverage, source revisions, and SHA-256 identities.
4. On **Context**, enter known OS versions (Windows uses a build version such as
   `10.0.22000`) and Android enrollment mode; only fields for the selected
   platforms appear. Explicitly select iOS/iPadOS **Personally owned** only for
   that comparison scope; ownership defaults to **Unknown**. Unknown applicability
   remains **not assessed**. These are user-selected comparison context, not
   discovered inventory, ownership, or effective assignment. A Windows 11 build
   can scope compatible unrestricted Windows-family profiles; real policy
   include/exclude rules still apply. Unsupported conditions block. If the
   Windows 11 build is blank, a non-blocking warning explains that Windows
   policies targeting Windows 10 and later, such as those that CIS build-kit
   packs check, stay **not assessed**.
5. On **Review & run**, check the summary. Choose an absolute
   **assessment report destination**, separate from both the installation and
   documentation export folders, then **Assess selected policies**. One export or
   assessment can run at a time; wait before sign-out, reset, or stop.
6. On **Results**, read the summary, filter evidence by status, inspect
   policy/assignment evidence, collection issues and reasons, then open the
   displayed `assessment.md` and `assessment.json` paths. Each run creates a new
   report subdirectory. **New assessment** returns to **Platforms** and keeps your
   choices; it is disabled while an assessment runs.
```

- [ ] **Step 9: Note in the README where ZIP-generated packs are stored**

In `README.md`, replace this text (about lines 126–131):

```markdown
Imported files persist in `%LOCALAPPDATA%\IntuneDocsStudio\AssessmentPacks` across
application updates; active tenant results clear on session reset. Reports go
only to your chosen report root. Treat packs and reports as customer-owned data,
separate from exports and their Git history. Assessment does not upload data,
commit, or push reports automatically. See [operator procedures](docs/operations.md)
for backup, update, and failure handling; never back up tokens or browser profiles.
```

with:

```markdown
Imported files persist in `%LOCALAPPDATA%\IntuneDocsStudio\AssessmentPacks` across
application updates; packs generated from a build-kit ZIP are stored there too.
The ZIP itself is not kept, so keep your licensed download. Active tenant results
clear on session reset. Reports go only to your chosen report root. Treat packs
and reports as customer-owned data, separate from exports and their Git history.
Assessment does not upload data, commit, or push reports automatically. See
[operator procedures](docs/operations.md) for backup, update, and failure
handling; never back up tokens or browser profiles.
```

- [ ] **Step 10: Rewrite the QUICKSTART assessment steps as the wizard**

In `QUICKSTART.md`, after the "Limited preview…" callout, replace this text
(about lines 87–108):

```markdown
1. Sign in, confirm the tenant on Home, and open **Assess policies**.
   Select platforms and exact pack versions/profiles. Read their
   source revision, hash, classification, and coverage before running.
2. For CIS, choose a customer-licensed, reviewed JSON rule pack and click
   **Import pack**. No CIS content is bundled or downloaded. PDFs and raw Intune
   exports are not rule packs; see [the import reference](docs/assessment-rule-packs.md)
   for schema, supported operators, and limits (10 MiB UTF-8, 32 levels,
   20,000 controls, 32,768 characters per string).
3. Enter known OS versions and Android enrollment mode. Windows expects a build
   version such as `10.0.22000`. Unknown applicability remains **not assessed**.
   Select iOS/iPadOS **Personally owned** only for that explicit comparison scope;
   its default is **Unknown**, not assumed ownership. This is selected comparison
   context, not discovered inventory or effective assignment. Windows-family
   policies can use the supplied Windows 11 target build; policy include/exclude
   rules remain authoritative and unsupported conditions remain not assessed.
4. Choose an absolute **assessment report destination** outside both the app and
   documentation output trees, then click **Assess selected policies**. Wait for
   completion before another export/assessment, sign-out, reset, or shutdown.
5. Inspect summary counts and filter the evidence table by status. Read expected
   and configured values, policy/assignment evidence, reasons, and collection
   limitations. Open the displayed paths: each new run folder contains
   `assessment.md` and `assessment.json`; existing exports/manifests are unchanged.
```

with:

```markdown
The assessment is a five-step wizard: **Platforms**, **Baselines**, **Context**,
**Review & run** and **Results**. **Next** checks each step; errors appear below
the stepper.

1. Sign in, confirm the tenant on Home, and open **Assess policies**. On
   **Platforms**, select at least one platform.
2. To import packs, use the **Import rule packs** card on **Platforms** or
   **Baselines**. Choose the licensed CIS Intune build-kit ZIP you downloaded from
   CIS (at most 32 MiB) or one customer-licensed, reviewed schema-1 JSON rule pack
   (at most 10 MiB), and click **Import pack**. The ZIP is read in memory. Its
   Settings Catalog policies become rule packs labeled CIS, so import only your
   licensed download. The card lists the packs and any skipped or ignored files.
   Imported packs are never selected automatically. No CIS content is bundled or
   downloaded. PDFs, Excel, XCCDF/OVAL, Group Policy and OMA-URI content are not
   supported; see [the import reference](docs/assessment-rule-packs.md) for
   schema, supported operators, ZIP conversion, and pack limits (10 MiB UTF-8,
   32 levels, 20,000 controls, 32,768 characters per string).
3. On **Baselines**, select 1–64 exact pack versions/profiles, with an applicable
   pack for every selected platform. Read their source revision, hash,
   classification, and coverage before running.
4. On **Context**, enter known OS versions and Android enrollment mode for the
   selected platforms. Windows expects a build version such as `10.0.22000`.
   Unknown applicability remains **not assessed**. Select iOS/iPadOS
   **Personally owned** only for that explicit comparison scope; its default is
   **Unknown**, not assumed ownership. This is selected comparison context, not
   discovered inventory or effective assignment. Windows-family policies can use
   the supplied Windows 11 target build; policy include/exclude rules remain
   authoritative and unsupported conditions remain not assessed. A blank
   Windows 11 build shows a non-blocking warning: Windows policies targeting
   Windows 10 and later, such as those that CIS build-kit packs check, then stay
   not assessed.
5. On **Review & run**, check the summary. Choose an absolute
   **assessment report destination** outside both the app and documentation
   output trees, then click **Assess selected policies**. Wait for completion
   before another export/assessment, sign-out, reset, or shutdown.
6. On **Results**, inspect summary counts and filter the evidence table by
   status. Read expected and configured values, policy/assignment evidence,
   reasons, and collection limitations. Open the displayed paths: each new run
   folder contains `assessment.md` and `assessment.json`; existing
   exports/manifests are unchanged. **New assessment** returns to **Platforms**
   with your choices kept; it is disabled while an assessment runs.
```

- [ ] **Step 11: Note in the QUICKSTART where ZIP-generated packs are stored**

In `QUICKSTART.md`, replace this text (about lines 116–120):

```markdown
Imports persist at `%LOCALAPPDATA%\IntuneDocsStudio\AssessmentPacks` through app
updates; active tenant results clear on session reset. Reports are written only
to the report root you choose, never automatically uploaded, committed, or pushed.
Back up packs/reports only as customer-owned files; do not back up tokens or
portal browser profiles. See [operator procedures](docs/operations.md).
```

with:

```markdown
Imports persist at `%LOCALAPPDATA%\IntuneDocsStudio\AssessmentPacks` through app
updates, including packs generated from a build-kit ZIP. The ZIP itself is not
kept, so keep your licensed download. Active tenant results clear on session
reset. Reports are written only to the report root you choose, never
automatically uploaded, committed, or pushed. Back up packs/reports only as
customer-owned files; do not back up tokens or portal browser profiles. See
[operator procedures](docs/operations.md).
```

- [ ] **Step 12: Describe the imported-pack folder in the operations guide**

In `docs\operations.md`, replace this text (about lines 35–39):

```markdown
- Imported assessment packs persist outside the installation at
  `%LOCALAPPDATA%\IntuneDocsStudio\AssessmentPacks`. Bundled packs are reviewed
  application resources, not customer imports. Active tenant assessment results
  live in memory and clear on session reset/identity replacement; saved report
  files and imported packs are not deleted by that reset.
```

with:

```markdown
- Imported assessment packs persist outside the installation at
  `%LOCALAPPDATA%\IntuneDocsStudio\AssessmentPacks`, one `<sha256>.json` file
  per pack. Packs generated from a CIS build-kit ZIP live in the same folder as
  JSON imports. The ZIP itself is read in memory and never kept; keep your
  licensed download under your own access controls. Bundled packs are reviewed
  application resources, not customer imports. Active tenant assessment results
  live in memory and clear on session reset/identity replacement; saved report
  files and imported packs are not deleted by that reset.
```

- [ ] **Step 13: Describe the wizard and ZIP import in the operations guide**

In `docs\operations.md`, replace this text (about lines 60–72):

```markdown
Sign in and verify tenant identity on Home, then open **Assess policies**. Select
platforms and exact pack versions/profiles; inspect source revisions, SHA-256,
baseline versus recommendations classification, and partial inventory. Import
only reviewed customer-licensed schema-1 JSON via **Import pack**; validation
does not attest to source correctness or rights. CIS benchmark PDFs and arbitrary
Intune exports are not supported. The [import reference](assessment-rule-packs.md)
documents fields, type/operator support, platform/enrollment context, and limits.
No framework content is downloaded automatically.

Supply known OS versions, Android enrollment mode and optional iOS/iPadOS ownership
comparison scope, select the separate
report destination, and click **Assess selected policies**. Windows 11 uses a
numeric build version such as `10.0.22000`; macOS FileVault needs at least 10.13.
```

with:

```markdown
Sign in and verify tenant identity on Home, then open **Assess policies**. The
wizard runs through **Platforms**, **Baselines**, **Context**, **Review & run**
and **Results**. Select platforms, then exact pack versions/profiles; inspect
source revisions, SHA-256, baseline versus recommendations classification, and
partial inventory. The **Import rule packs** card on **Platforms** and
**Baselines** accepts reviewed customer-licensed schema-1 JSON or the licensed
CIS Intune build-kit ZIP downloaded from CIS; click **Import pack**. Validation
and conversion do not attest to source correctness or rights. Packs converted
from a build-kit ZIP are labeled CIS without verifying the source. The
build-kit layout is unverified, so read the import summary: skipped entries
with reasons and the number of ignored files. Imported packs are never selected
automatically. CIS benchmark PDFs, Excel, XCCDF/OVAL, Group Policy and OMA-URI
content are not supported. The [import reference](assessment-rule-packs.md)
documents fields, type/operator support, ZIP conversion, platform/enrollment
context, and limits. No framework content is downloaded automatically.

On **Context**, supply known OS versions, Android enrollment mode and optional
iOS/iPadOS ownership comparison scope; only the selected platforms' fields are
shown. On **Review & run**, check the summary, select the separate report
destination, and click **Assess selected policies**. Windows 11 uses a numeric
build version such as `10.0.22000`; macOS FileVault needs at least 10.13. A
blank Windows 11 build shows a non-blocking warning: Windows policies targeting
Windows 10 and later, including the Settings Catalog policies that CIS
build-kit packs map to, are then reported as not assessed.
```

- [ ] **Step 14: Describe ZIP import failures in the operations guide**

In `docs\operations.md`, replace this text (about lines 108–110):

```markdown
Validation errors do not replace a valid pack; fix the JSON/limit or review the
immutable ID/version/hash collision and use a new version for revised bytes.
Do not delete a valid pack blindly to silence a collision. Source access failures
```

with:

```markdown
Validation errors do not replace a valid pack; fix the JSON/limit or review the
immutable ID/version/hash collision and use a new version for revised bytes.
Do not delete a valid pack blindly to silence a collision. A build-kit ZIP
import checks every generated pack before writing; one collision rejects the
whole archive and writes nothing. A storage failure (`500`) during a ZIP import
can leave some complete packs imported; import the same archive again, and
those packs are reported as already present. Source access failures
```

- [ ] **Step 15: Describe backup of ZIP-generated packs**

In `docs\operations.md`, replace this text (about lines 206–213):

```markdown
Back up imported rule-pack files and chosen report roots separately as
customer-owned data, with access controls and any CIS licensing restrictions.
Preserve original bytes for hash provenance. Restore packs outside the app,
review identity/version collisions, and reimport through the dashboard where
needed. Restore reports to a separate data folder, not into exported
documentation or the installation; opening an old report does not restore an
authenticated in-memory result. Never include access tokens, credentials, or
portal browser profiles in these backups.
```

with:

```markdown
Back up imported rule-pack files and chosen report roots separately as
customer-owned data, with access controls and any CIS licensing restrictions.
The imported-pack folder holds packs imported as JSON and packs generated from
a CIS build-kit ZIP alike, each as `<sha256>.json`. The application does not
keep the ZIP; keep your licensed download under your own access controls.
Preserve original bytes for hash provenance. Restore packs outside the app,
review identity/version collisions, and reimport through the dashboard where
needed. Restore reports to a separate data folder, not into exported
documentation or the installation; opening an old report does not restore an
authenticated in-memory result. Never include access tokens, credentials, or
portal browser profiles in these backups.
```

- [ ] **Step 16: Check that no contradicting old text remains**

Run:

```powershell
$files = '.\README.md', '.\QUICKSTART.md', '.\docs\assessment-rule-packs.md', '.\docs\operations.md'
$old = 'Imports accept only', 'Select its local JSON file',
    'Schema validation is not verification', 'automatic extraction/download',
    'raw Intune export', 'arbitrary Intune exports', '**schema-1 JSON** CIS pack',
    'reviewed JSON rule pack and click', 'only reviewed customer-licensed schema-1 JSON',
    '`201 { pack: metadata }` |'
foreach ($f in $files) {
    $text = (Get-Content -Raw $f) -replace '\s+', ' '
    $old | Where-Object { $text.Contains($_) } | ForEach-Object { "$f still contains: $_" }
}
```

Expected: no output.

- [ ] **Step 17: Check that the new text is present**

Run:

```powershell
$expect = [ordered]@{
    '.\docs\assessment-rule-packs.md' = '## CIS build-kit ZIP import',
        'Provide exactly one of content or archive.', '44,739,244',
        'Unclassified build kit policies', 'Review & run',
        'Import-IdsBaselinePackSet', 'ConvertFrom-IdsBaselineArchive'
    '.\README.md' = 'Import rule packs', 'Review & run', 'build-kit ZIP', 'New assessment'
    '.\QUICKSTART.md' = 'Import rule packs', 'Review & run', 'build-kit ZIP', 'New assessment'
    '.\docs\operations.md' = 'Import rule packs', 'Review & run', 'build-kit ZIP', 'never kept'
}
foreach ($f in $expect.Keys) {
    $text = (Get-Content -Raw $f) -replace '\s+', ' '
    $expect[$f] | Where-Object { -not $text.Contains($_) } | ForEach-Object { "$f is missing: $_" }
}
(Select-String -Path .\docs\assessment-rule-packs.md -Pattern '^## CIS build-kit ZIP import$').Count
```

Expected: only `1`.

- [ ] **Step 18: Check the shipped documents for tenant data patterns**

`Build-Package.ps1` rejects these patterns in shipped `.md` files. Run:

```powershell
Select-String -Path .\README.md, .\QUICKSTART.md, .\docs\assessment-rule-packs.md, .\docs\operations.md -Pattern '[A-Za-z0-9-]+\.onmicrosoft\.com', '[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}', 'eyJ[A-Za-z0-9_-]{20,}\.[A-Za-z0-9_-]{20,}'
```

Expected: no output.

- [ ] **Step 19: Run the repository checks**

Run:

```powershell
pwsh -NoProfile -File .\scripts\Test-Repository.ps1; $LASTEXITCODE
```

Expected: `Repository guidance and local policy checks passed.` and `0`. The
script may first print `Pull request target policy: not applicable without pull
request event context.` These checks do not read the four documents; they
confirm that the task changed no guarded file.

- [ ] **Step 20: Check the diff scope and line endings**

Run:

```powershell
git --no-pager diff --stat
'.\README.md', '.\QUICKSTART.md', '.\docs\assessment-rule-packs.md', '.\docs\operations.md' |
    Where-Object { (Get-Content -Raw $_) -match '(?<!\r)\n' } |
    ForEach-Object { "LF-only line ending in $_" }
```

Expected: the stat lists only `QUICKSTART.md`, `README.md`,
`docs/assessment-rule-packs.md` and `docs/operations.md`, and ends with
`4 files changed`. The line-ending check prints nothing.

- [ ] **Step 21: Commit**

```powershell
git add README.md QUICKSTART.md docs\assessment-rule-packs.md docs\operations.md
git commit -m "docs: document the assessment wizard and CIS ZIP import" -m "Co-authored-by: Copilot App <223556219+Copilot@users.noreply.github.com>"
```

Expected: one commit with 4 files changed. If the opt-in pre-commit hook is
installed, it runs `scripts\Test-Repository.ps1` and passes.



### Task 8: Full verification

**Files:**
- None. This task only verifies. Fix any regression in the task that caused it, then repeat this task.

**Interfaces:**
- Consumes: everything from Tasks 1–7.
- Produces: the validation evidence for the pull request body. Record each command with its result.

- [ ] **Step 1: Run the Node suites**

Run: `node --test .\tests\publishing-ui.test.js .\tests\assessment-ui.test.js .\tests\app-shell-ui.test.js`

Expected: every test passes, with 0 failures. Before this work 49 tests passed; the total now includes the new tests from Tasks 5 and 6.

- [ ] **Step 2: Run the full Pester suite (about 10 minutes)**

Run: `$r = Invoke-Pester .\tests\*.Tests.ps1 -PassThru; "Passed $($r.PassedCount) Failed $($r.FailedCount) Skipped $($r.SkippedCount)"`

Expected: `Failed 0`. The adversarial package test intentionally prints a line with "FOUT" and "GUID". That line is expected output, not a failure.

- [ ] **Step 3: Run the repository checks**

Run: `pwsh -NoProfile -File .\scripts\Test-Repository.ps1; $LASTEXITCODE`

Expected: exit code `0`.

- [ ] **Step 4: Build the package**

Run: `pwsh -NoProfile -File .\Build-Package.ps1`

Expected: the build ends with "Pakket klaar". `lib\BaselineArchive.ps1` is in the package, and the leak scan reports no findings.

- [ ] **Step 5: Visual check (controller)**

Serve `web\` with a fake API that returns synthetic state and catalog data. Check the Assess view at 1280 px and at 390 px wide:
- The five-step stepper is readable and wraps at 390 px.
- Only one panel is visible at a time.
- The import card shows on steps 1–2 only.
- Back/Next move focus to the panel heading.
- The Windows 11 warning appears when the build is blank.
- The review text lists the platforms, packs and context.
- The landing blocks align at the top and the bottom.

Fix any layout defect in the UI task that introduced it, then rerun Step 1.

- [ ] **Step 6: Confirm the working tree is clean**

Run: `git --no-pager status --short`

Expected: no output. All changes were committed by Tasks 1–7.
