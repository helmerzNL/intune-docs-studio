# Policy baseline comparison

Date: 2026-10-28

Status: Written specification approved by the owner on 2026-10-28.

## Purpose and approved scope

Add a standalone, read-only policy assessment to Intune Docs Studio. Compare
configured Intune settings with versioned Microsoft and customer-provided CIS
rules, show the evidence and gaps, and save separate Markdown and JSON reports.
This is configuration alignment analysis, not certification or proof of effective
device protection.

The first release supports Windows 11, macOS, iOS/iPadOS, and Android Enterprise.
Platform support includes collection, normalization, applicability checks,
comparison, and reporting, not a promise that every framework control can be
automated. Android enrollment modes and OS-version requirements are explicit
applicability dimensions.

Confirmed decisions:

- Use the connected tenant and existing read-only authentication.
- Bundle source-verified Microsoft mappings; import CIS rule packs locally.
- Distinguish official Microsoft security baselines from Microsoft recommendations.
- Compare configured values across policies and display assignment evidence and
  potential conflicts, without resolving effective device/user targeting.
- Add a dashboard assessment area and separate Markdown/JSON reports.
- Preserve existing documentation exports and Git publishing behavior.
- Use a framework-neutral, deterministic engine that can accept other frameworks
  through the same declarative rule-pack format.

## Framework availability and claims

Microsoft's Intune security-baseline documentation describes Windows baselines,
not equivalent native baseline templates for every supported platform:

<https://learn.microsoft.com/en-us/intune/device-security/security-baselines/overview>

The page was read on 2026-10-28. This confirms availability and terminology only;
it does not verify individual setting mappings or authorize a conformance claim.

Each bundled Microsoft rule must have a reviewed, authoritative setting-level
reference and a fixed source version or revision. Windows baseline packs must
identify the particular baseline product and release. Non-Windows Microsoft
guidance must be labeled "Microsoft recommendations", with its source revision,
not "Microsoft Security Baseline".

The initial catalog must provide a nonempty verified Microsoft pack for each
supported platform, clearly showing its actual mapped-control coverage. Release
acceptance requires verifying those sources and mappings; example rules or
unsupported placeholders do not satisfy this requirement. Do not invent expected
values to fill a platform or imply that a partial pack covers an entire baseline.

CIS assessment is available for all four platforms when the customer imports a
valid pack for the applicable benchmark version and profile. Do not bundle CIS
benchmark content, download it automatically, or assume redistribution rights.
The customer is responsible for rights to imported material. Import accepts the
documented JSON format, not a PDF, arbitrary Intune export, or unreviewed
automatically extracted benchmark.

The catalog displays unavailable combinations explicitly. Selecting a platform
without an applicable pack must not start an empty, successful assessment.

## Architecture and existing integration points

Use one rules engine rather than separate Microsoft/CIS engines. This avoids
duplicated comparison semantics and permits additional frameworks without
framework-specific executable code. Do not introduce an external assessment
service or send policy data to an AI service.

Keep the responsibilities separate:

| Component | Responsibility |
|---|---|
| Rule-pack handling | Parse, validate, identify, and catalog bundled/imported packs. |
| Assessment collection | Read policy settings and assignments, with explicit completeness evidence. |
| Normalization | Preserve stable identifiers, typed values, nesting, scope, platform, and source-policy provenance. |
| Evaluation | Apply validated declarative rules to normalized evidence. No network or file writes. |
| Report rendering | Render the same result model to Markdown and JSON. |
| Dashboard orchestration | Validate requests, run a background assessment, expose progress/results, and enforce session/job boundaries. |

Use focused PowerShell modules under `lib` and the existing dashboard files under
`web`. Wire orchestration through `IntuneDocsStudio.ps1`. Reuse Graph transport,
authentication, batching, and applicable formatting/file helpers rather than
reimplementing them.

The existing exporter is not an assessment data store:

- `Export-IdsSettingsCatalog` fetches policy settings separately, but its raw
  sidecar stores the policy object rather than that expanded settings evidence.
- `Expand-IdsSettingInstance` prepares display rows, including translated values
  and joined collections, which are unsuitable as canonical comparison data.
- `Invoke-IdsGraph -Tolerant` and `Get-IdsBatchValues` can turn some failures into
  null/empty collections. Assessment collection must retain errors instead.
- Existing export jobs share authentication state and a job handle. Add explicit
  assessment lifecycle state without overwriting an active export job.

Do not broadly refactor exports or change their failure semantics. Any shared
helper change needed for assessment must preserve existing export behavior and
have regression coverage.

## Rule-pack contract

Use versioned, declarative JSON. A pack contains:

