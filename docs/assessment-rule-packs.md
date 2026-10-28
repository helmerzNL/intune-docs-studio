# Assessment rule-pack contract (schema 1)

Rule packs describe atomic configuration checks; they never execute code, query
Graph, fetch source URLs, change policies, or establish certification/device
compliance. This document defines the pack component and reviewed bundled
Microsoft catalog. Dashboard upload, collection, evaluation, and reports are
separate components, not functionality supplied by pack loading alone.

Use only reviewed, licensed content. Microsoft security baselines and Microsoft
recommendations are distinct classifications. Do not redistribute CIS benchmark
content with the application or download it automatically. Customer-imported
packs remain customer-owned local data. Sources establish provenance; validation
does **not** establish the correctness, completeness, authority, or licensing of
a rule.

## Local assessment API

The local server exposes the following backend routes (dashboard controls are
a separate integration). All responses are JSON with `Cache-Control: no-store`.

| Route | Success response |
|---|---|
| `GET /api/assessment/packs` | `200 { packs: [...metadata], errors: [...] }` |
| `POST /api/assessment/packs` | `201 { pack: metadata }` |
| `POST /api/assessment` | `202 { started: true, runId }` |
| `GET /api/assessment` | `200 { running, done, percent, phase, error, partial, reportPaths, summaries }` |
| `GET /api/assessment/results` | `200` with the schema-1 Result |

POST requests require `Content-Type: application/json` (optionally
`charset=utf-8`), and `Origin` and `Host` matching the configured localhost
listener. Imports accept only `{ "content": "original UTF-8 JSON text" }`,
never a server-side file path. The import envelope is bounded to 64 MiB,
including chunked/unknown-length streams; decoded pack content remains bounded
to 10 MiB **before** pack parsing. Imported bytes are stored locally under
`%LOCALAPPDATA%\IntuneDocsStudio\baseline-packs`, outside the installation.
An ID/version collision with different bytes, including a bundled identity,
is rejected without replacing the valid catalog entry.

Start requests are bounded to 64 KiB and contain `packIds`, `context`, and an
absolute `outputPath`. Use the catalog's `selectionId` (`id@version#sha256`).
Select 1–64 unique identities and 1–4 unique `context.platforms`; every selected
platform requires a selected pack. Optional `context.osVersions` maps platform
names to numeric OS-version strings. Optional `context.enrollmentModes` accepts
`androidEnterprise` with `workProfile`, `fullyManaged`, `dedicated`, or
`corporateOwnedWorkProfile`. Omit unknown applicability rather than inventing it.
Reports, installation, and documentation export roots must be mutually disjoint.

Starts/progress/results require sign-in (`401`). Only one export or assessment
may run; identity replacement, sign-out, profile forget, and normal shutdown
are blocked during work (`409`). Active portal sign-in also blocks work and
other identity operations. Completed results belong to the authenticated
session epoch, and are cleared on identity replacement/reset (`404` when no
current result exists). Reset also invalidates pending OAuth/device-code
sign-ins. OAuth callbacks keep the existing redirect/PKCE flow; a callback
arriving during work redirects to `/?signin=busy` without replacing identity.

Malformed input/invalid selections return `400`; foreign-origin requests `403`;
oversized bodies/packs `413`; incompatible media types `415`; storage/worker
startup failures `500`. Worker failures are visible in progress without exposing
provider exception payloads. A failed report write has no successful result or
report pair. Source-read failures remain control-level not-assessed evidence;
authentication failures fail the run. `partial: true` also covers partial pack
inventories, unknown applicability, and incomplete collection/assignments.
Source revisions and coverage limitations remain in catalog/result metadata.
Reports are customer-owned local files; they are never automatically committed
or pushed.

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
recommended values**. The catalog also contains the reviewed encoding entries
used by collection/normalization tests and the production mappings documented
below. A catalog entry alone does not establish a recommendation. Other property
selectors remain rejected until their Graph definitions are reviewed and the
catalog is explicitly extended.

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

## Reviewed bundled Microsoft catalog (2026-10-28)

