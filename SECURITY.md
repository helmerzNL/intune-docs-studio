# Security

## Reporting a vulnerability

Please do not report security issues through public GitHub issues. Report them privately
through GitHub's [private vulnerability reporting](https://docs.github.com/code-security/security-advisories/guidance-on-reporting-and-writing-information-about-vulnerabilities/privately-reporting-a-security-vulnerability)
on this repository.

## What this tool does and does not do

Intune Docs Studio is **read-only**. It never creates, modifies or deletes anything in a
Microsoft 365 tenant. Understanding how it authenticates matters for reviewing it:

- **No application registration and no client secret.** Nothing is provisioned in the
  directory, and no standing credential exists.
- **Delegated permissions only.** Every request runs as the signed-in administrator and is
  bound by that person's Intune RBAC. The tool cannot read anything its operator could not
  read in the Intune admin center.
- **App-managed tokens stay in process memory.** The app does not write its token
  state to disk; the portal-session browser has a separate authentication cache.
- **The HTTP listener binds to `localhost` only** and is not reachable from the network.

The optional portal-session method reads a token from the browser's MSAL cache.
Its browser profiles under `%LOCALAPPDATA%\IntuneDocsStudio\browser-profile` (Edge) and
`%LOCALAPPDATA%\IntuneDocsStudio\browser-profile-chrome` (Chrome) may
persist cookies and other cached authentication material. Treat both profiles as sensitive:
do not include it in application backups or restore it onto another installation.

## About the "Use my Intune portal session" sign-in method

This method starts a browser, has the administrator sign in to the Intune admin center as
they normally would, and then reads the Microsoft Graph access token that the portal itself
obtained — from that browser's own MSAL cache, over the Chrome DevTools Protocol.

This is worth being explicit about:

- It grants **no additional privilege**. The operator signs in interactively with their own
  credentials and obtains exactly the access they already have.
- It requires **local access to the machine** and a browser instance this tool started.
  It cannot read tokens from any other browser, profile, session or user.
- Browser choice is explicit; Automatic prefers Edge and uses Chrome only if Edge is absent.
  Policy or CDP failures never switch browsers. Local mandatory policy blockers are reported
  before launch, including a managed `UserDataDir` that would override profile isolation.
  Cloud/effective policy still needs review in `edge://policy` or `chrome://policy`.
  The tool does not modify enterprise policy or disable protection. If CDP is prohibited,
  use standard Graph sign-in with admin consent or an IT-approved management workstation.
- It is **unsupported and depends on current portal internals.** It may stop working when the
  Intune admin center changes. The other sign-in methods do not depend on this.

It exists because the `DeviceManagement*.Read.All` scopes are admin-only: an account holding
just the Intune Administrator role cannot consent to them, even though that same account can
read every one of those objects in the portal. Where admin consent is available, prefer one
of the standard sign-in methods.

## Sensitive content in exports

Script bodies and custom OMA-URI payloads are included by default, because documenting them
is usually the point. They can contain sensitive material. Use *Include script bodies* /
`-NoScriptContent` to omit them, and consider who can read the destination repository.

Secret values (`SecretSettingValue`, OMA secret references) are never exported; they are
written as `«secret — not exported»`.

For operator guidance on the localhost runtime, verifying the running build,
separating application files from customer output, and safe backup/restore, see
[`docs/operations.md`](docs/operations.md). Back up generated output only to an
access-controlled location.
