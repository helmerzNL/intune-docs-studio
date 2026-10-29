# Quick start

Document your Intune tenant as Markdown files, ready for a Git or Azure DevOps repository.
**No Entra ID app registration. Nothing is created or changed in your tenant.**

---

## 1. Extract

Right-click the ZIP → **Extract All**. Put the folder anywhere you like, for example
`C:\Tools\IntuneDocsStudio`.

The ZIP carries its version, channel and source commit in `build-info.json`. A source checkout
without that file identifies as **beta / development**; stable packages must be built with an
explicit full source commit SHA.

## 2. Run

Double-click **`Start-IntuneDocs.cmd`**.

The launcher requires **PowerShell 7 or later**. If it is missing, the launcher stops and
suggests `winget install --id Microsoft.PowerShell --source winget`. To update an existing
installation, use `winget upgrade --id Microsoft.PowerShell --source winget`. Without WinGet,
download PowerShell from <https://aka.ms/powershell-release>. Reopen your terminal after
installation and start the tool again. Nothing is installed automatically, and Windows
PowerShell 5.1 is never used as a fallback.

A console window opens and your browser goes to <http://localhost:7654>. Leave the console
window open while you work — closing it stops the tool.

## 3. Sign in

On the landing page, click **Sign in via the Intune portal** (the recommended option). The
other sign-in methods are under **Advanced sign-in options**.

A separate browser window opens on the Intune admin center. Sign in as you normally would.
That window closes by itself once the tool has what it needs — usually within seconds.

> **Why a separate window?** The tool reads the sign-in from a browser it starts itself, which
> is what allows it to work without an app registration. It cannot use a window you already
> have open. Your sign-in is remembered, so you only do this once.

**Choose the right account.** If you are asked which account to use, pick the administrator
for the tenant you want to document — not your everyday account, if those differ.

After sign-in, choose **Load policies** or **Not now**. Nothing is collected when
you decline, including after reload/polling; Home still opens signed in and offers
an explicit load action. Documentation and Assessment require loaded/imported data.
When loading finishes,
Home shows the signed-in account, tenant, policy counts and collection time, and
two paths: **Document policies** and **Assess policies**. Both use the same
tenant-scoped in-memory policy snapshot. Use **Refresh policies** on Home to
collect changes; this also clears active assessment results. Sign-out or shutdown
discards the live snapshot. Other selected documentation areas are collected on export.

**Already have an export?** Choose **Import an existing policy export** on the
landing page instead of signing in. Select a host JSON folder/ZIP or upload its
ZIP. Supported inputs are a versioned Intune Docs Studio policy set and older
exports containing `_raw` policy JSON; Markdown alone is insufficient. Import is
transactional: a failed replacement keeps the current source. Offline Home shows
the source, environment, dates, family counts and limitations, independently of
any later sign-in. Both documentation and Assessment work without network/auth.
To reconnect, use **Sign in for live policies** on offline Home. You can return
to the active offline workspace without signing in; successful sign-in still
requires explicit collection consent and confirmation before replacing its data.

Use **Export policy set** on Home to write a new JSON subfolder for re-import or
manual zipping. This preserves available policy evidence, names and completeness,
not credentials or recognized secrets. Legacy inventories/settings may be incomplete
and their capture date unknown. Do not treat unknown data as absent configuration.
Only the five policy families are available for offline documentation; apps,
scripts and other live-only categories are disabled. Existing incomplete-family
output is preserved.

**Choose folder** opens a native Windows dialog on the computer running the app.
It is reused for import/export folders and Assessment report destinations; it
does not upload a browser-side directory. Cancel retains the old path. Enter the
absolute host path manually if a dialog cannot open.

If loading fails, use **Retry loading** or check permissions and sign in again.
Partial loads show warnings: assessment keeps incomplete evidence explicit, and
documentation skips incomplete policy families, preserving their previous pages
and raw files without pruning. Sign-out and Stop server can cancel policy loading;
wait for exports and assessments to finish before signing out or stopping.

## 4. Choose what to document

Open **Document policies** and pick an **output folder**. Use a separate folder per tenant;
the tool will stop you if you point two different tenants at the same folder.

All areas are selected by default. Under **Git publishing (optional)**, tick **Commit to git**
if the folder is a Git working copy and you want each run recorded as a commit.

To publish to **Azure DevOps**, paste an existing repository's clone URL under **Git publishing**
and optionally choose a target branch. Use an empty output folder for the first clone, or a
clean checkout of the same repository. **Push to remote** also commits changes. HTTPS sign-in
uses Git Credential Manager; it is separate from your Intune sign-in. Use a dedicated
documentation repository because generated pages are written at its root.

## 5. Generate

Click **Generate documentation** and watch the progress. When it finishes you can browse the
result in the dashboard, or open the folder directly.

## 6. Stop

Click **Stop server** in the top-right of the dashboard. You can also press Ctrl+C in the
console window; cmd.exe then asks *"Terminate batch job (Y/N)?"* — the server has already
stopped at that point, so either answer is fine.

## Optional: assess configured policies

> **Limited preview: five checks in four partial Microsoft packs, not a complete
> baseline or compliance assessment.** Windows 11: two Windows 26H2 baseline
> SmartScreen checks. macOS: one FileVault recommendation. These two platforms use
> **legacy Endpoint Protection only, over Graph beta**; equivalent modern policies
> are not mapped, and the macOS template is deprecated for new profiles.
> iOS/iPadOS: one **personal-only** passcode recommendation. Android Enterprise:
> one **personally-owned work-profile-only** encryption compliance-policy requirement
> recommendation, not proof of device encryption. **Missing** means absent/not
> configured in the completely read **mapped families/policy types only**, not
> tenant-wide absence.

