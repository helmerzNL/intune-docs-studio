# Assessment rule-pack contract (schema 1)

Rule packs describe atomic configuration checks; they never execute code, query
Graph, fetch source URLs, change policies, or establish certification/device
compliance. This document defines the pack component. Dashboard upload,
collection, evaluation, reports, and production Microsoft packs are separate
implementation tasks, not functionality supplied by this component alone.

Use only reviewed, licensed content. Microsoft security baselines and Microsoft
recommendations are distinct classifications. Do not redistribute CIS benchmark
content with the application or download it automatically. Customer-imported
packs remain customer-owned local data. Sources establish provenance; validation
does **not** establish the correctness, completeness, authority, or licensing of
a rule.

## Encoding and named resource limits

Input is one UTF-8 JSON object, without a BOM, comments, or trailing commas.
Every field below is required, including fields whose value may be `null`.
Field names and enumerations are case-sensitive. Unknown fields anywhere in the
schema are rejected. Duplicate member names at any nesting level, including
case-colliding names and escaped spellings of the same name, are rejected.

| Limit | Inclusive maximum | Failure |
|---|---|---|
| Pack bytes | 10 MiB (10,485,760 original bytes) | `Pack byte limit exceeded (10 MiB).` |
| JSON nesting | 32 object/array levels, counting the root as level 1 | Invalid JSON/nesting error naming 32 levels |
| Controls | 20,000, with at least one control | Control limit error naming 20000 controls |
| String length | 32,768 UTF-16 code units per decoded string or member name | String limit error naming 32768 characters |

Byte length is checked before decoding/parsing. JSON is parsed with
`System.Text.Json.JsonDocument`, with its nesting limit set explicitly, before
schema validation and conversion to ordinary PowerShell objects. Strings remain
strings, including date-like expected values. Booleans and numbers are never
coerced from strings. Numeric values use native `Int64`, exact `Decimal`, or
finite `Double` representations. Decimal conversion is checked for rounding;
values it cannot preserve exactly use double precision instead. Overflow and
nonzero underflow to zero are rejected. This is not an arbitrary-precision
numeric format.

Unless stated otherwise, a string must contain non-whitespace text. IDs and
array references are compared ordinally (case-sensitive). Arrays remain arrays
when empty or singleton; `false`, zero, empty expected strings, and empty
expected sets retain their types and values.

## Root fields

| Field | JSON type | Rules |
|---|---|---|
| `schemaVersion` | integer | Exactly `1`; not a string or fractional representation |
| `id` | string | Entire value matches `[a-z][a-z0-9.-]{0,127}`; immutable pack identity, never a storage filename |
| `version` | string | SemVer `major.minor.patch`, optional prerelease and build metadata; numeric core/prerelease identifiers have no leading zeros; no `@` or `#` |
| `framework` | string | Framework name; does not itself imply authority |
| `frameworkVersion` | string | Fixed benchmark/framework version |
| `classification` | string enum | `baseline` or `recommendations` |
| `platform` | string enum | `windows11`, `macos`, `iosIpados`, or `androidEnterprise` |
| `profile` | string | Benchmark/profile selection identity |
| `sourceRevision` | string | Fixed reviewed source revision, not an instruction to fetch “latest” |
| `sources` | nonempty object array | Source entries below |
| `coverage` | object | Inventory declaration below |
| `controls` | nonempty object array | Unique atomic control entries below |

`sha256`, `origin`, and `path` are **not** accepted in input JSON.

### Sources

| Field | JSON type | Rules |
|---|---|---|
| `id` | string | Unique within `sources`; referenced by controls |
| `url` | string | Absolute HTTP(S) URL with a host and without user credentials; reference only, never requested by this module |
| `revision` | string | Fixed version/revision of this source |
| `retrievedOn` | string | Valid calendar date in exact `yyyy-MM-dd` form |

Source and control IDs preserve framework spelling (for example `SYN-1`).
The lowercase restricted ID grammar applies to the **pack** ID used in catalog
selection, not to source/control identifiers.

### Coverage

| Field | JSON type | Rules |
|---|---|---|
| `inventory` | string enum | `complete` or `partial` |
| `totalSourceControls` | integer or null | If supplied, at least the number of listed controls; `complete` requires a non-null count exactly equal to the listed count |

`partial` with a null total does not claim a known complete benchmark
denominator. A `complete` declaration is only a structurally consistent author
claim; an authoritative complete inventory must still be reviewed. Assessment
coverage describes assessed listed controls, not device compliance. Overall
benchmark coverage cannot be inferred from a partial pack.

### Controls

