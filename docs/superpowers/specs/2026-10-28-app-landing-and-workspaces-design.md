# Landing page and signed-in workspaces — design

Date: 2026-10-28
Status: Draft for owner review. The owner was unavailable during brainstorming and
asked for autonomous progress, so the decisions below use the recommended option
for each question. Every decision is listed in "Decisions to confirm" so the
owner can overturn it during PR review. Nothing merges into `beta` before that
review.

## Goal

Give Intune Docs Studio a professional, good-looking front end:

1. A **landing page** shown to signed-out users, whose only job is to explain
   the product briefly and let the operator sign in.
2. After sign-in, a **signed-in workspace** with distinct paths:
   **Document policies** (the existing export) and **Assess policies** (the
   existing baseline assessment), reachable from a **Home** view.

Today everything is one long page of numbered cards (Connect, Assess,
Configure, Progress, Result). The redesign changes presentation and navigation
only. Export, assessment, sign-in, Git publishing and runtime behavior stay
exactly as they are.

## Non-goals

- No server, route, authentication, token or Graph changes. `IntuneDocsStudio.ps1`
  and `lib\*.ps1` are not modified.
- No new export or assessment capabilities, and no history or reports page.
- No light theme, per-route document titles, localization or framework
  migration.
- No new packaged files. The package allow-list stays `web\index.html`,
  `web\app.js` and `web\style.css`, so the package keeps its 31 files.
- No external assets: no web fonts, CDNs, remote images or analytics. The app
  must render fully offline on loopback.

## Approaches considered

| Approach | Summary | Verdict |
|---|---|---|
| **A. Hash-routed views in the existing page** | One `index.html` contains the landing view and a signed-in shell with Home, Document and Assess views. A small router in `app.js` shows one view based on `location.hash` (`#/`, `#/document`, `#/assess`) and on sign-in state. | **Chosen.** No server changes, element IDs and polling logic stay intact, existing tests keep working, and in-memory job state survives navigation. |
| B. Separate server-served pages | `/document` and `/assess` served by new server routes, with the shell duplicated per page. | Rejected. Requires server and package allow-list changes, and a full page load loses in-memory UI state (selections, pollers, results). |
| C. Front-end framework with a build step | React or similar, bundled. | Rejected. Adds dependencies and a build pipeline, which `AGENTS.md` forbids without need. |

## Information architecture

One persistent top bar is always visible (see "Top bar"). Below it:

| State | URL hash | What renders below the top bar |
|---|---|---|
| Server state not yet loaded | any | A minimal centered loading mark ("Connecting to the local server…"). |
| Signed out | any | **Landing** view only. The hash is ignored and left unchanged. Sign-in methods that stay on the page (portal, device code, Azure CLI, Graph PowerShell) therefore land on that route. Interactive browser sign-in leaves the page and returns to Home. |
| Signed in | `#/` or empty or unknown | **Home** view. |
| Signed in | `#/document` | **Document policies** view. |
| Signed in | `#/assess` | **Assess policies** view. |

All views stay in the DOM and are toggled with the existing `.hidden` class.
Navigating never cancels, restarts or duplicates an export or assessment.
Their pollers keep running while another view is shown.

## Landing view (signed out)

A full-height, two-column layout. Below 900 px wide it stacks, with a condensed
hero above the sign-in card.

**Left: product hero** on a deep navy background with soft radial accent glows
and a faint inline-SVG grid pattern. The brand and product name are already in
the top bar, so the hero does not repeat them:

- A small eyebrow label "Microsoft Intune · documentation and assessment".
- Headline: "Document and assess your Microsoft Intune configuration".
- One-line subtext: "A local tool for Intune administrators. No app registration
  required."
- Three feature rows, each with an inline SVG icon, a title and one sentence:
  - **Document policies**: "Export configuration to Markdown, with optional
    publishing to an Azure DevOps Git repository."
  - **Assess against baselines**: "Compare configured policies with bundled
    Microsoft checks and your own imported CIS rule packs. This is configuration
    alignment, not device compliance."
  - **Read-only and local**: "Runs on this computer. Nothing is created in
    your tenant."
- Copy must not claim compliance, certification, security posture or data
  residency beyond what the app already states.

**Right: sign-in card** (a raised surface, max width about 440 px):

- Title "Sign in", plus a muted line naming the accepted roles (Intune
  Administrator, Global Reader or Global Administrator).
- `signinError` alert region at the top of the card.
- Primary full-width button **Sign in via the Intune portal** (`btnBrowser`)
  with a "Recommended · no consent needed" pill and one sentence of explanation.
  The browser status line (`browserStatus`/`bsText`), the **Force account
  picker** checkbox (`optForcePicker`) and the **Forget saved session** link
  (`btnForget`) sit directly under it.