All four packs are version **1.0.0**, with **partial** inventories and unknown
total source-control counts (`totalSourceControls: null`). There are five listed
atomic checks, not five complete benchmark controls. The `IDS-*` control IDs are
application-owned identifiers, **not official Microsoft framework numbering**.
Titles and reference descriptions are concise original summaries of public
facts. No CIS content is included.

| File / pack ID | Classification / fixed guidance version | Profile / listed checks |
|---|---|---|
| `baselines\microsoft-windows-11.json` / `microsoft-windows-11` | **baseline** / Windows 26H2 | Shell SmartScreen through legacy Endpoint Protection; 2 atomic checks |
| `baselines\microsoft-macos.json` / `microsoft-macos` | **recommendations** / Zero Trust endpoints, updated 2026-03-26 | FileVault enablement through legacy Endpoint Protection; 1 check |
| `baselines\microsoft-ios-ipados.json` / `microsoft-ios-ipados` | **recommendations** / iOS/iPadOS personal level 1, updated 2026-10-22 | Personal device passcode requirement through legacy device restrictions; 1 check |
| `baselines\microsoft-android-enterprise.json` / `microsoft-android-enterprise` | **recommendations** / Android personally-owned work profile level 2, updated 2026-07-01 | Device encryption compliance requirement; 1 check |

### Source evidence

These pages were independently read on **2026-10-28**. Revisions are the served
Learn `updated_at` date plus the content Git revision, not an invented framework
release. Full hashes and retrieval dates are also recorded in each pack.
Recommendation/value sources and Graph **encoding-only** sources are separate.