| Field | JSON type | Rules |
|---|---|---|
| `id` | string | Unique within `controls` |
| `title` | string | Display title; untrusted text |
| `sourceIds` | nonempty string array | Unique references to existing source IDs |
| `reference` | string | Human-readable framework/control reference |
| `applicability` | object | OS/enrollment constraints below |
| `manualReason` | string or null | Nonempty reason exactly when `mappings` is empty; otherwise must be null |
| `mappings` | object array | One or more alternatives for the same atomic check, or empty for a manual/unsupported check |

Alternative mappings must agree on `valueType`, `operator`, `caseSensitive`,
and expected value (respecting string case sensitivity and unordered set/
membership semantics). Numeric equivalence ignores spelling differences,
including exponent notation and signed zero (`0` equals `-0.0`); numeric-looking
strings remain strings. They may select different policy families, types, setting
identifiers, or instance paths. Do not approximate compound controls with
different atomic checks; use an empty mapping array and explain the limitation
in `manualReason`.

#### Applicability

| Field | JSON type | Rules |
|---|---|---|
| `osMin` | string or null | Inclusive numeric OS version, one to four nonnegative dot-separated Int32 components |
| `osMax` | string or null | Same encoding; must not precede `osMin` when both exist |
| `enrollmentModes` | string array | Unique nonempty stable enrollment-mode identifiers; empty means no mode restriction |

OS versions are compared after padding missing components with zeros. Null OS
bounds impose no bound. Enrollment-mode identifiers are declarative, not code
or inferred labels; normalization/context must supply matching identifiers.
Unknown device/context applicability is not evidence of alignment.

### Mappings

| Field | JSON type | Rules |
|---|---|---|
| `family` | string enum | `settingsCatalog`, `deviceConfiguration`, `compliance`, `admx`, or `intent` |
| `policyTypes` | nonempty string array | Unique declared Graph policy-type identifiers |
| `settingId` | string or null | Stable setting identifier, mutually exclusive with `property` |
| `property` | string or null | Explicit allowlisted property for **every** declared family/policy type; never an object expression or arbitrary path |
| `instancePath` | string or null | Opaque stable nested/repeated-instance identity, not an executable property expression; null if no instance selector is needed |
| `valueType` | string enum | `boolean`, `number`, `string`, `stringSet`, or `numberSet` |
| `operator` | string enum | See operator matrix below |
| `expected` | typed scalar or typed array | Required, never null; exact type/operator constraints below |
| `caseSensitive` | boolean | Required explicitly, including numeric/boolean checks where it has no effect |

Exactly one of `settingId` and `property` must be a nonempty string; the other
must be null. `compliance` and `deviceConfiguration` use allowlisted properties,
not stable-setting-ID selectors. Stable IDs are supported for `settingsCatalog`,
`admx`, and `intent`; their declared policy type/setting support must also be
established by subsequent adapters. A valid declarative ID alone does not mean
collection or normalization supports it.

`Get-IdsAssessmentPropertyCatalog` owns the explicit
`family:policyType -> property -> valueType` allowlist, without depending on the
normalizer. The initial reviewed entries are:

| Family | Policy type | Property | Value type |
|---|---|---|---|
| `compliance` | `macOSCompliancePolicy` | `storageRequireEncryption` | `boolean` |
| `compliance` | `macOSCompliancePolicy` | `systemIntegrityProtectionEnabled` | `boolean` |
| `compliance` | `macOSCompliancePolicy` | `passwordMinimumLength` | `number` |

