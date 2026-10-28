# Operator procedures

This guide covers a local Intune Docs Studio installation. The app is a Windows
PowerShell 7+ process that serves a dashboard on a loopback `HttpListener`,
collects read-only delegated Microsoft Graph data, and writes Markdown to a
chosen output folder. It is not a hosted service.

## Runtime and data boundaries

- The listener binds to `http://localhost:<port>/` (default port `7654`). No
  supported CDN, reverse proxy, ingress, or public TLS deployment exists.
- `GET /api/health` returns `{"status":"ok"}` while the dashboard process is
  serving requests. This is a process/readiness check only; it does not verify
  sign-in, Microsoft Graph access, export completion, or output-folder health.
- `GET /api/version` returns the running build's `version`, `channel`, and
  `commit`. A source checkout without packaged build metadata identifies as
  `beta` / `development`; packaged builds carry their identity in
  `build-info.json`.
- App-managed tokens and normal dashboard state live in process memory; the
  app does not write its token state to disk. Portal-session sign-in reads a
  token from the browser's MSAL cache. Its separate browser profile under
  `%LOCALAPPDATA%\IntuneDocsStudio\browser-profile` may persist cookies and
  other cached authentication material. Do not back up, copy, or restore that
  profile as application data. Sign in again after restoring or moving an
  installation.
- The default export destination is `Documents\intune-docs`; operators can
  select another folder, which the exporter resolves before writing. The export writes
  `.intune-docs-manifest.json`, which records the tenant ID and generated-file
  list. If the destination is a Git checkout, its `.git` directory holds the
  output's repository history. Generated script bodies and custom payloads are
  included by default; restrict access to the output and its backups.
- The exporter refuses to overwrite a manifest associated with another tenant.
  If collection is incomplete, it skips stale-file pruning rather than
  fabricating deletions.

## Start, stop, and verify

Start the supported launcher from the extracted application folder:

```powershell
.\Start-IntuneDocs.cmd
```

PowerShell 7 or later is required; the launcher does not install or update
PowerShell and does not fall back to Windows PowerShell 5.1. The dashboard
opens at `http://localhost:7654` unless another port was configured.

To stop cleanly, use **Stop server** in the dashboard or press Ctrl+C in the
launcher console. Wait for the process to exit before replacing application
files. Do not use the health endpoint as evidence that an export has completed.

After startup, check both endpoints from the same machine:

```powershell
Invoke-RestMethod http://localhost:7654/api/health
Invoke-RestMethod http://localhost:7654/api/version
```

Confirm health is `ok`, then verify the expected version, channel, and source
commit in the version response and dashboard build indicator. Do not begin an
export if the identity is missing or does not match the ZIP/build you intended
to run. Health does not attest to tenant identity or Microsoft Graph access;
confirm the signed-in tenant in the dashboard before exporting.

## Updating the application

Keep the application installation separate from every tenant's generated
output and Git checkout. Never use an output folder as an installation folder.

1. Obtain the replacement ZIP from the intended, trusted beta artifact or
   stable release. Verify its source/build identity from its provenance and
   `build-info.json`; for a beta artifact, compare the commit with the intended
   beta source. Do not infer identity from a filename alone.
2. Stop the running server and wait for its process to exit.
3. Extract the product ZIP into a new, empty, versioned application folder.
   Keep the previous application folder until the replacement passes checks.
   Do not copy output data, `.git` history, credentials, or browser profiles
   into the application folder.
4. Start `Start-IntuneDocs.cmd` from the replacement folder. Confirm
   `/api/health`, `/api/version`, and the dashboard's version/channel/commit
   before using it. Sign in again as needed, and confirm the tenant shown is
   the intended tenant before generating documentation.
5. Retain or remove the previous application folder according to local
   change-control policy only after the replacement has been verified.

The update is a file replacement, not a migration service. No automatic
installation, rollback, or compatibility guarantee between arbitrary builds
is provided.

## Back up and restore generated output

Back up each tenant's output folder as customer data, including
`.intune-docs-manifest.json` and, when present, the complete `.git` directory
and its history. Store backups in an access-controlled location because pages
can include script bodies, device/configuration details, tenant identifiers,
and other sensitive operational data. Choose and test the backup cadence
according to the organization's needs; the application does not schedule or
verify backups.

To restore, restore the complete output to a **new folder**, not over another
tenant's output. Before exporting:

1. Inspect the restored manifest's `tenantId` and compare it with the tenant
   identity shown after signing in.
2. If the folder is a Git checkout, inspect its configured remotes and branch
   (for example, `git remote -v` and `git status --short`) and verify that the
   destination is the intended documentation repository. Do not push until
   that identity is confirmed.
3. Start the intended application build, sign in again, confirm the tenant,
   and only then run an export. Never restore bearer tokens, the browser
   profile, or other sign-in credentials from a backup.

The tenant manifest prevents a detected cross-tenant overwrite; it is not a
backup-integrity check or a guarantee that a restored Git remote is correct.

## Limits and service objectives

There are no measured capacity, throughput, latency, availability, or recovery
objectives for this local tool. No SLO, performance limit, RPO, or RTO is
committed. These values are **unmeasured / not-now**: the application is
operator-run on customer machines. No measured service history or agreed
service commitment is available for deriving a target.
Do not treat example tenant sizes, Graph throttling behavior, or a successful
local test as a measured limit or service guarantee.

Operators own their backup schedule and recovery objectives. Section 18 and
the 111-topic adoption declaration remain incomplete until the authoritative
index, template, validators, and linked reference workflows are supplied.
