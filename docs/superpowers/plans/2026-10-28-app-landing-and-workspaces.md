# Landing page and signed-in workspaces — implementation plan

Spec: `docs\superpowers\specs\2026-10-28-app-landing-and-workspaces-design.md`.

**Goal:** a sign-in landing page and a signed-in workspace with Home, Document
policies and Assess policies views. The change touches only the three packaged
web files, the Node test harnesses, workflows and documentation.

**Architecture:** all views stay in `web\index.html` and are toggled with
`.hidden`. A small router in `web\app.js` picks the view from sign-in state and
`location.hash`. Every existing element ID is kept exactly once, so the export,
assessment and sign-in handlers are unchanged.

**Constraints:**
- No server, `lib\*.ps1`, authentication or package allow-list changes.
- No new dependencies and no external assets.
- The fake DOMs in the existing harnesses support only `classList.add`/`remove`
  (plus `contains` in the assessment harness) and return a fixed
  `querySelectorAll` stub. New router code therefore uses explicit IDs and
  `add`/`remove` only.

## Task 1: Router, loading state and test harness (TDD)

Files: `tests\app-shell-ui.test.js` (new), `tests\publishing-ui.test.js`,
`tests\assessment-ui.test.js`, `web\app.js`.

1. Write `tests\app-shell-ui.test.js`. Its fake DOM supports class sets,
   attributes, `focus`, `open`, `window.location.hash`, `hashchange`
   listeners, `history.replaceState` and `scrollTo`. Tests:
   - signed out shows only `viewLanding` for `''`, `#/document` and `#/assess`,
     with the navigation and session controls hidden;
   - signed in shows Home by default, the Document or Assess view for their
     hashes, and Home for an unknown hash; `aria-current` follows the route;
   - `hashchange` re-renders the route and focuses the view heading;
   - sign-out and a 401 assessment response render the landing view, and the
     401 also shows the session-ended message;
   - activity indicators follow `exportBusy` and `assessmentBusy`;
   - the stepper follows configure → generate → review → configure;
   - the advanced sign-in disclosure opens for a non-default tenant;
   - a failed `/api/state` shows the retry message, and Retry recovers;
   - stripping `?signin=` keeps the hash;
   - static checks: every `$('id')` literal, and every ID requested during
     the flows above, exists exactly once in `index.html`; there are no
     duplicate IDs and no external resources.
2. Run it: `node --test .\tests\app-shell-ui.test.js`. Expect failures.
3. In `app.js`, implement `setHidden`, `routeView`, `renderRoute`, the
   `hashchange` listener, `setDocumentStep`, the activity indicators in
   `syncJobAdmission`, the session-ended message in
   `assessmentSessionFailure`, the disclosure auto-open in `renderAuth`, and
   `loadInitialState`/`start` with Retry. Change the `?signin=` strip to keep
   `location.hash`.
4. Add `window.addEventListener` and `setAttribute`/`removeAttribute` stubs to
   both existing harnesses, without changing any assertion.

## Task 2: Markup

File: `web\index.html`.

- A top bar with brand, `appNav` (with activity dots), `buildInfo`,
  `sessionControls` (`connBadge` and `btnSignout`) and `btnQuit`.
- Views: `viewLoading`, `viewLanding` (hero + sign-in card with the
  `advancedSignin` disclosure), `viewHome` (path cards + `connectedPane`),
  `viewDocument` (stepper + `cardConfigure`/`cardRun`/`cardResult`, Git
  publishing in `gitDetails`), and `viewAssess` (Baselines, Applicability
  context, Run and Results cards).
- Inline SVG icons only. Every existing ID moves, never duplicates.

## Task 3: Visual system

File: `web\style.css`. Add tokens, the top bar, landing hero and sign-in card,
path cards, page headers, stepper, disclosures, activity dots, focus rings,
reduced motion, the 900 px and 640 px breakpoints, and the stopped page. Keep
every class used by markup generated in `app.js`.

## Task 4: Workflows and documentation

- Add `.\tests\app-shell-ui.test.js` to the `node --test` lines in
  `.github\workflows\ci.yml`, `beta.yml` and `release.yml`, and list all three
  suites in `AGENTS.md`.
- Update the navigation wording in `README.md`, `QUICKSTART.md`,
  `docs\operations.md` and `docs\assessment-rule-packs.md`.

## Task 5: Verification

- Run a synthetic preview server from the session folder and check the views
  in the browser canvas at 1280 px and 390 px.
- Run all three Node suites.
- Run Pester, gating on the `-PassThru` counts.
- Run `pwsh -NoProfile -File .\scripts\Test-Repository.ps1`.
- Run `pwsh -NoProfile -File .\Build-Package.ps1` and expect 31 files.