Encoding source:
[Microsoft Graph v1.0 macOSCompliancePolicy resource](https://learn.microsoft.com/en-us/graph/api/resources/intune-deviceconfig-macoscompliancepolicy?view=graph-rest-1.0).
These definitions establish property names/types only, **not Microsoft
recommended values**. Other property selectors remain rejected until their
Graph definitions are reviewed and the catalog is explicitly extended.

#### Operator/type matrix

| Operator | Permitted `valueType` | `expected` |
|---|---|---|
| `eq`, `ne` | All five types | Typed scalar for scalar types; typed array for set types |
| `gte`, `lte` | `number` only | Number, inclusive bound |
| `in` | `boolean`, `number`, `string` only | Nonempty array of scalars of that type |
| `setEquals`, `containsAll` | `stringSet`, `numberSet` only | Array of strings or numbers matching the set element type |

Equality/inequality on sets uses set semantics. Set ordering and duplicates are
not significant; empty expected sets are valid. String comparisons explicitly
honor `caseSensitive`; they are not locale-dependent label comparisons. Numbers
are not presumed safer merely because they are larger. `"false"` is not
`false`, `"0"` is not `0`, and mixed-type expected arrays are invalid.
Do not use comma-joined display text as an expected set.

## PowerShell interfaces and local storage

Dot-source `lib\BaselinePacks.ps1` under PowerShell 7 or later.

- `Read-IdsBaselinePack -Bytes [byte[]]` returns one `PSCustomObject` containing
  the validated root fields plus lowercase hexadecimal `sha256`. Identity is
  SHA-256 of the **original bytes**, not reformatted JSON. Whitespace-only
  changes therefore change identity. Validation failure throws a terminating
  exception with the failing field/rule/limit; no partially validated pack is
  returned.
- `Get-IdsBaselinePacks -BundledRoot [string] -ImportedRoot [string]` returns one
  object `{ packs = @(); errors = @() }`. It reads direct `*.json` files in
  deterministic filename order, including hidden files, not nested folders or
  staged files. Missing roots mean empty inventories. Each valid pack adds
  `origin` (`bundled` or `imported`) and its absolute local `path`; neither changes
  `sha256`. Each error contains `{ origin, path, reason }`. Invalid files,
  unreadable roots/files, roots that are files, and reparse points are exposed,
  not silently skipped.
- Catalog entries sharing ID/version but different byte hashes are all excluded
  with an error for each conflicting entry, including cross-origin conflicts.
  Byte-identical copies may appear with both origins. Catalog consumers must
  surface errors and must not silently substitute one version/content.
- `Import-IdsBaselinePack -Bytes [byte[]] -ImportedRoot [string]` validates before
  creating storage. Use a customer-owned absolute filesystem directory outside
  the application installation/source tree. Overlapping installation paths
  (including ancestors), relative paths, and reparse-point paths are rejected.
  The caller chooses this controlled storage root; there is no imported
  filename or arbitrary server-side-file-read input.
- Import uses a same-root generated staged file, then a non-overwriting move
  to `<sha256>.json`. Pack IDs are never used as storage names. An exclusive,
  delete-on-close `.import.lock` serializes writes; a competing import fails
  explicitly rather than racing. Staging and lock files are cleaned up on
  success or failure. Interrupted-process orphan staging files are not JSON
  catalog entries.
- Reimporting identical bytes for an existing imported ID/version is
  idempotent. Different bytes for that imported ID/version are rejected; a new
  revision requires a new version. A malformed/conflicting imported catalog
  blocks imports until repaired, without replacing existing packs. Combined
  catalog checks also expose collisions with bundled content. Import returns
  the validated pack without catalog-only metadata.

### Error categories

Validation errors cover invalid UTF-8/JSON/depth; duplicate members; unknown or
missing fields; wrong object/array/scalar types; unsupported schema versions,
platforms, classifications, families, value types, or operators; invalid pack
IDs/SemVer; empty text/required arrays; duplicate IDs/list entries; invalid source
URLs/dates/references; inconsistent inventory counts; malformed/reversed OS
bounds; malformed enrollment modes; ambiguous/missing selectors; unreviewed
properties/type mismatches; invalid expected types/operator combinations; and
manual/mapping or alternative-atomic-check inconsistencies. Resource errors
name the violated limit. Storage errors include invalid/overlapping/reparse
paths, corrupt catalogs, immutable ID/version conflicts, lock contention, and
filesystem/staged-publication failures. Do not treat any error as a valid empty
pack or successful import. Message wording is diagnostic text, not an error-code
API.

Imported strings are untrusted. Later dashboard/report consumers must escape
HTML and Markdown and must not execute text, expressions, URLs, or selectors.
Keep local packs outside application updates and source control. Do not back up
credentials or browser profiles alongside packs.

## Synthetic example — not production guidance

The test factory `New-IdsTestPackBytes` in
`tests\TestHelpers\Assessment.ps1` emits this synthetic rule. Its
`synthetic.required` setting is invented solely for tests; `example.invalid` is
not a guidance endpoint. Do not ship it as Microsoft/CIS content or infer any
recommended configuration from it.

```json
{
  "schemaVersion": 1,
  "id": "synthetic-pack",
  "version": "1.0.0",
  "framework": "Synthetic",
  "frameworkVersion": "1",
  "classification": "recommendations",
  "platform": "windows11",
  "profile": "test",
  "sourceRevision": "synthetic-v1",
  "sources": [
    {
      "id": "source",
      "url": "https://example.invalid/rules",
      "revision": "synthetic-v1",
      "retrievedOn": "2026-10-28"
    }
  ],
  "coverage": { "inventory": "partial", "totalSourceControls": null },
  "controls": [
    {
      "id": "SYN-1",
      "title": "Synthetic required setting",
      "sourceIds": ["source"],
      "reference": "SYN-1",
      "manualReason": null,
      "applicability": { "osMin": null, "osMax": null, "enrollmentModes": [] },
      "mappings": [
        {
          "family": "settingsCatalog",
          "policyTypes": ["configurationPolicy"],
          "settingId": "synthetic.required",
          "property": null,
          "instancePath": null,
          "valueType": "boolean",
          "operator": "eq",
          "expected": true,
          "caseSensitive": true
        }
      ]
    }
  ]
}
```