- A `<details>` disclosure, **Advanced sign-in options**, containing:
  - Tenant (`tenant`) and client application (`client`, `clientNote`) fields.
  - The existing consent explanation for the other methods.
  - The four other method buttons (`btnInteractive`, `btnDeviceCode`,
    `btnAzureCli`, `btnMgGraph`) and the device-code pane (`deviceCodePane`,
    `dcUri`, `dcCode`, `dcStatus`).
  - The disclosure opens automatically when the tenant value is not the
    default `organizations` (for example, a remembered tenant), so a
    non-default tenant is never hidden.

The tenant field moves into the disclosure. It still feeds the portal sign-in
request as it does today.

## Top bar (all states)

One sticky `header.topbar`. Every element exists once, so no IDs are
duplicated and nothing moves in the DOM:

- **Left:** brand mark + `appName`. `renderBuild` keeps setting the name with
  the channel marker for non-stable builds.
- **Center (signed in only):** primary navigation (`appNav`) with **Home**,
  **Document policies** and **Assess policies** as `<a href="#/…">` links.
  The active link carries `aria-current="page"`.
- **Right:** build badge (`buildInfo`, always); account chip (`connBadge`,
  signed in only); **Sign out** (`btnSignout`, signed in only); **Stop server**
  (`btnQuit`, always, so an operator can stop the app from the landing page as
  well).

The Document and Assess navigation items each show a small pulsing activity
dot, with a visually hidden "running" label, while that job is busy. The dots
are driven by the existing `exportBusy`/`assessmentBusy` flags through
`syncJobAdmission()`, which already runs on every busy-state change.

## Home view