- Schema version; immutable pack ID and version; framework name and version;
  baseline/recommendation classification; platform; benchmark profile; applicable
  OS versions and Android enrollment modes; and authoritative source references.
- Explicit coverage metadata identifying whether the listed controls represent
  a complete source inventory or a partial selection.
- Unique control IDs, titles, references, applicability conditions, and either a
  supported mapping or an explicit manual/unsupported assessment reason.
- Mappings containing stable Intune setting identifiers or allowlisted,
  policy-type-specific property selectors, supported source families, value type,
  comparison operator, and expected value.

Support equality/inequality, numeric bounds, membership, and typed set comparison.
Declare case sensitivity and set ordering semantics; never infer security
equivalence from labels or assume a larger numeric value is always safer.
Repeated nested setting groups retain their instance paths, so values from
different instances cannot be combined into a false match.

The initial schema supports atomic mapped checks. Controls requiring compound
logic that cannot be represented faithfully remain not assessed with a reason;
they must not be approximated as atomic checks.

Reject unsupported schema versions/operators/selectors, duplicate IDs, invalid
types, malformed applicability conditions, and inconsistent coverage metadata
before collection begins. Limit each pack to 10 MiB of UTF-8 JSON, 32 nesting
levels, 20,000 controls, and 32,768 characters per string. Document these named
limits in the import contract and reject excess input with a precise error. Packs
cannot contain scripts, executable expressions, arbitrary Graph URLs, or
instructions to fetch their source references.

Treat imported text as untrusted display content. Escape HTML in the dashboard
and Markdown-sensitive content in reports. Store imported packs outside the
application installation and source tree; use the local upload flow, not an
endpoint that reads arbitrary server-side paths.

Capture a SHA-256 hash of the exact validated pack bytes for each assessment.
Snapshot validated packs at job start so later imports cannot change a running
assessment. Updating a bundled pack requires a new pack version and mapping
review; do not silently substitute "latest" during a run.

## Collection and normalized evidence

Read Settings Catalog policies, legacy configuration profiles, compliance
policies, administrative templates, and endpoint-security/security-baseline
policies through explicit adapters. Recognize modern policies by their settings
and template metadata, not only their display category. Avoid counting a modern
endpoint-security policy twice when it is returned with configuration policies.

Each normalized value retains policy ID/name/type, stable setting identity,
typed raw value, nested instance path, platform/applicability information, and
assignment evidence. Display labels are supplementary, never match keys.
Preserve false, zero, null, empty collections, and not-configured states
distinctly. Do not expose secret setting values, payloads, scripts, or tokens in
assessment evidence.

Track completeness per policy source, settings read, and assignment read.
Follow all collection and settings pagination, including batch next links.
Detect exhausted pagination guards, missing batch entries, non-success response
statuses, malformed bodies, and unsupported setting shapes. None is equivalent
to a complete empty collection.

A failed relevant settings source prevents a complete aggregate assessment for
affected controls. An assignment-only failure is visible as unknown assignment
evidence; it does not erase successfully read configuration values. If an
unsupported policy shape could contain a required setting, mark that control
not assessed rather than claiming it is missing.

Unknown OS version or enrollment-mode applicability cannot establish a pass.
Use explicit policy metadata where available and user-selected target
platform/profile context where applicable; disclose the latter as assessment
context, not discovered device inventory.

## Evaluation and result semantics

Evaluate each control against each relevant policy and retain those individual
results alongside its aggregate result:

| Status | Meaning |
|---|---|
| Aligned | Relevant evidence is complete, applicability is known, and all observed mapped values satisfy the rule without contradictory values. |
| Misaligned | Complete, applicable evidence contains configured values that violate the rule, without differing cross-policy values taking precedence. |
| Missing | All relevant supported settings sources were read completely, applicability is established, and the mapped setting is absent/not configured. |
| Potential conflict | Complete evidence contains differing configured values for the same mapped setting across policies. This does not prove targeting overlap or an Intune conflict. |
| Not applicable | Explicit applicability conditions exclude the selected platform/profile context. |
| Not assessed | Relevant collection, applicability, mapping, or automated-rule support is insufficient, with a specific reason. |

For aggregate status, apply known non-applicability first, then insufficient
evidence, differing cross-policy values, absence, and finally rule evaluation.
Keep observed mismatches and potential conflicts visible even when insufficient
evidence makes the aggregate status not assessed.

Different values can be a potential conflict even if both satisfy a numeric
bound. Equal duplicate values are not conflicts. Individual policy results must
not be discarded because another policy has an acceptable value.

Always flag unassigned policies. An aligned but unassigned policy means only that
its configured value matches; it is not evidence that a control reaches devices.
Show included/excluded groups and filters without resolving membership or
claiming effective targeting.

