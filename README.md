<div align="center">

# Intune Docs Studio

### Your Intune tenant. Finally, an open book.

Turn complex configurations into clear, structured documentation.<br>
From your tenant to a Git-ready Markdown repository — without a new app registration.

**Windows** &nbsp; / &nbsp; **PowerShell 7+** &nbsp; / &nbsp; **Local-first** &nbsp; / &nbsp; **Beta**

[**Get the beta build →**](https://github.com/helmerzNL/intune-docs-studio/actions/workflows/beta.yml) &nbsp; · &nbsp;
[Quick start](#quick-start) &nbsp; · &nbsp;
[Explore the output](#output-structure) &nbsp; · &nbsp;
[Setup guide](QUICKSTART.md)

</div>

---

## Less documenting. More understanding.

For assessments, handovers, and the moment someone asks, **“How is this actually configured?”**

| No new app. No new secret. | The details, connected. | A history you can read. |
|---|---|---|
| Use an existing sign-in method with read-only access. No new Entra ID app registration or client secret to rotate. | Document policies, apps, scripts, and enrollment, with resolved assignment groups and filter rules alongside the settings. | Export Markdown into your Git working folder. Re-run, review the diff, and publish through your own repository. |

Your tenant configuration stays read-only. Your documentation lives in an output folder you
choose. Git publishing is optional; generated tenant documentation should be treated as sensitive.

> **Beta, not a production release.** Validate beta packages before operational use.
> Beta builds are available as ZIP artifacts from successful
> [Beta workflow runs](https://github.com/helmerzNL/intune-docs-studio/actions/workflows/beta.yml).
> GitHub sign-in and access to this private repository are required.

## Quick start

**You need:** Windows and [PowerShell 7 or later](#requirements). Git is optional and only
needed for commit/push functionality.

1. Open a successful [Beta workflow run](https://github.com/helmerzNL/intune-docs-studio/actions/workflows/beta.yml)
   and download its ZIP artifact. Extract the artifact, then extract the included
   `IntuneDocsStudio.zip` application package.
2. Double-click **`Start-IntuneDocs.cmd`** in the extracted application folder.
   The dashboard opens at <http://localhost:7654>.
3. **Connect** — choose a sign-in method and sign in as an administrator with access
   to the Intune areas you want to document.
4. **Configure** — choose your output folder and which areas to document.
5. **Generate** — watch the live progress, inspect the Markdown, and optionally commit and push.

Already have the source or an extracted application package? Open PowerShell 7 in that
folder and run:

```powershell
.\Start-IntuneDocs.cmd
```

| 01 · Connect | 02 · Configure | 03 · Generate |
|---|---|---|
| Your tenant, your sign-in. Read only what your account is allowed to see. | Choose the areas and an output folder you control, separate from the application. | Build a readable reference. Re-run when things change, then review the difference. |

> **Before you connect:** Standard delegated Graph sign-in needs administrator consent.
> The optional portal-session method has different limitations and is not a supported
> Microsoft integration pattern. Read the [sign-in guidance](#which-sign-in-method-should-the-customer-use)
> before choosing a method.

The listener is bound to `localhost` only and requires no elevation. To stop the tool,
use **Stop server** in the dashboard or press Ctrl+C in the console window.
Ctrl+C may leave cmd.exe asking *“Terminate batch job (Y/N)?”*; the server has already
stopped, so either answer is fine.

For a guided walkthrough, see [QUICKSTART.md](QUICKSTART.md). For safe updates, runtime
identity checks, and output backup/restore, see [the operator guide](docs/operations.md).

### Find your way

[Sign-in and permissions](#which-sign-in-method-should-the-customer-use) ·
[Requirements](#requirements) ·
[Output structure](#output-structure) ·
[Tracking changes](#the-point-of-re-running-it) ·
[Azure DevOps publishing](#publishing-to-azure-devops) ·
[Command line](#unattended--command-line) ·
[Security](#security-notes) ·
[Troubleshooting](#troubleshooting)

---

## Why this exists

Most Intune documentation tooling asks the customer to register an application, grant
*application* permissions, mint a client secret and rotate it forever. In many tenants that is
a change-advisory-board conversation, and it leaves a standing credential behind.

This tool does none of that.

| | Old approach | Intune Docs Studio |
|---|---|---|
| App registration | Required | **None** |
| Client secret | Required, must be rotated | **None** |
| Permission type | Application (tenant-wide) | Delegated (the signed-in admin only) |
| Effective scope | Everything, always | Whatever that admin may read, honouring Intune RBAC |
| Audit trail | "the app did it" | The named administrator did it |

### Which sign-in method should the customer use?

**The decisive question is whether anyone available can grant admin consent.** Every
`DeviceManagement*.Read.All` scope is admin-only — a user can never self-consent to them, and
approving them requires **Global Administrator, Privileged Role Administrator, Cloud
Application Administrator or Application Administrator**. An account holding *only* the Intune
Administrator role cannot approve it, even though that same account can read every one of
those objects in the portal.

| Method | Needs consent? | Best for |
|---|---|---|
| **Use my Intune portal session** | **No** | An Intune Administrator with no route to consent. Assessments and one-off handovers. |
| Sign in with browser | Yes, once | The normal case where a Global Admin can approve. Most robust. |
| Device code | Yes, once | Servers, jump hosts, RDP sessions without a usable browser. |
| Azure CLI session | Usually already consented | Hosts with an existing `az login`. Good for scheduled runs. |
| Graph PowerShell session | Usually already consented | Hosts already using `Connect-MgGraph`. |

#### Use my Intune portal session — how it works

The Intune admin center is itself already consented in every tenant. This method opens a
browser to the portal, lets the administrator sign in exactly as they normally do, and reads
the Microsoft Graph token the portal itself obtains. Nothing is registered and no new grant
appears in the directory.

Practical notes, learned the hard way:

- **Windows SSO is deliberately disabled** in that window. Without this, Edge silently signs in
  with the machine's own work account, which is usually a *different tenant* than the one being
  documented — and the export then finds nothing. You will be asked to pick an account; choose
  the administrator for the tenant you are documenting.
- **If the wrong account still signs in automatically**, tick **Force account picker**. That
  signs the browser session out first and opens an InPrivate window, so neither Windows SSO nor
  the browser profile can reuse your everyday account. Security keys, passkeys and Windows Hello
  all keep working — WebAuthn is not tied to a browser profile. The trade-off is that the
  sign-in is not remembered for the next run.
- **The sign-in is remembered** in a profile under `%LOCALAPPDATA%\IntuneDocsStudio`, so this
  is a one-time step. The browser is closed cleanly over CDP so Chromium flushes its cookies
  to disk, and session restore is enabled so the sign-in survives whether or not you tick
  Azure AD's *Stay signed in?* prompt. Use *forget saved session* to switch accounts.
- **The token cannot be renewed** — the refresh token stays inside the portal. Its lifetime is
  set by tenant policy and varies widely (an hour in some tenants, close to a day in others);
  the dashboard shows the actual expiry. When it lapses, sign in again. For anything recurring,
  prefer a method above that can refresh.
- This depends on the admin center's current behaviour and is not a supported Microsoft
  integration pattern. It is excellent for an assessment; it is not a pipeline foundation.

### Permissions requested

All read-only. The dashboard shows which were granted and what is affected if one is missing.

| Scope | Covers |
|---|---|
| `DeviceManagementConfiguration.Read.All` | Configuration profiles, settings catalog, compliance, endpoint security |
| `DeviceManagementApps.Read.All` | Applications, app protection and app configuration policies |
| `DeviceManagementServiceConfig.Read.All` | Enrollment, Autopilot, ESP, terms |
| `DeviceManagementRBAC.Read.All` | Roles and scope tags |
| `DeviceManagementManagedDevices.Read.All` | Device counts and remediation state |
| `Group.Read.All` | Resolving assignment group ids to names |

A user with **Intune Administrator**, **Global Reader** or **Global Administrator** can run it.
A read-only Intune role works too — the export simply contains whatever that role can see.

---

## Requirements

- Windows with **PowerShell 7 or later** (`pwsh` on `PATH`). Windows PowerShell 5.1 is not supported.
- A browser (except for the device-code method)
- `git` on `PATH` — only if you want the commit/push option

No modules to install. `Microsoft.Graph.Authentication` is optional and only used by the
"Graph PowerShell session" sign-in method.

The launcher verifies PowerShell 7 before starting; it never falls back to Windows PowerShell.
If PowerShell 7 is missing or cannot run, it stops and shows installation guidance. Nothing is
installed or updated automatically.

```powershell
# Install PowerShell 7
winget install --id Microsoft.PowerShell --source winget

# Update an existing installation
winget upgrade --id Microsoft.PowerShell --source winget
```

If WinGet is unavailable, use the official download at <https://aka.ms/powershell-release>.
After installation, reopen your terminal so `pwsh` is available on `PATH`. For direct
command-line runs, use `pwsh -NoProfile -File .\IntuneDocsStudio.ps1` with the desired
parameters; the script itself rejects versions older than 7.

## Package identity

A source checkout with no `build-info.json` identifies itself as **beta / development**.
`Build-Package.ps1` creates `IntuneDocsStudio.zip` from the product files only and adds a
`build-info.json` containing exactly `version`, `channel` and `commit`. Its ZIP contents and
timestamps are normalized so repeated builds from unchanged inputs are byte-identical.

For a local development package, the defaults are beta/development:

```powershell
pwsh -NoProfile -File .\Build-Package.ps1 -OutputPath C:\release
```

For a package tied to a source revision, pass its full 40-character lowercase Git SHA:

```powershell
pwsh -NoProfile -File .\Build-Package.ps1 -OutputPath C:\release `
  -Channel beta -SourceCommit 0123456789abcdef0123456789abcdef01234567
```

Stable packages require both `-Channel stable` and an explicit full source SHA; a
development identity cannot be labeled stable. The package includes the publishing guide
and includes `docs/operations.md` only when that guide exists. Contributor/agent instructions,
tests, build scripts, workflows, and design specifications are never shipped.

---

## Output structure

```
intune-docs/
├─ README.md                        tenant, counts, warnings
├─ index.md                         full table of contents
├─ .order                           Azure DevOps wiki page ordering
├─ .gitattributes
├─ configuration/
│  ├─ settings-catalog/<platform>/*.md
│  ├─ templates/*.md
│  ├─ administrative-templates/*.md   ADMX, with category and state
│  └─ custom/*.md                     OMA-URI and custom payloads
├─ compliance/<platform>/*.md         rules + actions for noncompliance
├─ endpoint-security/<category>/*.md
├─ apps/<platform>/*.md               install, detection and requirement rules
├─ app-management/
│  ├─ app-protection/<platform>/*.md
│  └─ app-configuration/*/*.md
├─ scripts/
│  ├─ windows/*.md  macos/*.md        script bodies inline
│  └─ remediations/*.md               detection + remediation scripts
├─ enrollment/
│  ├─ autopilot/*.md  enrollment-status-page/*.md  restrictions/*.md
├─ assignments/
│  ├─ by-group.md                     every object targeted at each group
│  ├─ by-object.md                    included/excluded groups per object
│  └─ unassigned.md                   clean-up candidates
├─ reference/
│  ├─ groups/*.md                     with membership rules and "used by"
│  ├─ filters/*.md
│  └─ roles/*.md                      custom roles only
└─ _raw/**/*.json                     normalised source objects
```

Every page carries YAML front matter (`intuneId`, `objectType`, `platform`, `lastModified`),
an overview table, the settings in readable form, the assignments, and the raw object in a
collapsed `<details>` block.

Where an assignment uses an assignment filter, the filter's **rule is written out beneath the
assignment tables**, so you can see which devices are actually targeted without opening
another page. Filter pages list every assignment that uses them in return.

---

## The point of re-running it

The export is **deterministic**. Object pages contain no export timestamp, JSON keys are
sorted, and files are only rewritten when their content actually changes. A manifest records
what was written so that objects deleted in Intune are pruned from the repository on the next
run. When nothing in the tenant changed, **nothing is written and no commit is made** — the
working tree stays clean and the history stops growing.

That means:

```
git diff
```

shows **exactly what changed in Intune** — nothing else. Point this at a Git working folder,
run it on a schedule, and the commit history becomes a configuration-drift audit trail.

Tick **Commit to git** in the dashboard, or enable **Push to remote** to commit and push.
From the command line, `-GitPush` also enables committing.

### Never fabricates drift

If any area fails to collect — a throttle, a transient Graph error, a dropped connection —
the exporter **skips the clean-up step entirely** and says so. Deleting pages because a call
happened to fail would write "this policy was removed" into the history when nothing of the
sort occurred. A stale page for one run is a far smaller problem than a false deletion in an
audit trail, so incomplete runs never prune.

Endpoints that genuinely do not apply to a tenant (HTTP 400/403/404) are tolerated silently;
transient failures are not.

---

## Publishing to Azure DevOps

The tree is already wiki-shaped: each folder has a matching landing page and a `.order` file.

1. Create an Azure Repos Git repository, or choose an existing documentation repository.
2. In the dashboard's **Git publishing** section, paste its **clone URL** and optionally
   choose a **target branch**. This enables **Commit to git** and **Push to remote**.
3. Choose an **empty output folder** for the first clone, or an existing clean checkout of
   the same repository, then generate documentation.
4. Complete the separate Azure DevOps sign-in through Git Credential Manager if prompted.
   SSH clone URLs use your configured SSH key instead. Do not put tokens in the URL.
5. In Azure DevOps go to **Overview → Wiki → Publish code as wiki** and select the
   repository, branch and folder.

The exporter preserves existing repository history, fast-forwards a clean checkout before
export, and configures branch tracking on the first push. Leave the branch blank to use the
repository default on first clone or the checkout's current branch; an empty repository starts
on `main`. A new target branch starts from the cloned default branch. The tool never replaces a
different remote or force-pushes; resolve local changes or divergent history before exporting.
Generated pages are written at the repository root, so use a dedicated documentation repository.

Re-running the export and pushing updates the wiki in place. See
[`docs/publishing.md`](docs/publishing.md) for GitHub, MkDocs and pipeline examples.

---

## Unattended / command line

```powershell
# Interactive sign-in, then export and commit
.\IntuneDocsStudio.ps1 -Export -OutputPath C:\repos\intune-docs -GitCommit

# Headless host: device code sign-in
.\IntuneDocsStudio.ps1 -Export -Method devicecode -OutputPath C:\repos\intune-docs

# Reuse an existing az login, selected areas only, no script bodies
.\IntuneDocsStudio.ps1 -Export -Method azurecli `
    -Sections settingsCatalog,compliance,apps -NoScriptContent
```

| Parameter | Purpose |
|---|---|
| `-Export` | Run headless, no dashboard |
| `-Method` | `interactive` (default), `browser`, `devicecode`, `azurecli`, `mggraph` |
| `-Client` | `graphcli` (default), `azurecli`, `intuneps` |
| `-Tenant` | Tenant id or domain; defaults to `organizations` |
| `-OutputPath` | Target folder |
| `-Sections` | Subset of areas to document |
| `-GitCommit` / `-GitPush` | Commit and push the result |
| `-GitRemoteUrl` | Existing Azure DevOps HTTPS or SSH clone URL; use with `-GitCommit` or `-GitPush` |
| `-GitBranch` | Target branch; defaults to remote default/current branch, or `main` for an empty remote |
| `-NoScriptContent` | Omit script bodies and custom payloads |
| `-NoRawJson` | Omit the `_raw` tree and the inline JSON blocks |
| `-NoFrontMatter` | Omit YAML front matter |
| `-NoAdoOrder` | Omit `.order` files |
| `-Port` | Dashboard / loopback redirect port (default 7654) |

Delegated tokens are short-lived and interactive by design, so a fully unattended scheduled
run needs the device-code or Azure CLI method with a session that is kept alive. For a truly
unattended pipeline, an app registration remains the right tool — this project exists for the
much more common case where one is unwelcome.

---

## Security notes

- Generated documentation is written to the chosen output folder. Portal-session
  sign-in reads a token from the browser's MSAL cache; its separate profile under
  `%LOCALAPPDATA%\IntuneDocsStudio\browser-profile` may persist cookies and other
  cached authentication material.
- App-managed tokens and normal dashboard state live in process memory; the app
  does not write its token state to disk. Do not back up, copy, or restore browser
  profiles as application data.
- Secret values (`SecretSettingValue`, OMA secret references) are exported as
  `«secret — not exported»`, never as plaintext.
- **Script bodies and custom payloads are included by default** because that is usually the
  point of documenting them. They can contain sensitive material — untick *Include script
  bodies* or pass `-NoScriptContent` if the destination repository is broadly readable.
- The HTTP listener binds to `localhost` only.
- Operator update, backup, and restore procedures are documented in
  [`docs/operations.md`](docs/operations.md).

---

## Troubleshooting

| Symptom | Cause and fix |
|---|---|
| "Need admin approval" on the consent prompt | Your account cannot grant admin consent. Use **Use my Intune portal session**, or have a Global Administrator approve once. |
| Sign-in window opens as the wrong account | Tick **Force account picker** and sign in again. That opens an InPrivate window with the session signed out, so Windows SSO cannot reuse your everyday account. Passkeys and security keys still work. |
| Portal session asks me to sign in every time | Fixed in the current build: the browser is now closed cleanly so Chromium writes its cookies to disk. Note that **Force account picker** deliberately does not remember the session. |
| Portal capture reports "no usable token" | The account signed in may hold no Intune role in that tenant, or the sign-in never completed. The status line lists the API hosts seen. |
| Assignments show `(deleted group …)` | Those assignments target groups that no longer exist in Entra ID. Genuine clean-up candidates — see `assignments/by-group.md`. |
| Assignments show `(group … insufficient permission)` | The sign-in lacks `Group.Read.All`. Object pages are complete; only group *names* are missing. |
| Some areas are empty and a warning appears | The signed-in account lacks the matching scope or Intune RBAC. The dashboard's permission list shows which. |
| `AADSTS50011` redirect URI mismatch | Something is rewriting the loopback redirect. Use the **device code** method. |
| Export is slow in a large tenant | Normal: settings are fetched per policy in batches of 20. Later runs report almost everything as *unchanged*. |
| Port 7654 is in use | Start with `-Port 7655`. |
| PowerShell 7 is missing or cannot start | Follow the launcher's installation/update instructions, reopen the terminal, and run again. Windows PowerShell 5.1 cannot run the tool. |
| `git push` fails | Enter an Azure DevOps clone URL or configure a remote in the output checkout. Check Git credentials and repository/branch permissions. The local commit is retained; re-run to retry the push even if nothing changed. |

---

<div align="center">

**Less guesswork. Better handovers.**

[Setup guide](QUICKSTART.md) · [Publishing guide](docs/publishing.md) ·
[Operator guide](docs/operations.md) · [Security policy](SECURITY.md)

An independent project. Not affiliated with or endorsed by Microsoft.<br>
Microsoft Intune is a Microsoft trademark.

</div>