- Greeting: "Welcome" with the account name, and the tenant underneath.
- Two large path cards, implemented as links so they work without JavaScript
  routing:
  - **Document policies** → `#/document`. Icon, two-line description, a
    "Start documenting" call to action, and an activity badge ("Export
    running") while busy.
  - **Assess policies** → `#/assess`. Icon, description that includes "not
    device compliance", an "Open assessment" call to action, and an activity
    badge ("Assessment running") while busy.
- **Connection** panel: the existing `connectedPane` content (`cAccount`,
  `cTenant`, `cClient`, `cMethod`, `scopeList`) shown as a compact
  definition list and permission list.

## Document policies view

Page header (title, one-line description, "← Home" link), then a three-step
indicator: **Configure → Generate → Review**. The current step is derived from
existing card visibility: the configure card enabled, `cardRun` visible, or
`cardResult` visible.

The existing cards keep their IDs and behavior, restyled and grouped:

- `cardConfigure` with sub-sections **Destination** (`outputPath`,
  `folderWarn`), **Content** (sections with all/none), **Options**, and
  **Publish to Git (optional)** as a `<details>`, which opens automatically
  when `gitRemoteUrl` has a value. The primary action is `btnExport`.
- `cardRun` (progress, log) and `cardResult` (summary, file list, preview,
  `btnOpen`, `btnAgain`), unchanged in behavior.

## Assess policies view

Page header (title, one line that repeats the configuration-alignment
limitation, "← Home" link), then:

1. **Baselines**: `assessmentCatalogNote`, `assessmentCatalogErrors`, target
   platforms, profile filter, pack list, and **Import a rule pack** as a
   `<details>` (`assessmentImportFile`, `btnAssessmentImport`, limits text).
2. **Applicability context (optional)**: OS versions, Android enrollment mode,
   iOS ownership (the select still starts with `<option value="">Unknown</option>`).
3. **Run**: `assessmentOutputPath`, `btnAssessmentRun`, `btnAssessmentRefresh`,
   `assessmentError`, progress bar and status.
4. **Results**: report paths, limitations, summary tiles (`assessmentSummary`),
   status filter, evidence table, and the existing details disclosure for
   context, pack identities and collection completeness.

All existing IDs, labels, captions and limitation text stay as they are. Only
grouping and styling change.

## Visual system

- **Theme:** a refined version of the existing dark theme. Tokens live in
  `:root` (`--bg`, `--surface`, `--surface-2`, `--border`, `--text`,
  `--muted`, `--accent`, plus new `--accent-2` violet, `--shadow`,
  `--radius-lg`). Hard-coded colors are replaced with tokens where touched.
- **Typography:** "Segoe UI Variable Display" for headings, falling back to
  "Segoe UI Variable", "Segoe UI" and system-ui. No web fonts.
- **Components:** buttons (primary, secondary, ghost, link), pills, badges,
  path cards with hover lift, section headers, a stepper, an alert, and
  `<details>` disclosures with a rotating chevron.
- **Icons:** inline SVG in `index.html` using `currentColor`, with
  `aria-hidden="true"` and `focusable="false"`. No icon font or image files.
- **Motion:** short (≤200 ms) transitions on hover and focus, plus the
  activity-dot pulse. All motion is disabled under
  `prefers-reduced-motion: reduce`.
- **Responsive:** breakpoints at 900 px (landing stacks, top-bar navigation
  moves to its own row) and
  640 px (single-column forms, compact header). No document-wide horizontal
  overflow at 360 px. The evidence table keeps its own horizontal scroller.
- **Accessibility:** `header`/`nav`/`main` landmarks; a skip link to main
  content; visible `:focus-visible` rings; colors that meet WCAG AA text
  contrast against their surfaces; status regions keep `role="status"` and
  `aria-live`; activity dots carry text alternatives.

## Behavior and data flow

- `refreshState()` keeps its current role. After `renderAuth()` it calls
  `renderRoute()`.
- `renderRoute()` reads `state` and `location.hash`, then:
  - if `state` is null, shows only the loading view;
  - if signed out, shows only the landing view;
  - otherwise shows exactly one workspace view, reveals the signed-in top-bar
    items, and updates
    `aria-current` on the navigation.
- A `hashchange` listener calls `renderRoute()` and then moves focus to the
  newly shown view's heading (`tabindex="-1"`). Focus does not move on
  state-driven re-renders, so polling never steals focus.
- **Sign-out** (`btnSignout`) keeps today's flow. The resulting signed-out
  state renders the landing view.
- **Session expiry** (`assessmentSessionFailure`, 401) keeps today's flow and
  also shows "Your session ended. Sign in again to continue." in
  `signinError` on the landing view. `clearWorkspace()` clears that error
  first, so the session message is set after the workspace is cleared.
- **OAuth return** (`/?signin=…`) is handled as today. The query is stripped
  with `history.replaceState`, keeping any hash, and the user lands on Home.
- **Stop server** keeps today's guard, confirmation and stopped page. The
  stopped page is restyled with the theme tokens.

## Error handling

- `/api/state` failure on load: the loading view changes to "The local server
  is not responding. Restart Intune Docs Studio." with a **Retry** button that
  calls `refreshState()`.
- Every existing error surface (`signinError`, `folderWarn`, `assessmentError`,
  alerts for 409 conflicts) stays in place, inside the view where it is
  relevant.

## Testing

- **New** `tests\app-shell-ui.test.js` (Node, fake DOM in the style of the
  existing suites, extended with `location.hash` and `window` event
  listeners). It covers:
  - signed out → only the landing view is visible, for `#/`, `#/document` and `#/assess`;
  - signed in → Home by default, `#/document` and `#/assess` show exactly one view,
    unknown hash → Home, `aria-current` follows the route;
  - `hashchange` re-renders the route;
  - sign-out renders the landing view; a 401 assessment response renders the
    landing view with the session-ended message;
  - activity indicators follow `exportBusy` and `assessmentBusy`;
  - the advanced sign-in disclosure opens for a non-default tenant;
  - the `/api/state` failure shows the retry message.
- **Static HTML checks** in the same file:
  - every literal `$('id')` used in `app.js`, plus the computed
    `assessmentOs*` IDs and the IDs listed in its clear-lists, exists exactly
    once in `index.html`, and `index.html` has no duplicate IDs. The fake DOM
    creates any requested ID, so without this check a missing element would
    go unnoticed;
  - `index.html` and `style.css` reference no external `http(s)` resources
    except documentation links (`<a href>`);
  - the iOS ownership select still starts with `Unknown`.
- Both existing harnesses gain the minimal `window.addEventListener` and
  `location.hash` stubs needed to load the new `app.js`. Their assertions are
  unchanged.
- The CI, beta and release workflows run the new suite next to the existing
  two. `AGENTS.md` lists all three Node suites.
- **Visual verification** uses a throwaway Node preview server kept in the
  session folder, not in the repository. It serves `web\` and returns
  synthetic `/api/state` responses for the signed-out, signed-in and busy
  states. The landing page, Home, Document and Assess views are checked in
  the browser canvas at 1280 px and 390 px wide, with keyboard focus and no
  horizontal overflow. No tenant, token or customer data is used.
- Full Pester suite (gating on the `-PassThru` counts), all Node suites,
  `scripts\Test-Repository.ps1`, and a package build confirming 31 files.

## Documentation

`README.md`, `QUICKSTART.md`, `docs\operations.md` and
`docs\assessment-rule-packs.md` replace the step-card wording ("Connect",
"Configure the export", "beside the export") with the landing → Home →
Document/Assess navigation. Button names that still exist keep their exact
labels.

## Decisions to confirm (made autonomously)

1. Paths after sign-in: **Home + Document policies + Assess policies**.
   Connection details live on Home rather than in a separate page.
2. Sign-in hierarchy: the portal session is primary; tenant, client and the
   four other methods sit under **Advanced sign-in options**.
3. Theme: a refined **dark** theme only (no light theme or system switching).
4. Routing: client-side hash routes (`#/document`, `#/assess`); no server
   changes.
5. Landing copy as drafted above, limited to claims the app already makes.