Keep summaries separate per pack/platform/profile. Report counts for every
status and label two distinct measures:

- Assessment coverage: assessed controls divided by all listed controls except
  those explicitly not applicable. Unknown applicability remains in the
  denominator as not assessed, with its count disclosed.
- Configuration alignment: aligned controls divided by assessed controls.
  Misaligned, missing, and potential-conflict controls remain in this denominator.

Zero denominators produce "not available", not 100%. Partial packs describe
coverage of their listed controls only. Overall benchmark coverage may be
reported only when an authoritative complete inventory is supplied and verified.
Never label either measure a device-compliance or certification score.
Here, assessed controls are those classified aligned, misaligned, missing, or
potential conflict; manual/unsupported controls remain not assessed.

## Dashboard, jobs, and output

Add an "Assess policies" area beside the existing export workflow. The user
selects platforms, packs, versions/profiles, and an absolute report destination
separate from the installation and documentation export root. Show pack source,
classification, and coverage before running. Allow local pack imports and show
validation errors without replacing a previously valid pack.

Run collection in a background runspace while the dashboard remains responsive.
Allow only one export or assessment at a time in this release. Extend existing
sign-out, tenant-switch, saved-session-reset, and shutdown safeguards to prevent
cross-tenant or stale-session results. Preserve current loopback and request
protections. Bind results to the tenant/session that started the job; clear
assessment views on sign-out or tenant change.

Expose catalog/import, assessment-start, progress, and result operations through
the existing local HTTP layer. Reject unauthenticated starts and concurrent-job
requests explicitly. Return descriptive validation/collection errors through the
dashboard and logs without exposing credentials.

Results provide summary counts and a filterable control table with expected
and configured values, status/reason, source policies, assignments, and framework
references. Unsupported/manual controls and collection limitations remain visible.

Save each run to a new assessment-owned subdirectory, containing
`assessment.md` and `assessment.json`. Reject installation/export-root overlap;
never prune documentation or overwrite a previous assessment. Do not commit or
push reports automatically.

Both reports use the same schema-versioned result model, with assessment time,
tenant context, selected platforms/profiles, pack versions/hashes, completeness
details, status counts, per-control evidence, and limitations. Tenant context
and policy/assignment evidence are customer-owned and remain local. Reports do
not include full tenant exports, secrets, or browser-session material.

Write reports through staged files and surface write errors. A failed report
write must not display a completed/successful report pair. Stable sorting makes
evidence reproducible for identical inputs; unlike existing policy documents,
assessment reports deliberately include run time and run identity.

## Packaging, documentation, and verification

Add bundled Microsoft JSON packs to an explicit product resource allowlist in
`Build-Package.ps1`, preserving deterministic ZIP behavior. Never include imported
packs, generated reports, tenant data, or this development specification in the
customer package. Do not change `VERSION`, add dependencies, or raise the minimum
PowerShell version.

Update README/quick-start guidance for assessment use, document the JSON pack
contract and coverage semantics, and update operator guidance for local pack and
report locations without recommending credential/browser-profile backups.

Use synthetic fixtures and mocked Graph responses, never a real tenant:

- Verify normalization and applicable rules for all four platforms, including
  Android enrollment-mode distinctions and unknown applicability.
- Cover each supported policy family, nested/repeated instances, encoded choice
  values, typed scalars/sets, and explicit not-configured states.
- Test equal duplicates, mixed aligned/misaligned policies, differing values
  that both meet a bound, unassigned policies, and incomplete assignments.
- Test access failures, unsupported shapes, missing batch responses, paginated
  settings, and truncated collections; none may produce a false pass/missing.
- Test pack validation, unsupported/manual controls, provenance/hash identity,
  escaped imported text, coverage denominators, and zero/partial coverage.
- Test dashboard imports, selection, progress, error display, status filtering,
  tenant reset, concurrent-job guards, and report destination/write failures.
- Verify Markdown/JSON evidence agreement and package inclusion/exclusion.
- Preserve existing authentication, export determinism/pruning, and publishing
  behavior through the repository's existing relevant regression suites.

Use focused Pester and Node tests first. Changes to shared runtime paths require
the documented PowerShell/Node suites and repository check; package changes also
require `Build-Package.ps1` verification with synthetic inputs.

## Non-goals

No automatic remediation, tenant writes, device-level compliance assessment,
effective group/filter evaluation, framework certification, AI-based rule
inference, PDF benchmark conversion, remote rule downloads, historical trend
service, or assessment integration into every documentation export.

## Review gate

This specification records the approved architecture and workflow, not an
implemented feature. Obtain approval of this written specification before
implementation planning. Implementation work starts from and targets `beta`;
stable promotion and release remain owner-authorized operations.
