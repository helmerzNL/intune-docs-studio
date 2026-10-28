# Publishing the export

The generated folder is designed to be committed straight into a repository. It contains no
build step, no front-end and no absolute paths.

---

## Azure DevOps — publish code as wiki

This is the smoothest destination: the exporter already writes the two things Azure DevOps
needs — a landing page for every folder, and a `.order` file controlling page sequence.

### One-time setup

Create an Azure Repos Git repository or choose an existing **dedicated documentation**
repository. In the dashboard:

1. Set **Output folder** to an empty folder, or an existing clean checkout of that repository.
2. Under **Git publishing**, paste the repository's HTTPS or SSH **clone URL** from Azure
   DevOps. This selects **Commit to git** and **Push to remote**.
3. Optionally enter a **target branch**. Leave it blank for the remote default on first clone
   or the existing checkout's current branch. Empty repositories default to `main`.
4. Generate documentation. The tool clones or reuses the repository, commits the documentation,
   and pushes with upstream tracking.

The equivalent command-line invocation is:

```powershell
.\IntuneDocsStudio.ps1 -Export -OutputPath C:\repos\intune-docs `
    -GitRemoteUrl https://dev.azure.com/<org>/<project>/_git/<repo> `
    -GitBranch main -GitPush
```

`-GitPush` implies `-GitCommit`. To prepare and commit without pushing, use `-GitCommit`
instead. The URL must point to an existing repository; the tool does not create Azure DevOps
projects or repositories.

**Authentication is separate from Intune.** For HTTPS, use Git Credential Manager (included
with Git for Windows) and complete its Azure DevOps browser sign-in when prompted. SSH URLs
such as `git@ssh.dev.azure.com:v3/<org>/<project>/<repo>` use your configured key. Do not embed
passwords or PATs in clone URLs; the app neither accepts nor stores them. Your Git identity needs
repository read/contribute permissions, and branch policies may require publishing to a
documentation branch and opening a pull request yourself.

Existing history is preserved. A clean checkout is fetched and fast-forwarded before export
when a URL is supplied. New branches start from the cloned default branch. Different remotes,
uncommitted changes, unfinished Git operations, and divergent histories stop the export rather
than being silently overwritten or force-pushed. Generated files are placed at the repository
root; do not point this at a source-code repository whose root pages you need to keep.

If you already generated documentation into a non-Git folder, choose a new empty folder for
the clone and re-export, or configure Git there manually. The tool will not clone over existing
files.

Alternatively, configure Git yourself:

```powershell
cd C:\repos\intune-docs
git init -b main
git remote add origin https://dev.azure.com/<org>/<project>/_git/<repo>
```

Use this initialization only for an **empty remote**. For a populated remote, clone it instead
so the existing history is retained. Generate the documentation into that folder
(tick **Commit to git**, or use `-GitCommit`), then:

```powershell
git push -u origin main
```

In Azure DevOps: **Overview → Wiki → Publish code as wiki**, then choose the repository,
branch `main` and folder `/`. Publish.

### Keeping it current

Re-run the export against the same folder and push. Azure DevOps re-reads the branch, so the
wiki reflects the new commit immediately. Pages for deleted Intune objects disappear because
the exporter prunes them.

Keep the same URL and branch selected, or leave the URL blank once the checkout has a remote
and upstream configured. A failed push leaves the local commit intact; re-running with push
enabled retries it even when the documentation has not changed. Git errors appear in the
dashboard and cause command-line exports to exit unsuccessfully.

A weekly scheduled task is usually enough:

```powershell
schtasks /create /tn "Intune documentation" /sc weekly /d MON /st 06:00 ^
  /tr "pwsh -NoProfile -File C:\tools\intune-docs-studio\IntuneDocsStudio.ps1 -Export -Method azurecli -OutputPath C:\repos\intune-docs -GitCommit -GitPush"
```

> Delegated authentication is interactive by nature. For a scheduled run, use the Azure CLI
> method on a host with a maintained `az login`, or the device-code method with an operator
> present. If nobody can be present, that is the one scenario where an app registration is
> genuinely the better tool.

### Provisioned wiki instead of code wiki

If the project already uses a provisioned wiki, clone it (`.../_git/<project>.wiki`), export
into the clone, and push. The `.order` files work identically.

---

## GitHub

Nothing extra is required — every link in the export is relative, so GitHub renders the tree
natively. `README.md` is the landing page, `index.md` is the full table of contents.

For a browsable site, the front matter is already compatible with MkDocs:

```yaml
# mkdocs.yml
site_name: Intune configuration
docs_dir: .
theme:
  name: material
markdown_extensions:
  - tables
  - admonition
  - pymdownx.details      # renders the collapsed raw-JSON blocks
```

---

## Reviewing configuration drift

Because the export is deterministic, the diff *is* the change report.

```powershell
# What changed in Intune since the last documented state?
git diff --stat HEAD~1

# Which policies changed, ignoring the raw JSON sidecars?
git diff --stat HEAD~1 -- ':!_raw'

# Full detail on one policy
git log -p -- "configuration/settings-catalog/windows10/win-defender-baseline.md"
```

A useful pull-request gate: run the export in a pipeline against the production tenant, and
fail the build if `git status --porcelain` is non-empty on a branch that is supposed to be in
sync. That turns undocumented tenant changes into a visible signal.

---

## Splitting by scope

For a large or federated environment, run the export several times with different accounts.
Intune RBAC scope tags mean each administrator's export contains only their own scope, so a
per-region repository or per-region folder needs no extra configuration:

```powershell
.\IntuneDocsStudio.ps1 -Export -OutputPath C:\repos\intune-docs-emea
.\IntuneDocsStudio.ps1 -Export -OutputPath C:\repos\intune-docs-amer
```

---

## What not to commit

The exporter writes `.gitattributes` to normalise line endings. Consider also adding a
`.gitignore` if you keep anything else in the folder — the export itself produces no
temporary files, but a `.intune-docs-manifest.json` is written and **should be committed**:
it is what allows the next run to prune objects deleted from Intune.