| Evidence key | Official source / revision | Reviewed section and fact |
|---|---|---|
| W | [Windows baseline reference](https://learn.microsoft.com/en-us/intune/device-security/security-baselines/ref-windows-mdm-settings?pivots=mdm-26h2), updated 2026-10-05, Git `63ff44f43d17d04e8cbcf5c1ab60f7614f49762e` | **Security Baseline for Windows, version 26H2**, Administrative Templates > Windows Components > File Explorer: SmartScreen enabled; device option warns and prevents bypass. The [baseline overview](https://learn.microsoft.com/en-us/intune/device-security/security-baselines/overview), same revision, lists Windows 26H2 without a preview label. |
| WG | [windows10EndpointProtectionConfiguration, Graph beta](https://learn.microsoft.com/en-us/graph/api/resources/intune-deviceconfig-windows10endpointprotectionconfiguration?view=graph-rest-beta), updated 2026-01-08, Git `0b52ae19972cd7e12cd0217dfb7ea043fad86019` | Properties and JSON representation: `smartScreenEnableInShell` and `smartScreenBlockOverrideForFiles` are Boolean. The former configures Windows SmartScreen; the latter controls bypass of warnings for files, not Edge URL warnings. |
| WC | [SmartScreen Policy CSP](https://learn.microsoft.com/en-us/windows/client-management/mdm/policy-csp-smartscreen), updated 2026-10-23, Git `6e5887a2f20ef9f4a897a01f069534e71a53d71e` | `EnableSmartScreenInShell`: 1 enables; `PreventOverrideForFilesInShell`: 1 prevents override. Both are device-scoped, available on Windows 10 1703+ including Windows 11; group-policy mappings identify the SmartScreen setting and its option. These CSP integers establish semantics, **not Graph encodings**; the mapped Graph properties are booleans. |
| M | [Zero Trust endpoints](https://learn.microsoft.com/en-us/security/zero-trust/deploy/endpoints), updated 2026-03-26, Git `54dc947cde988cf65f5189e174c3a227ac950d47` | Deployment objective 3, Encrypt devices: use FileVault for macOS full-disk encryption. This is directional recommendation guidance, not a macOS security baseline or a recovery-key prescription. |
| MD | [FileVault deployment](https://learn.microsoft.com/en-us/intune/device-configuration/endpoint-security/encrypt-filevault-macos), updated 2026-09-28, Git `73d3f16e19f4e30a39496fe4bb4ff0be85c4f296` | Prerequisites: macOS 10.13+ and user-approved MDM. Policy types: the legacy Endpoint Protection template includes FileVault but is deprecated for creating profiles; use Endpoint security/Settings Catalog for new deployment. |
| MG | [macOSEndpointProtectionConfiguration, Graph beta](https://learn.microsoft.com/en-us/graph/api/resources/intune-deviceconfig-macosendpointprotectionconfiguration?view=graph-rest-beta), updated 2026-01-08, Git `0b52ae19972cd7e12cd0217dfb7ea043fad86019` | `fileVaultEnabled` is Boolean: whether FileVault should be enabled. It **configures** FileVault; it is not `macOSCompliancePolicy.storageRequireEncryption`, which only requires encryption for compliance. |
| I | [iOS/iPadOS personal security configurations](https://learn.microsoft.com/en-us/intune/device-security/security-configurations/ios-ipados-personal), updated 2026-10-22, Git `81d3141082938db877de43c78cb57af1ea40f62b` | Personal basic security (level 1), **Device restrictions**, Password: require a password = Yes. Level 1 is the recommended minimum for personal devices. The table is not a compliance-policy table despite the article introduction mentioning compliance. |
| IG | [iosGeneralDeviceConfiguration, Graph v1.0](https://learn.microsoft.com/en-us/graph/api/resources/intune-deviceconfig-iosgeneraldeviceconfiguration?view=graph-rest-1.0), updated 2025-12-03, Git `e8eace7fa9bfa9e7afacfe9f5dec1ba42ffd493f` | `passcodeRequired` is Boolean: require a passcode. This deviceConfiguration resource maps the restriction, unlike a compliance-only requirement. |
| A | [Android personally-owned work profile configurations](https://learn.microsoft.com/en-us/intune/device-security/security-configurations/android-personally-owned), updated 2026-07-01, Git `a60f43f6f562ded6195ddd8d888335f2d8e11e73` | Personally-owned work profile enhanced security (level 2), **Device compliance**, System Security: require encryption of data storage = Require. Level 2 is the minimum recommended level; there is no level 1 offering here. |
| AG | [androidWorkProfileCompliancePolicy, Graph v1.0](https://learn.microsoft.com/en-us/graph/api/resources/intune-deviceconfig-androidworkprofilecompliancepolicy?view=graph-rest-1.0), updated 2025-12-03, Git `e8eace7fa9bfa9e7afacfe9f5dec1ba42ffd493f` | `storageRequireEncryption` is Boolean: require encryption on Android devices. This is a compliance requirement, not a policy that initiates encryption. |

### Per-control mapping review

Evidence keys resolve to the exact URLs/revisions/sections above. Every row uses
`operator: eq`, `expected: true`, `valueType: boolean`, `caseSensitive: true`,
with null `settingId` and `instancePath`. Every policy type is in the
`microsoft.graph` namespace. Positive/negative examples below are **synthetic
raw Graph-property payloads**, not tenant evidence, and pass through production
`Read-IdsBaselinePack`, `ConvertTo-IdsAssessmentSnapshot`, and
`Compare-IdsAssessment` in `tests\AssessmentBaselines.Tests.ps1`.

| Pack/version | Control ID | Source URL/revision/section | Recommended value | Graph family / policy type + property | Encoding/type | Applicability | Synthetic positive case | Synthetic negative case |
|---|---|---|---|---|---|---|---|---|
| microsoft-windows-11 / 1.0.0 | IDS-WIN-SHELL-SMARTSCREEN | W + WG + WC | Enabled | deviceConfiguration / windows10EndpointProtectionConfiguration / smartScreenEnableInShell | JSON Boolean `true` | Windows 11, OS 10.0.22000+; managed device scope | `smartScreenEnableInShell: true` → aligned | `smartScreenEnableInShell: false` → misaligned |
| microsoft-windows-11 / 1.0.0 | IDS-WIN-SHELL-NO-BYPASS | W + WG + WC | Warn and prevent bypass: prevent override component | deviceConfiguration / windows10EndpointProtectionConfiguration / smartScreenBlockOverrideForFiles | JSON Boolean `true` | Windows 11, OS 10.0.22000+; managed device scope | `smartScreenBlockOverrideForFiles: true` → aligned | `smartScreenBlockOverrideForFiles: false` → misaligned |
| microsoft-macos / 1.0.0 | IDS-MAC-FILEVAULT | M + MD + MG | Configure FileVault enabled | deviceConfiguration / macOSEndpointProtectionConfiguration / fileVaultEnabled | JSON Boolean `true` | macOS 10.13+, Intune-managed/user-approved MDM prerequisite | `fileVaultEnabled: true` → aligned | `fileVaultEnabled: false` → misaligned |
| microsoft-ios-ipados / 1.0.0 | IDS-IOS-PASSCODE | I + IG | Require password = Yes | deviceConfiguration / iosGeneralDeviceConfiguration / passcodeRequired | JSON Boolean `true` | Personal iOS/iPadOS only; context mode `personallyOwned` | `passcodeRequired: true` → aligned | `passcodeRequired: false` → misaligned |
| microsoft-android-enterprise / 1.0.0 | IDS-ANDROID-ENCRYPTION | A + AG | Require encryption for compliance | compliance / androidWorkProfileCompliancePolicy / storageRequireEncryption | JSON Boolean `true` | Personally-owned Android Enterprise work profile only; context/policy mode `workProfile` | `storageRequireEncryption: true` → aligned | `storageRequireEncryption: false` → misaligned |

### Coverage boundaries and interpretation

- **Partial means partial.** Other controls in these sources are not assessed;
  no complete inventory denominator has been reviewed. Percentages describe only
  listed checks, never platform security, device compliance, or certification.
- Windows uses real **26H2 baseline values**, not relabeled Zero Trust compliance
  guidance. Choosing those values as the comparison reference does not assert
  the target device runs 26H2: the two shell settings exist on earlier Windows
  11 releases too. OS context uses Windows build versions (for example
  `10.0.22000`), not the marketing label `11`.
- Windows enablement and bypass prevention are **separate atomic checks**.
  An aligned bypass flag alone does not imply SmartScreen is enabled. Both
  must be reviewed, including assignment evidence; no compound/effective-device
  protection claim is made.
- Windows and macOS mappings intentionally cover **legacy deviceConfiguration
  properties over Graph beta**, supported by the existing beta transport. Beta
  resource definitions can change more frequently. macOS Endpoint Protection is
  deprecated for new profile creation; this pack assesses existing profiles,
  not a recommended deployment route.
- Modern Settings Catalog, ADMX, intent, endpoint-security and security-baseline
  template setting IDs are **not mapped** here: no static Graph identifier was
  established. A setting present only in those families cannot satisfy these
  property checks. **Missing means absent from the mapped policy family**, not
  absent from every policy in the tenant. These packs do not establish conflict
  detection across equivalent modern settings. Review those policies separately
  until verified alternative mappings are added in a new pack version.
- FileVault assessment checks **configuration enablement only**, not successful
  encryption, key escrow, key type/rotation, user approval, or deferral behavior.
  A compliance encryption requirement cannot satisfy this configuration check.
  No recovery-key material is collected by these property mappings.
- iOS uses the source's **device restriction** setting, not a compliance-policy
  substitute. Personal guidance is not applied to corporate/supervised/ADE
  contexts. Callers must explicitly provide
  `context.enrollmentModes.iosIpados = 'personallyOwned'`; this is selected
  assessment context, **not discovered ownership**. Unknown mode is not assessed.
- Android coverage is personally-owned `workProfile` only, not fully managed,
  dedicated, or corporate-owned work profile. Its encryption rule assesses a
  **compliance requirement**, not encryption deployment or actual device state.
  Unknown enrollment mode is not assessed; excluded modes are not applicable.
- macOS **Change At Next Auth** was not mapped: its recommended false value
  cannot justify inventing a Settings Catalog ID or using compliance password
  properties. iOS/Android password-length/type rules and other source settings
  remain outside this intentionally small reviewed inventory.

Each mapped property also has synthetic absent (`missing`) and string `"true"`
(`notAssessed`, never boolean-coerced) cases. Additional tests prevent macOS/iOS
compliance substitution and exercise excluded/unknown enrollment and macOS OS
applicability. Tests check mapping behavior; the source review above, not URL or
schema assertions alone, establishes the provenance of the chosen values.
