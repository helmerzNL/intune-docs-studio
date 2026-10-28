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

Click **Sign in via the Intune portal** (the top, recommended option).

A separate browser window opens on the Intune admin center. Sign in as you normally would.
That window closes by itself once the tool has what it needs — usually within seconds.

> **Why a separate window?** The tool reads the sign-in from a browser it starts itself, which
> is what allows it to work without an app registration. It cannot use a window you already
> have open. Your sign-in is remembered, so you only do this once.

**Choose the right account.** If you are asked which account to use, pick the administrator
for the tenant you want to document — not your everyday account, if those differ.

## 4. Choose what to document

Pick an **output folder**. Use a separate folder per tenant; the tool will stop you if you
point two different tenants at the same folder.

All areas are selected by default. Tick **Commit to git** if the folder is a Git working copy
and you want each run recorded as a commit.

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

1. Sign in, confirm the tenant, and find **Assess policies** beside the export
   workflow. Select platforms and exact pack versions/profiles. Read their
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

Coverage and alignment percentages concern listed configuration checks, **not
device compliance or certification**. Incomplete/unsupported/manual evidence is
not assessed, never a pass or missing result. Unassigned policies can align
without reaching devices. Potential conflicts mean differing configured values,
not proven overlapping assignments; groups/filters are not resolved to devices.

Imports persist at `%LOCALAPPDATA%\IntuneDocsStudio\AssessmentPacks` through app
updates; active tenant results clear on session reset. Reports are written only
to the report root you choose, never automatically uploaded, committed, or pushed.
Back up packs/reports only as customer-owned files; do not back up tokens or
portal browser profiles. See [operator procedures](docs/operations.md).

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