The assessment is a six-step wizard: **Platforms**, **Import packs**, **Baselines**, **Context**,
**Review & run** and **Results**. **Next** checks each step; errors appear below
the stepper.

1. Sign in, confirm the tenant on Home, and open **Assess policies**. On
   **Platforms**, select at least one platform.
2. Press **Next** for **Import packs**. Add multiple files or host folders to the
   queue. Trash removes a queued item without deleting its file. **Import** shows
   each item's real status and an Added/Already present/Skipped/Failed summary
   with reasons; failures do not undo other successes. Continue without importing
   if suitable packs already exist. Choose the licensed CIS Intune build-kit ZIP you downloaded from
   CIS (at most 32 MiB) or one customer-licensed, reviewed schema-1 JSON rule pack
   (at most 10 MiB). The build-kit ZIP is read in memory.
   Its Settings Catalog policies become rule packs labeled CIS without verifying
   the source, so import only your licensed download. The build-kit layout is
   unverified; review the defensive converter's summary of packs, skipped entries
   with reasons and ignored-file counts. Imported packs are never selected
   automatically. A single JSON file must be a schema-1 rule pack; Settings
   Catalog JSON is converted only from a build-kit ZIP. No CIS content is bundled
   or downloaded. PDFs, Excel, XCCDF/OVAL, Group Policy and OMA-URI content are not
   supported; see [the import reference](docs/assessment-rule-packs.md) for
   schema, supported operators, build-kit ZIP conversion, and pack limits
   (10 MiB UTF-8, 32 levels, 20,000 controls, 32,768 characters per string).
   **Policy set as custom reference** instead converts supported complete settings
   from a reference policy set into expected values. This is separate from target
   import, never CIS/certified, and explicitly skips unsupported/conflicting/secret
   evidence and undated legacy references.
3. On **Baselines**, select 1–64 exact pack versions/profiles, with an applicable
   pack for every selected platform. Read their source revision, hash,
   classification, and coverage before running. Profiles identify their baseline
   set and imported origin. Technical details expand on demand. Imported-library
   trash requires confirmation and leaves saved reports intact; bundled packs
   cannot be deleted.
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
5. On **Review & run**, check each platform's exact packs/profiles/versions, target
   policy source and context together. Use **Choose folder** or enter an absolute
   **assessment report destination** outside both the app and documentation
   output trees, then click **Assess selected policies**. Wait for completion
   before another export/assessment, sign-out, reset, or shutdown.
6. On **Results**, inspect summary counts and filter the evidence table by
   status. Read expected and configured values, policy/assignment evidence,
   reasons, and collection limitations. Open the displayed paths: each new run
   folder contains `assessment.md` and `assessment.json`; existing
   exports/manifests are unchanged. **New assessment** returns to **Platforms**
   with your choices kept; it is disabled while an assessment runs.

Coverage and alignment percentages concern listed configuration checks, **not
device compliance or certification**. Incomplete/unsupported/manual evidence is
not assessed, never a pass or missing result. Unassigned policies can align
without reaching devices. Potential conflicts mean differing configured values,
not proven overlapping assignments; groups/filters are not resolved to devices.

Imports persist at `%LOCALAPPDATA%\IntuneDocsStudio\AssessmentPacks` through app
updates, including packs generated from a build-kit ZIP. The build-kit ZIP itself
is not kept, so keep your licensed download. Active tenant results clear on
session reset. Reports are written only to the report root you choose, never
automatically uploaded, committed, or pushed. Back up packs/reports only as
customer-owned files; do not back up tokens or portal browser profiles. See
[operator procedures](docs/operations.md).

---

## What you get

```
README.md              tenant, counts, warnings
index.md               full table of contents
configuration/         settings catalog, templates, ADMX, custom (OMA-URI)
compliance/            rules and actions for noncompliance
endpoint-security/     antivirus, disk encryption, firewall, EDR, ASR
apps/                  install, detection and requirement rules
app-management/        app protection and app configuration
scripts/               PowerShell, shell and remediation scripts
enrollment/            Autopilot, ESP, enrollment restrictions
assignments/           by group, by object, and unassigned objects
reference/             groups, filters, custom roles
_raw/                  the underlying JSON, for diffing
```

## Running it again

Refresh policies on Home before documenting tenant changes in the same session.
Re-run it against the same folder whenever you want. Only what actually changed in Intune is
rewritten — if nothing changed, nothing is written and no commit is made. In a Git folder,
`git diff` then shows exactly what changed in your tenant and nothing else.

---

## Requirements

- Windows, with **PowerShell 7 or later** on `PATH` and Microsoft Edge or Google Chrome installed
- An account with **Intune Administrator**, **Global Reader** or **Global Administrator**
  (a read-only Intune role also works; you simply document what that role can see)
- `git` on your PATH, only if you want the commit option

## If something goes wrong

| What you see | What to do |
|---|---|
| Sign-in window opens as the wrong account | Tick **Force account picker**, then sign in again. This opens a private window with the session signed out, so Windows cannot sign you in automatically with your everyday account. Security keys and passkeys still work. |
| "Need admin approval" | You used one of the *other* sign-in methods. Use **Sign in via the Intune portal** instead — it needs no consent. |
| An area is empty and a warning appears | Your account cannot read that part of Intune. Everything else is still exported. |
| Assignments show `(deleted group …)` | Those policies target groups that no longer exist. A real finding — see `assignments/by-group.md`. |
| Your organisation blocks PowerShell scripts | The launcher will say so. That policy is set by your IT department and cannot be worked around. |
| Port 7654 already in use | Start it as `Start-IntuneDocs.cmd -Port 7655`. |

For the full technical background, permissions and publishing instructions, see `README.md`
and `docs/publishing.md`. Before updating the application or restoring generated output, read
[`docs/operations.md`](docs/operations.md).
