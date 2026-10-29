'use strict';

const $ = (id) => document.getElementById(id);
const escapeHtml = (value) => String(value == null ? '' : value)
  .replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;')
  .replace(/"/g, '&quot;').replace(/'/g, '&#39;');
const api = async (path, options) => {
  const res = await fetch(path, options);
  let body = null;
  try { body = await res.json(); } catch (e) { body = null; }
  return { ok: res.ok, status: res.status, body };
};
const post = (path, payload) => api(path, {
  method: 'POST',
  headers: { 'Content-Type': 'application/json' },
  body: JSON.stringify(payload || {})
});

let state = null;
let logCursor = 0;
let logTimer = null;
let deviceTimer = null;
let workspaceGeneration = 0;
let stateRequest = 0;
let exportBusy = false;
let exportStarting = false;
let booting = false;
let policyTimer = null;
let policyPolling = false;
let policyReloading = false;
let sourceImportOpen = false;
let sourceTransferBusy = false;
let folderPickerBusy = false;

const setHidden = (id, hidden) => {
  if (hidden) $(id).classList.add('hidden');
  else $(id).classList.remove('hidden');
};

// --- Navigation ------------------------------------------------------------

const views = { loading: 'viewLoading', landing: 'viewLanding', import: 'viewImport', policies: 'viewPolicies', home: 'viewHome', document: 'viewDocument', assess: 'viewAssess' };
const viewHeadings = { landing: 'landingTitle', import: 'policyImportTitle', policies: 'policyLoadTitle', home: 'homeTitle', document: 'documentTitle', assess: 'assessTitle' };
const navLinks = { home: 'navHome', document: 'navDocument', assess: 'navAssess' };
const routes = { '#/document': 'document', '#/assess': 'assess' };
let lastRoute = 'home';

// In-page anchors such as the skip link (#main) keep the current route.
const isRouteHash = (hash) => !hash || hash.startsWith('#/');
const policiesReady = () => !policyReloading && !sourceTransferBusy &&
  (!!state?.auth?.connected || state?.policies?.source?.kind === 'offline') &&
  ['ready', 'partial'].includes(state?.policies?.status);

function routeView() {
  if (!state) return 'loading';
  if (sourceImportOpen) return 'import';
  if (!state.auth?.connected && window.location.hash === '#/signin') return 'landing';
  if (!state.auth?.connected && state.policies?.source?.kind !== 'offline') return 'landing';
  if (state.policies?.status === 'loading' || state.policies?.consentRequired || state.policies?.status === 'failed') return 'policies';
  if (!policiesReady()) return 'home';
  const hash = window.location.hash || '';
  if (isRouteHash(hash)) lastRoute = routes[hash] || 'home';
  return lastRoute;
}

function renderRoute() {
  const view = routeView();
  const offlineSignedOut = !state?.auth?.connected && state?.policies?.source?.kind === 'offline';
  setHidden('offlineSignIn', !offlineSignedOut);
  setHidden('returnOfflineWorkspace', !offlineSignedOut);
  Object.entries(views).forEach(([key, id]) => setHidden(id, key !== view));
  const signedIn = !!navLinks[view];
  setHidden('appNav', !signedIn);
  setHidden('sessionControls', !state?.auth?.connected);
  Object.entries(navLinks).forEach(([key, id]) => {
    if (key === view) $(id).setAttribute('aria-current', 'page');
    else $(id).removeAttribute('aria-current');
  });
  return view;
}

window.addEventListener('hashchange', () => {
  const routed = isRouteHash(window.location.hash || '');
  const heading = viewHeadings[renderRoute()];
  if (!heading || !routed) return;
  window.scrollTo(0, 0);
  $(heading).focus({ preventScroll: true });
});

const documentSteps = { configure: 'stepConfigure', generate: 'stepGenerate', review: 'stepReview' };

function setDocumentStep(step) {
  const order = Object.keys(documentSteps);
  const current = order.indexOf(step);
  order.forEach((name, i) => {
    const el = $(documentSteps[name]);
    el.className = i < current ? 'done' : i === current ? 'active' : '';
    if (i === current) el.setAttribute('aria-current', 'step');
    else el.removeAttribute('aria-current');
  });
}

// --- Sign in ---------------------------------------------------------------

function showSigninError(message) {
  const el = $('signinError');
  if (!message) { el.classList.add('hidden'); return; }
  el.textContent = message;
  el.classList.remove('hidden');
}

function renderBuild(build) {
  if (!build) return;
  const name = 'Intune Docs Studio' + (build.channel === 'stable' ? '' : ' (' + build.channel + ')');
  $('appName').textContent = name;
  document.title = name;
  $('buildInfo').textContent = 'v' + build.version + ' ' + build.channel;
}

async function refreshState() {
  const generation = workspaceGeneration;
  const request = ++stateRequest;
  const { body } = await api('/api/state');
  if (!body || generation !== workspaceGeneration || request !== stateRequest) return;
  const awaitingPolicies = !!state && !policiesReady();
  const identity = (s) => JSON.stringify(s?.auth || {}, ['connected', 'tenantId', 'account', 'client', 'method']);
  if (state && identity(state) !== identity(body)) clearWorkspace();
  const sourceKey = (s) => JSON.stringify([s?.policies?.source, s?.policies?.capturedAt]);
  if (state && sourceKey(state) !== sourceKey(body) && policiesReady()) clearWorkspace();
  state = body;
  if (body.transfer?.running && !sourceTransferBusy) {
    const operation = body.transfer.operation;
    if (operation === 'import') sourceImportOpen = true;
    const statusId = operation === 'import' ? 'policyImportStatus' : 'policyExportStatus';
    void transferPolicySource(operation, null, statusId, true).catch((e) => { $(statusId).textContent = e.message; });
  }
  const policiesArrived = awaitingPolicies && policiesReady();
  if (policiesArrived) {
    lastRoute = 'home';
    window.location.hash = '#/';
  }
  if (body.export) exportBusy = exportStarting || !!body.export.running;
  renderBuild(body.build);
  renderAuth();
  renderPolicyState();
  syncJobAdmission();
  if (policiesArrived) $('homeTitle').focus({ preventScroll: true });
}

function renderPolicyState() {
  const policies = state?.policies || {};
  const waiting = policies.status === 'loading';
  const consent = !!policies.consentRequired;
  const failed = policies.status === 'failed';
  const percent = Math.max(0, Math.min(100, Number(policies.percent) || 0));
  $('policyLoadBar').style.width = percent + '%';
  $('policyLoadProgress').setAttribute('aria-valuenow', percent);
  $('policyLoadPhase').textContent = policies.phase || 'No collection has started';
  $('policyLoadTitle').textContent = consent && !waiting ? 'Load policies now?' : 'Loading your Intune policies';
  setHidden('policyConsentActions', !consent && !failed);
  setHidden('policyLoadProgress', !waiting);
  $('policyLoadTenant').textContent = state?.auth?.tenantId ? 'Tenant ' + state.auth.tenantId : '';
  $('policyLoadError').textContent = policies.error || '';
  setHidden('policyLoadError', !policies.error);
  setHidden('policyLoadSpinner', !waiting);
  setHidden('btnRetryPolicies', !failed);
  const offline = policies.source?.kind === 'offline';
  const ready = ['ready', 'partial'].includes(policies.status);
  $('policySummary').textContent = ready ? `${Number(policies.count) || 0} policies · ${offline ? 'Offline import' : 'Live snapshot'}` +
    ` · Collected: ${policies.capturedAt || 'Unknown'}` +
    (policies.source?.importedAt ? ` · Imported: ${policies.source.importedAt}` : '') : 'No policies loaded yet';
  $('policySourceDescription').textContent = offline
    ? 'Both workflows use this offline source. No Graph or authentication calls are made. Only the five policy families are available; missing evidence and reference names remain explicit.'
    : ready ? 'Both workflows use this snapshot. Refresh explicitly to read changes from Intune. Other documentation categories are collected during export.'
      : 'You can stay signed in without loading data. Load live policies or import an existing source to enable documentation and Assessment.';
  $('btnRefreshPolicies').textContent = offline ? 'Replace with live policies' : ready ? 'Refresh live policies' : 'Load live policies';
  ['homeDocument', 'homeAssess', 'navDocument', 'navAssess'].forEach((id) => {
    $(id).setAttribute('aria-disabled', ready ? 'false' : 'true');
  });
  $('policyFamilies').innerHTML = (policies.families || []).map((family) =>
    `<div class="stat"><b>${Number(family.count) || 0}</b><span>${escapeHtml(family.label)}</span>` +
    (family.complete ? '' : '<p class="muted">Incomplete evidence</p>') + '</div>').join('');
  const partial = policies.status === 'partial';
  setHidden('policyLimitations', !partial);
  $('policyLimitations').textContent = partial ?
    'Some policies could not be fully read. Assessment keeps incomplete evidence explicit; documentation skips incomplete policy families and preserves previous files. ' +
      (policies.issues || []).map((issue) =>
        `${issue.family}: ${issue.stage} — ${issue.reason}${issue.statusCode ? ` (HTTP ${issue.statusCode})` : ''}`).join('\n') : '';
  if (waiting && !failed && !policyTimer) policyTimer = setInterval(pollPolicyState, 1000);
  if (!waiting || failed) { clearInterval(policyTimer); policyTimer = null; }
}

async function pollPolicyState() {
  if (policyPolling || !state?.auth?.connected) return;
  const generation = workspaceGeneration;
  policyPolling = true;
  try { await refreshState(); }
  catch (e) {
    if (generation === workspaceGeneration) {
      $('policyLoadError').textContent = 'Policy progress is unavailable. Checking the local server again…';
      setHidden('policyLoadError', false);
    }
  } finally { if (generation === workspaceGeneration) policyPolling = false; }
}

async function reloadPolicies() {
  if (policyReloading || exportBusy || assessmentBusy || !state?.auth?.connected) return;
  const replace = ['ready', 'partial'].includes(state?.policies?.status);
  if (replace && !confirm('Replace the active policy source with a new live collection? Assessment results will be cleared.')) return;
  const generation = workspaceGeneration;
  policyReloading = true;
  syncJobAdmission();
  try {
    const r = await post('/api/policies/reload', { replace });
    if (generation !== workspaceGeneration) return;
    if (assessmentSessionFailure(r)) return;
    if (!r.ok) throw new Error(r.body?.error || 'Could not reload policies.');
    state.policies = { status: 'loading', percent: 0 };
    clearAssessment();
    $('policyRefreshError').textContent = '';
    setHidden('policyRefreshError', true);
  } catch (e) {
    if (generation !== workspaceGeneration) return;
    ['policyLoadError', 'policyRefreshError'].forEach((id) => {
      $(id).textContent = e.message; setHidden(id, false);
    });
  } finally {
    if (generation === workspaceGeneration) { policyReloading = false; syncJobAdmission(); }
  }
  if (generation === workspaceGeneration) {
    renderRoute();
    renderPolicyState();
    await pollPolicyState();
  }
}

$('btnRetryPolicies').addEventListener('click', reloadPolicies);
$('btnRefreshPolicies').addEventListener('click', reloadPolicies);
$('btnLoadPolicies').addEventListener('click', reloadPolicies);
$('btnPoliciesNotNow').addEventListener('click', async () => {
  const r = await post('/api/policies/decline');
  if (!r.ok) { $('policyLoadError').textContent = r.body?.error || 'Could not save your choice.'; setHidden('policyLoadError', false); return; }
  await refreshState();
  $('homeTitle').focus({ preventScroll: true });
});

const waitForLocalJob = () => new Promise((resolve) => setTimeout(resolve, 300));

async function chooseHostFolder(inputId, statusId) {
  if (folderPickerBusy) throw new Error('A folder dialog is already open on the application host.');
  folderPickerBusy = true;
  $(statusId).textContent = 'Choose a folder in the Windows dialog on the application host. Cancel keeps the current path.';
  try {
    const started = await post('/api/folders/picker', { initialPath: $(inputId).value });
    if (!started.ok) throw new Error(started.body?.error || 'Could not open folder selection.');
    while (true) {
      const r = await api('/api/folders/picker');
      if (!r.ok) throw new Error(r.body?.error || 'Folder selection is unavailable.');
      if (r.body?.status === 'selected') {
        $(inputId).value = r.body.path;
        $(statusId).textContent = 'Host folder selected.';
        return r.body.path;
      }
      if (r.body?.status === 'cancelled') { $(statusId).textContent = 'Folder selection cancelled; current path unchanged.'; return null; }
      if (r.body?.status !== 'running') throw new Error(r.body?.error || 'Folder selection ended unexpectedly. Enter the host path manually.');
      await waitForLocalJob();
    }
  } finally { folderPickerBusy = false; }
}

function openPolicyImport() {
  if (exportBusy || assessmentBusy || sourceTransferBusy || assessmentImporting) return;
  sourceImportOpen = true;
  renderRoute();
  $('policyImportTitle').focus({ preventScroll: true });
}
$('btnOpenPolicyImport').addEventListener('click', openPolicyImport);
$('btnReplacePolicySource').addEventListener('click', openPolicyImport);
$('btnCancelPolicyImport').addEventListener('click', () => {
  if (sourceTransferBusy) return;
  sourceImportOpen = false; renderRoute();
  $(state?.auth?.connected || policiesReady() ? 'homeTitle' : 'landingTitle').focus({ preventScroll: true });
});
for (const [button, input, status] of [
  ['btnBrowsePolicyImport', 'policyImportPath', 'policyImportStatus'],
  ['btnBrowsePolicyExport', 'policyExportPath', 'policyExportStatus'],
  ['btnBrowseAssessmentReports', 'assessmentOutputPath', 'assessmentFolderStatus']
]) {
  $(button).addEventListener('click', async () => {
    try { await chooseHostFolder(input, status); }
    catch (e) { $(status).textContent = e.message; }
  });
}

async function transferPolicySource(operation, payload, statusId, resume = false) {
  if (sourceTransferBusy || exportBusy || assessmentBusy || assessmentImporting) return;
  sourceTransferBusy = true;
  syncJobAdmission();
  $(statusId).textContent = operation === 'import' ? 'Reading and validating policy files…' : 'Writing policy JSON files…';
  try {
    if (!resume) {
      const started = await post(`/api/policies/${operation}`, payload);
      if (!started.ok) throw new Error(started.body?.error || 'Could not start policy transfer.');
    }
    while (true) {
      const r = await api('/api/policies/transfer');
      if (!r.ok || r.body?.status === 'failed') throw new Error(r.body?.error || 'Policy transfer failed.');
      $(statusId).textContent = r.body?.phase || 'Working…';
      if (r.body?.status === 'completed') {
        $(statusId).textContent = operation === 'export' ? `Policy set written to ${r.body.result?.path}` : 'Policy set imported.';
        if (operation === 'import') {
          sourceImportOpen = false;
          clearWorkspace();
          lastRoute = 'home'; window.location.hash = '#/';
        }
        break;
      }
      if (!r.body?.running) throw new Error('Policy transfer ended without a completed result.');
      await waitForLocalJob();
    }
  } finally {
    sourceTransferBusy = false; syncJobAdmission(); await refreshState();
  }
}
$('btnImportPolicySource').addEventListener('click', async () => {
  try {
    const replace = ['ready', 'partial'].includes(state?.policies?.status);
    if (replace && !confirm('Replace the active policy source? Existing Assessment results will be cleared; saved report files remain unchanged.')) return;
    const file = $('policyImportZip').files[0];
    let payload;
    if (file) {
      if (!file.size || file.size > 32 * 1024 * 1024 || !/\.zip$/i.test(file.name)) throw new Error('Choose a nonempty policy ZIP, at most 32 MiB.');
      payload = { archive: assessmentArchiveBase64(await file.arrayBuffer()), replace };
    } else {
      const path = $('policyImportPath').value.trim();
      if (!path) throw new Error('Choose a policy ZIP or enter a host folder path.');
      payload = { path, replace };
    }
    setHidden('policyImportError', true);
    await transferPolicySource('import', payload, 'policyImportStatus');
  } catch (e) { $('policyImportError').textContent = e.message; setHidden('policyImportError', false); }
});
$('btnExportPolicySource').addEventListener('click', async () => {
  try {
    if (!policiesReady()) throw new Error('Load or import policies before exporting a policy set.');
    await transferPolicySource('export', { path: $('policyExportPath').value.trim() }, 'policyExportStatus');
  } catch (e) { $('policyExportStatus').textContent = e.message; }
});

function renderClients() {
  const sel = $('client');
  if (sel.options.length || !state.clients) return;
  state.clients.forEach((c) => {
    const opt = document.createElement('option');
    opt.value = c.key;
    opt.textContent = c.name;
    opt.dataset.note = c.note || '';
    sel.appendChild(opt);
  });
  const setNote = () => { $('clientNote').textContent = sel.selectedOptions[0].dataset.note; };
  sel.addEventListener('change', setNote);
  setNote();
}

function renderSections() {
  const host = $('sections');
  if (!state.sections) return;
  if (host.children.length) {
    sectionBoxes().forEach((box) => {
      box.disabled = state.sections.find((s) => s.key === box.value)?.available === false;
      if (box.disabled) box.checked = false;
    });
    return;
  }
  state.sections.forEach((s) => {
    const label = document.createElement('label');
    label.className = 'check';
    label.innerHTML = `<input type="checkbox" value="${escapeHtml(s.key)}" ${s.available === false ? 'disabled' : 'checked'}><span>${escapeHtml(s.label)}${s.available === false ? ' (unavailable offline)' : ''}</span>`;
    host.appendChild(label);
  });
}

function renderAuth() {
  renderClients();
  renderSections();
  if (!$('outputPath').value && state.outputPath) $('outputPath').value = state.outputPath;
  if (state.tenant && $('tenant').value === 'organizations') $('tenant').value = state.tenant;
  const tenant = $('tenant').value.trim();
  if (tenant && tenant !== 'organizations') $('advancedSignin').open = true;
  if ($('gitRemoteUrl').value.trim()) $('gitDetails').open = true;

  const auth = state.auth || {};
  const badge = $('connBadge');

  if (auth.connected) {
    badge.textContent = auth.account || 'Connected';
    badge.className = 'badge badge-on';
    $('homeGreeting').textContent = 'Welcome' + (auth.account ? ', ' + auth.account : '');
    $('homeTenant').textContent = auth.tenantId ? 'Tenant ' + auth.tenantId : '';
    $('signinPane').classList.add('hidden');
    $('connectedPane').classList.remove('hidden');
    $('cardConfigure').classList.remove('disabled');
    $('cAccount').textContent = auth.account || '—';
    $('cTenant').textContent = auth.tenantId || '—';
    $('cClient').textContent = auth.client || '—';
    $('cMethod').textContent = auth.method || '—';
    if (policiesReady()) checkFolder();

    const host = $('scopeList');
    host.innerHTML = '';
    (auth.scopes || []).forEach((s) => {
      const div = document.createElement('div');
      div.className = 'scope';
      div.innerHTML = `<span class="dot ${s.granted ? 'on' : 'off'}"></span>
        <span><code>${s.scope}</code></span>
        <span class="impact">${s.granted ? s.impact : 'missing — ' + s.impact + ' may be incomplete'}</span>`;
      host.appendChild(div);
    });
  } else {
    badge.textContent = 'Not connected';
    badge.className = 'badge badge-off';
    $('signinPane').classList.remove('hidden');
    $('connectedPane').classList.add('hidden');
    if (policiesReady()) $('cardConfigure').classList.remove('disabled');
    else $('cardConfigure').classList.add('disabled');
  }
  if (state.policies?.source?.kind === 'offline') {
    $('homeGreeting').textContent = 'Offline policy workspace';
    $('homeTenant').textContent = state.policies.tenant?.name || 'Environment name unavailable';
  } else if (!policiesReady()) {
    $('homeGreeting').textContent = 'Welcome';
  }
  if (state.pendingError) showSigninError(state.pendingError);
  renderRoute();
}

$('btnBrowser').addEventListener('click', async () => {
  clearAssessment();
  showSigninError(null);
  const btn = $('btnBrowser');
  btn.disabled = true;
  $('browserStatus').classList.remove('hidden');
  $('bsText').textContent = 'Starting browser…';

  await post('/api/signin/browser', {
    tenant: $('tenant').value.trim(),
    forcePicker: $('optForcePicker').checked
  });

  const timer = setInterval(async () => {
    const r = await api('/api/signin/browser/status');
    if (!r.body) return;
    if (r.body.status) $('bsText').textContent = r.body.status;
    if (r.body.error) {
      clearInterval(timer);
      btn.disabled = false;
      $('browserStatus').classList.add('hidden');
      showSigninError(r.body.error);
      return;
    }
    if (!r.body.running && r.body.done) {
      clearInterval(timer);
      btn.disabled = false;
      $('browserStatus').classList.add('hidden');
      await refreshState();
    }
  }, 1200);
});

$('btnForget').addEventListener('click', async () => {
  clearAssessment();
  await post('/api/signin/browser/forget');
  await refreshState();
  $('bsText').textContent = 'Saved browser session cleared.';
  $('browserStatus').classList.remove('hidden');
  setTimeout(() => $('browserStatus').classList.add('hidden'), 2500);
});

$('btnInteractive').addEventListener('click', async () => {
  clearAssessment();
  showSigninError(null);
  const { body } = await post('/api/signin/interactive', {
    tenant: $('tenant').value.trim() || 'organizations',
    client: $('client').value
  });
  if (body && body.url) { window.location.href = body.url; }
  else { showSigninError('Could not start sign-in.'); }
});

$('btnDeviceCode').addEventListener('click', async () => {
  clearAssessment();
  showSigninError(null);
  const { body } = await post('/api/signin/devicecode', {
    tenant: $('tenant').value.trim() || 'organizations',
    client: $('client').value
  });
  if (!body || body.error) { showSigninError(body ? body.error : 'Device code request failed.'); return; }

  $('dcUri').textContent = body.verificationUri;
  $('dcUri').href = body.verificationUri;
  $('dcCode').textContent = body.userCode;
  $('deviceCodePane').classList.remove('hidden');

  clearInterval(deviceTimer);
  deviceTimer = setInterval(async () => {
    const r = await api('/api/signin/devicecode/poll');
    if (!r.body) return;
    if (r.body.status === 'ok') {
      clearInterval(deviceTimer);
      $('deviceCodePane').classList.add('hidden');
      await refreshState();
    } else if (['declined', 'expired', 'error'].includes(r.body.status)) {
      clearInterval(deviceTimer);
      $('deviceCodePane').classList.add('hidden');
      showSigninError(r.body.message || ('Sign-in ' + r.body.status));
    }
  }, 3000);
});

$('btnAzureCli').addEventListener('click', async () => {
  clearAssessment();
  showSigninError(null);
  const { body } = await post('/api/signin/azurecli');
  if (body && body.error) { showSigninError(body.error); return; }
  await refreshState();
});

$('btnMgGraph').addEventListener('click', async () => {
  clearAssessment();
  showSigninError(null);
  $('btnMgGraph').disabled = true;
  $('btnMgGraph').textContent = 'Check the sign-in window…';
  const { body } = await post('/api/signin/mggraph', { tenant: $('tenant').value.trim() });
  $('btnMgGraph').disabled = false;
  $('btnMgGraph').textContent = 'Use Graph PowerShell session';
  if (body && body.error) { showSigninError(body.error); return; }
  await refreshState();
});

function clearWorkspace() {
  // Everything below belongs to the previous sign-in and must not survive it.
  workspaceGeneration++;
  clearInterval(policyTimer);
  policyTimer = null;
  policyPolling = false;
  policyReloading = false;
  ['policySummary', 'policyFamilies', 'policyLimitations', 'policyRefreshError', 'policyLoadError', 'policyLoadTenant'].forEach((id) => {
    $(id).textContent = '';
  });
  $('policyFamilies').innerHTML = '';
  setHidden('policyRefreshError', true);
  exportBusy = false;
  exportStarting = false;
  clearAssessment();
  clearInterval(logTimer);
  logCursor = 0;
  $('log').textContent = '';
  $('summary').innerHTML = '';
  $('fileList').innerHTML = '';
  $('preview').textContent = 'Select a file to preview.';
  $('bar').style.width = '0%';
  $('phase').textContent = '';
  $('pct').textContent = '';
  $('cardRun').classList.add('hidden');
  $('cardResult').classList.add('hidden');
  $('folderWarn').classList.add('hidden');
  $('deviceCodePane').classList.add('hidden');
  $('gitRemoteUrl').value = '';
  $('gitBranch').value = '';
  $('optPush').checked = false;
  $('optGit').checked = false;
  showSigninError(null);
  sectionBoxes().forEach((b) => { b.checked = true; });
  setDocumentStep('configure');
}

$('btnSignout').addEventListener('click', async () => {
  if (state) state.auth = { connected: false };
  clearWorkspace();
  if (state) renderAuth();
  const { body } = await post('/api/signout');
  if (body && body.error) { await refreshState(); alert(body.error); return; }
  clearWorkspace();
  if (body && body.outputPath) $('outputPath').value = body.outputPath;
  if (body && body.tenant) $('tenant').value = body.tenant;
  await refreshState();
});

// --- Configure -------------------------------------------------------------

async function checkFolder() {
  const generation = workspaceGeneration;
  const path = $('outputPath').value.trim();
  if (!path || !policiesReady()) return;
  const { body } = await api('/api/checkfolder?path=' + encodeURIComponent(path));
  if (generation !== workspaceGeneration || path !== $('outputPath').value.trim()) return;
  const el = $('folderWarn');
  if (body && body.conflict) {
    el.innerHTML = body.conflict +
      (body.suggestion ? ` <button class="linkbtn" id="btnUseSuggestion">use ${body.suggestion}</button>` : '');
    el.classList.remove('hidden');
    const b = $('btnUseSuggestion');
    if (b) b.addEventListener('click', () => {
      if (generation !== workspaceGeneration || path !== $('outputPath').value.trim()) return;
      $('outputPath').value = body.suggestion;
      el.classList.add('hidden');
    });
  } else {
    el.classList.add('hidden');
  }
}

$('outputPath').addEventListener('change', checkFolder);
$('tenant').addEventListener('change', clearAssessment);
$('gitRemoteUrl').addEventListener('change', () => {
  if ($('gitRemoteUrl').value.trim()) {
    $('optPush').checked = true;
    $('optGit').checked = true;
  }
});
const syncGitOptions = () => {
  if ($('optPush').checked) $('optGit').checked = true;
};
$('optPush').addEventListener('change', syncGitOptions);
$('optGit').addEventListener('change', syncGitOptions);

const sectionBoxes = () => Array.from(document.querySelectorAll('#sections input'));
$('btnAll').addEventListener('click', () => sectionBoxes().forEach((b) => { b.checked = true; }));
$('btnNone').addEventListener('click', () => sectionBoxes().forEach((b) => { b.checked = false; }));

$('btnExport').addEventListener('click', async () => {
  if (!policiesReady()) { alert('Load policies before documenting.'); return; }
  if (assessmentBusy || exportBusy) { alert('An export or assessment is already running.'); return; }
  const sections = sectionBoxes().filter((b) => b.checked).map((b) => b.value);
  if (!sections.length) { alert('Select at least one area to document.'); return; }

  const payload = {
    outputPath: $('outputPath').value.trim(),
    sections,
    includeRaw: $('optRaw').checked,
    includeScriptContent: $('optScripts').checked,
    frontMatter: $('optFrontMatter').checked,
    adoWikiOrder: $('optAdo').checked,
    gitCommit: $('optGit').checked || $('optPush').checked,
    gitPush: $('optPush').checked,
    gitRemoteUrl: $('gitRemoteUrl').value.trim(),
    gitBranch: $('gitBranch').value.trim()
  };

  const generation = workspaceGeneration;
  exportBusy = true;
  exportStarting = true;
  syncJobAdmission();
  let response;
  try { response = await post('/api/export', payload); }
  catch (e) {
    if (generation === workspaceGeneration) {
      exportStarting = false; exportBusy = false; syncJobAdmission(); alert(e.message);
    }
    return;
  }
  if (generation !== workspaceGeneration) return;
  exportStarting = false;
  const { body } = response;
  if (!response.ok || (body && body.error)) {
    exportBusy = false;
    syncJobAdmission();
    alert(body?.error || 'Export request failed.');
    return;
  }

  logCursor = 0;
  $('log').textContent = '';
  $('cardRun').classList.remove('hidden');
  $('cardResult').classList.add('hidden');
  $('cardConfigure').classList.add('disabled');
  setDocumentStep('generate');
  $('cardRun').scrollIntoView({ behavior: 'smooth' });
  startLogPolling();
});

// --- Progress --------------------------------------------------------------

function startLogPolling() {
  clearInterval(logTimer);
  logTimer = setInterval(pollLog, 800);
  pollLog();
}

async function pollLog() {
  const generation = workspaceGeneration;
  const { body } = await api('/api/export/log?from=' + logCursor);
  if (!body || generation !== workspaceGeneration) return;

  (body.entries || []).forEach((e) => {
    const span = document.createElement('span');
    if (e.level && e.level !== 'info') span.className = e.level;
    span.textContent = `[${e.time}] ${e.message}\n`;
    $('log').appendChild(span);
  });
  if (body.entries && body.entries.length) {
    logCursor = body.total;
    $('log').scrollTop = $('log').scrollHeight;
  }

  $('bar').style.width = (body.percent || 0) + '%';
  $('phase').textContent = body.phase || '';
  $('pct').textContent = body.percent ? `· ${body.percent}%` : '';

  if (body.done) {
    clearInterval(logTimer);
    exportBusy = false;
    syncJobAdmission();
    $('cardConfigure').classList.remove('disabled');
    setDocumentStep('review');
    if (body.error) {
      $('phase').textContent = 'Failed';
      $('summary').innerHTML = `<div class="error">${escapeHtml(body.error)}</div>`;
      $('cardResult').classList.remove('hidden');
    } else if (body.summary) {
      renderSummary(body.summary);
      loadFiles();
      $('cardResult').classList.remove('hidden');
      $('cardResult').scrollIntoView({ behavior: 'smooth' });
    }
  }
}

// --- Results ---------------------------------------------------------------

function renderSummary(s) {
  const st = s.stats || {};
  const counts = s.counts || {};
  let html = `<div class="stats">
    <div class="stat"><b>${st.created || 0}</b><span>created</span></div>
    <div class="stat"><b>${st.updated || 0}</b><span>updated</span></div>
    <div class="stat"><b>${st.unchanged || 0}</b><span>unchanged</span></div>
    <div class="stat"><b>${st.deleted || 0}</b><span>removed</span></div>
  </div>`;

  html += `<p class="muted">Output: <code>${escapeHtml(s.root)}</code></p>`;

  html += '<table class="counts">';
  Object.keys(counts).forEach((k) => {
    html += `<tr><td>${escapeHtml(k)}</td><td>${escapeHtml(counts[k])}</td></tr>`;
  });
  html += '</table>';

  if (s.git) {
    html += s.git.committed
      ? `<p class="muted">Committed: <code>${escapeHtml(s.git.message)}</code></p>`
      : '<p class="muted">No configuration changes since the last export &mdash; nothing committed.</p>';
    if (s.git.pushed) html += '<p class="muted">Successfully pushed to remote.</p>';
  }
  if (s.warnings && s.warnings.length) {
    html += '<h4 class="section-label">Warnings</h4><ul class="muted">' + s.warnings.map((w) => `<li>${escapeHtml(w)}</li>`).join('') + '</ul>';
  }
  $('summary').innerHTML = html;
}

async function loadFiles() {
  const generation = workspaceGeneration;
  const { body } = await api('/api/files');
  if (generation !== workspaceGeneration) return;
  const host = $('fileList');
  host.innerHTML = '';
  if (!body || !body.files) return;
  body.files.forEach((f) => {
    const btn = document.createElement('button');
    btn.textContent = f.path;
    btn.addEventListener('click', async () => {
      Array.from(host.children).forEach((c) => c.classList.remove('active'));
      btn.classList.add('active');
      const r = await api('/api/file?path=' + encodeURIComponent(f.path));
      if (generation !== workspaceGeneration) return;
      $('preview').textContent = r.body && r.body.content ? r.body.content : '(unable to read file)';
      $('preview').scrollTop = 0;
    });
    host.appendChild(btn);
  });
}

$('btnOpen').addEventListener('click', () => post('/api/open'));

$('btnQuit').addEventListener('click', async () => {
  if (exportBusy || assessmentBusy) {
    alert('An export or assessment is still running. Wait for it to finish before stopping the server.');
    return;
  }
  if (!confirm('Stop the Intune Docs Studio server?')) return;
  try {
    const r = await post('/api/quit');
    if (!r.ok || r.body?.error) { alert(r.body?.error || 'The server could not stop.'); return; }
  } catch (e) { /* the server goes away mid-request */ }
  clearInterval(logTimer);
  clearInterval(deviceTimer);
  clearAssessment();
  document.body.innerHTML =
    '<main class="stopped"><span class="mark" aria-hidden="true"></span>' +
    '<h2>Intune Docs Studio has stopped.</h2>' +
    '<p>You can close this tab. Run <code>Start-IntuneDocs.cmd</code> to start it again.</p></main>';
});
$('btnAgain').addEventListener('click', () => {
  $('cardResult').classList.add('hidden');
  $('cardRun').classList.add('hidden');
  setDocumentStep('configure');
  $('cardConfigure').scrollIntoView({ behavior: 'smooth' });
});

// --- Assessment ------------------------------------------------------------

const assessmentStatuses = {
  aligned: 'Aligned', misaligned: 'Misaligned', missing: 'Missing',
  potentialConflict: 'Potential conflict', notApplicable: 'Not applicable', notAssessed: 'Not assessed'
};
const assessmentLimits = 'Configuration alignment only, not device compliance or certification. ' +
  'Missing means absent/not configured only in the mapped families and policy types read completely for that rule, not tenant-wide absence. ' +
  'Potential conflict means differing configured values, not proven targeting overlap or an Intune conflict. ' +
  'Unassigned policies do not establish device coverage; groups, exclusions and filters are not resolved. ' +
  'Partial inventories cover listed checks only, not a full baseline or benchmark. ' +
  'User-selected context is not discovered device inventory. Unknown applicability remains not assessed.';
let assessmentResult = null;
let assessmentPacks = [];
let assessmentGeneration = 0;
let assessmentImporting = false;
let assessmentImportQueue = [];
let assessmentQueueSequence = 0;
let assessmentBusy = false;
let assessmentStarting = false;
let assessmentTimer = null;
let assessmentPolling = false;
let assessmentCatalogRequest = 0;
let assessmentCatalogIssues = [];
const assessmentPlatforms = {
  windows11: 'Windows 11', macos: 'macOS', iosIpados: 'iOS/iPadOS', androidEnterprise: 'Android Enterprise'
};
const assessmentPackBoxes = () => Array.from(document.querySelectorAll('#assessmentPacks input'));
const assessmentPlatformBoxes = () => Array.from(document.querySelectorAll('#assessmentPlatforms input'));
const assessmentIdentity = (p) => `${p.id}@${p.version}#${p.sha256}`;
const assessmentText = (value) => escapeHtml(typeof value === 'string' ? value : JSON.stringify(value));
const assessmentPercent = (value) => value == null ? 'not available' : escapeHtml(value) + '%';

function renderAssessmentPacks(catalog) {
  const selected = new Set(assessmentPackBoxes().filter((b) => b.checked).map((b) => b.value));
  const platforms = new Set(assessmentPlatformBoxes().filter((b) => b.checked).map((b) => b.value));
  assessmentPacks = catalog.packs || [];
  assessmentCatalogIssues = catalog.errors || [];
  $('assessmentCatalogNote').textContent =
    'CIS content is never bundled or downloaded. Import your own licensed CIS Intune build-kit ZIP or a ' +
    'schema-1 JSON rule pack below; PDF and Excel benchmarks are not supported. ' +
    'Choose platforms first; unavailable pack combinations cannot run until a suitable pack is imported. ' +
    'The Microsoft catalog contains five bundled checks total, all partial inventories: ' +
    'Windows 26H2 has two shell SmartScreen atomic checks, legacy Endpoint Protection only (Graph beta), not modern baseline/Settings Catalog coverage. ' +
    'macOS has one FileVault enablement check, legacy Endpoint Protection on Graph beta; the template is deprecated, not current-template, recovery-key or encryption compliance coverage. ' +
    'iOS/iPadOS has one personal level 1 passcode check, legacy device restrictions only, not organization-owned coverage. ' +
    'Android has one personally-owned work profile level 2 encryption compliance requirement check, not organization-owned profiles or discovered device encryption. ' +
    'Unknown OS/enrollment applicability is not assessed; no full-baseline or device-compliance claim.';
  $('assessmentCatalogErrors').textContent = assessmentCatalogIssues.map((e) => `${e.origin}: ${e.reason}`).join('\n');
  $('assessmentPlatforms').innerHTML = '';
  Object.entries(assessmentPlatforms).forEach(([key, name]) => {
    const available = assessmentPacks.some((p) => p.platform === key);
    const label = document.createElement('label');
    label.className = 'check';
    const box = document.createElement('input');
    box.type = 'checkbox';
    box.value = key;
    box.disabled = false;
    box.checked = platforms.has(key);
    box.addEventListener('change', updateAssessmentSelection);
    const text = document.createElement('span');
    text.textContent = name + (available ? '' : ' — no library packs yet; import after Next');
    label.appendChild(box);
    label.appendChild(text);
    $('assessmentPlatforms').appendChild(label);
  });
  const profile = $('assessmentProfile');
  const previous = profile.value;
  const profiles = assessmentPacks.map((p) => assessmentIdentity(p));
  profile.innerHTML = '';
  ['', ...profiles].forEach((value) => {
    const option = document.createElement('option');
    option.value = value;
    const pack = assessmentPacks.find((p) => assessmentIdentity(p) === value);
    option.textContent = pack
      ? `${pack.profile} — ${pack.framework} / ${pack.frameworkVersion || pack.id} (${pack.id}) · ${pack.origin === 'imported' ? 'Imported' : 'Bundled'} · ${pack.version}`
      : 'All available profiles (select packs below)';
    profile.appendChild(option);
  });
  profile.value = profiles.includes(previous) ? previous : '';
  $('assessmentPacks').innerHTML = '';
  assessmentPacks.forEach((p) => {
    const label = document.createElement('div');
    label.className = 'check assessment-pack';
    const box = document.createElement('input');
    box.type = 'checkbox';
    box.value = assessmentIdentity(p);
    box.setAttribute('aria-label', `Select ${p.framework} ${p.profile}, ${p.id} version ${p.version}`);
    box.checked = selected.has(box.value);
    box.addEventListener('change', updateAssessmentSelection);
    const text = document.createElement('span');
    const classification = p.origin === 'imported'
      ? `${p.framework} — customer-imported local pack; author-declared ${p.classification}`
      : p.origin !== 'bundled' ? `${p.framework} — unverified origin; author-declared ${p.classification}`
      : p.framework === 'Microsoft' ? (p.classification === 'baseline'
        ? 'Official Microsoft security baseline — partial mapped checks' : 'Microsoft recommendations')
        : `${p.framework} — local rule pack`;
    text.innerHTML = `<strong>${escapeHtml(p.framework)} · ${escapeHtml(p.profile)}</strong>
      <small>${escapeHtml(assessmentPlatforms[p.platform])} · ${escapeHtml(p.frameworkVersion)} · Version ${escapeHtml(p.version)}</small>
      <span class="badge">${p.origin === 'imported' ? 'Imported' : 'Bundled'}</span>
      <small>${escapeHtml(classification)}</small>
      <small>${escapeHtml(p.coverage?.inventory)} inventory · source total ${escapeHtml(p.coverage?.totalSourceControls ?? 'unknown')}</small>
      <details class="pack-technical"><summary>Identity and source details</summary>
        <p>${escapeHtml(p.id)}</p><p>${escapeHtml(p.sourceRevision)}</p>
        <pre>${assessmentText(p.sources || [])}</pre><p>SHA-256: ${escapeHtml(p.sha256)}</p></details>`;
    label.appendChild(box);
    label.appendChild(text);
    if (p.origin === 'imported') {
      const remove = document.createElement('button');
      remove.className = 'btn ghost small pack-remove';
      remove.innerHTML = '<svg class="icon" viewBox="0 0 24 24" aria-hidden="true"><path d="M3 6h18M9 6V3h6v3M5 6l1 15h12l1-15M10 10v7M14 10v7"/></svg>';
      remove.setAttribute('aria-label', `Remove imported pack ${p.id} from the local library`);
      remove.addEventListener('click', () => removeAssessmentPack(p));
      label.appendChild(remove);
    }
    $('assessmentPacks').appendChild(label);
  });
  updateAssessmentSelection();
}

function updateAssessmentSelection() {
  const platforms = assessmentPlatformBoxes().filter((b) => b.checked).map((b) => b.value);
  const profile = $('assessmentProfile').value;
  let enabled = 0;
  // Row i is pack i; the empty state sits outside #assessmentPacks to keep that mapping.
  Array.from($('assessmentPacks').children).forEach((label, i) => {
    const box = label.children[0];
    const pack = assessmentPacks[i];
    box.disabled = !platforms.includes(pack.platform);
    if (box.disabled || (!!profile && profile !== assessmentIdentity(pack))) {
      if (box.disabled) box.checked = false;
      label.classList.add('hidden');
    } else {
      enabled++;
      label.classList.remove('hidden');
    }
  });
  $('assessmentPacksEmpty').textContent = enabled ? '' : 'No rule pack matches the selected platforms and profile. ' +
    'Choose other platforms or a different profile, or import a pack below.';
  setHidden('assessmentPacksEmpty', enabled > 0);
  syncJobAdmission();
}

$('assessmentProfile').addEventListener('change', updateAssessmentSelection);

// Wizard steps are client state, not routes, so the current step survives navigating Home and back.
const assessmentSteps = {
  platforms: ['assessStepPlatforms', 'assessPanelPlatforms', 'platformsTitle'],
  import: ['assessStepImport', 'assessImportPanel', 'assessImportTitle'],
  baselines: ['assessStepBaselines', 'assessPanelBaselines', 'baselinesTitle'],
  context: ['assessStepContext', 'assessPanelContext', 'contextTitle'],
  review: ['assessStepReview', 'assessPanelReview', 'runAssessmentTitle'],
  results: ['assessStepResults', 'assessPanelResults', 'resultsTitle']
};
const assessmentContextFields = {
  windows11: ['assessmentContextWindows11'],
  macos: ['assessmentContextMacos'],
  iosIpados: ['assessmentContextIosIpados', 'assessmentContextIosOwnership'],
  androidEnterprise: ['assessmentContextAndroidEnterprise', 'assessmentContextEnrollment']
};
// These mirror the <option> labels in index.html; the review must not depend on selectedIndex.
const assessmentEnrollmentLabels = {
  workProfile: 'Personally-owned work profile', fullyManaged: 'Fully managed', dedicated: 'Dedicated',
  corporateOwnedWorkProfile: 'Corporate-owned work profile'
};
const assessmentOwnershipLabels = {
  personallyOwned: 'Personally owned', corporateOwned: 'Corporate owned (excluded by personal-only guidance)'
};
const assessmentWindowsWarning = 'Windows policies targeting Windows 10 and later, such as the Settings Catalog ' +
  'policies that CIS build-kit packs map to, are assessed only when a Windows 11 build is entered ' +
  '(for example 10.0.22631 or 10.0.26100); otherwise their controls are reported as not assessed.';

function setAssessmentStep(step, focus) {
  const order = Object.keys(assessmentSteps);
  const current = order.indexOf(step);
  order.forEach((name, i) => {
    const [item, panel] = assessmentSteps[name];
    $(item).className = i < current ? 'done' : i === current ? 'active' : '';
    if (i === current) $(item).setAttribute('aria-current', 'step');
    else $(item).removeAttribute('aria-current');
    setHidden(panel, i !== current);
  });
  if (!focus) return;
  window.scrollTo(0, 0);
  $(assessmentSteps[step][2]).focus({ preventScroll: true });
}

function assessmentSelection() {
  const platforms = assessmentPlatformBoxes().filter((b) => b.checked && !b.disabled).map((b) => b.value);
  const identities = new Set(assessmentPackBoxes().filter((b) => b.checked && !b.disabled).map((b) => b.value));
  return { platforms, packs: assessmentPacks.filter((p) => identities.has(assessmentIdentity(p))) };
}

function assessmentSelectionError() {
  const { platforms, packs } = assessmentSelection();
  if (!platforms.length || platforms.some((p) => !packs.some((pack) => pack.platform === p))) {
    return 'Every selected platform requires a selected applicable pack; choose at least one platform.';
  }
  return !packs.length || packs.length > 64 ? 'Select 1–64 packs.' : null;
}

function selectAssessmentPacks(checked) {
  const filter = $('assessmentProfile').value;
  assessmentPackBoxes().forEach((b) => { if (!b.disabled && (!filter || filter === b.value)) b.checked = checked; });
  updateAssessmentSelection();
}

function updateAssessmentContext() {
  const { platforms } = assessmentSelection();
  Object.entries(assessmentContextFields).forEach(([platform, ids]) => {
    ids.forEach((id) => setHidden(id, !platforms.includes(platform)));
  });
  const warn = platforms.includes('windows11') && !$('assessmentOsWindows11').value.trim();
  $('assessmentContextWarning').textContent = warn ? assessmentWindowsWarning : '';
  setHidden('assessmentContextWarning', !warn);
}

function renderAssessmentReview() {
  const { platforms, packs } = assessmentSelection();
  const context = platforms.map((p) => {
    let line = `${assessmentPlatforms[p]} — OS version: ${$(assessmentOsId(p)).value.trim() || 'Unknown'}`;
    if (p === 'iosIpados') {
      line += '; ownership scope: ' + (assessmentOwnershipLabels[$('assessmentIosOwnership').value] || 'Unknown');
    }
    if (p === 'androidEnterprise') {
      line += '; enrollment mode: ' + (assessmentEnrollmentLabels[$('assessmentEnrollment').value] || 'Unknown');
    }
    const selected = packs.filter((pack) => pack.platform === p);
    return `<article class="review-platform"><h4>${escapeHtml(assessmentPlatforms[p])}</h4>
      <p>${escapeHtml(line)}</p><ul>${selected.map((pack) => `<li><strong>${escapeHtml(pack.framework)}${pack.frameworkVersion ? ' · ' + escapeHtml(pack.frameworkVersion) : ''} · ${escapeHtml(pack.profile)}</strong>
        <span>${escapeHtml(pack.id)} · version ${escapeHtml(pack.version)} · ${pack.origin === 'imported' ? 'Imported' : 'Bundled'}
        · ${escapeHtml(pack.coverage?.inventory)} inventory</span></li>`).join('')}</ul></article>`;
  });
  const source = state?.policies;
  $('assessmentReview').innerHTML = `<div class="notice"><strong>Target policy source</strong>
    <p>${escapeHtml(source?.source?.kind === 'offline' ? 'Offline import' : 'Live snapshot')} · ${escapeHtml(source?.tenant?.name || source?.tenant?.id || 'Environment name unavailable')}
    · Collected ${escapeHtml(source?.capturedAt || 'Unknown')}${source?.source?.importedAt ? ' · Imported ' + escapeHtml(source.source.importedAt) : ''}</p>
    <p>${Number(source?.count) || 0} policies · ${source?.status === 'partial' ? 'Incomplete evidence: some checks may remain not assessed.' : 'Loaded snapshot'}</p></div>
    <p class="muted">Each platform below connects the selected packs to your comparison context. This is not discovered device inventory or effective device compliance.</p>
    ${context.join('')}${platforms.includes('windows11') && !$('assessmentOsWindows11').value.trim()
      ? `<p class="notice">${escapeHtml(assessmentWindowsWarning)}</p>` : ''}`;
}

function blockAssessmentStep(message) {
  showAssessmentError(message);
  $('assessmentError').scrollIntoView({ block: 'nearest' });
}

function moveAssessmentStep(step) {
  showAssessmentError(null);
  if (step === 'context') updateAssessmentContext();
  if (step === 'review') renderAssessmentReview();
  setAssessmentStep(step, true);
}

$('btnAssessmentSelectAll').addEventListener('click', () => selectAssessmentPacks(true));
$('btnAssessmentSelectNone').addEventListener('click', () => selectAssessmentPacks(false));
$('assessmentOsWindows11').addEventListener('input', updateAssessmentContext);
$('btnAssessPlatformsNext').addEventListener('click', () => {
  if (!assessmentSelection().platforms.length) blockAssessmentStep('Choose at least one platform to assess.');
  else moveAssessmentStep('import');
});
$('btnAssessImportBack').addEventListener('click', () => { if (!assessmentImporting) moveAssessmentStep('platforms'); });
$('btnAssessImportNext').addEventListener('click', () => { if (!assessmentImporting) moveAssessmentStep('baselines'); });
$('btnAssessBaselinesBack').addEventListener('click', () => moveAssessmentStep('import'));
$('btnAssessBaselinesNext').addEventListener('click', () => {
  const error = assessmentSelectionError();
  if (error) blockAssessmentStep(error);
  else moveAssessmentStep('context');
});
$('btnAssessContextBack').addEventListener('click', () => moveAssessmentStep('baselines'));
$('btnAssessContextNext').addEventListener('click', () => moveAssessmentStep('review'));
$('btnAssessReviewBack').addEventListener('click', () => moveAssessmentStep('context'));
$('btnAssessNew').addEventListener('click', () => {
  if (!assessmentBusy) moveAssessmentStep('platforms');
});

function showAssessmentError(message) {
  $('assessmentError').textContent = message || '';
  if (message) $('assessmentError').classList.remove('hidden');
  else $('assessmentError').classList.add('hidden');
}

function syncJobAdmission() {
  const busy = exportBusy || assessmentBusy || sourceTransferBusy || !!state?.transfer?.running;
  $('btnExport').disabled = busy || !policiesReady();
  $('btnAssessmentRun').disabled = busy || assessmentImporting || !policiesReady();
  $('btnRefreshPolicies').disabled = busy || policyReloading || !state?.auth?.connected;
  $('btnRetryPolicies').disabled = busy || policyReloading;
  $('btnAssessmentImport').disabled = busy || assessmentImporting;
  $('btnAssessNew').disabled = assessmentBusy;
  ['btnImportPolicySource', 'btnReplacePolicySource', 'btnOpenPolicyImport', 'btnExportPolicySource'].forEach((id) => {
    $(id).disabled = busy || assessmentImporting || (id === 'btnExportPolicySource' && !policiesReady());
  });
  ['btnLoadPolicies', 'btnPoliciesNotNow'].forEach((id) => { $(id).disabled = busy || policyReloading; });
  ['btnQueueAssessmentFiles', 'btnQueueAssessmentFolder', 'btnQueueAssessmentPath', 'btnAssessImportBack', 'btnAssessImportNext'].forEach((id) => {
    $(id).disabled = busy || assessmentImporting;
  });
  Array.from($('assessmentImportQueue').children).forEach((row) => {
    if (row.children[1]) row.children[1].disabled = busy || assessmentImporting;
  });
  Array.from($('assessmentPacks').children).forEach((row) => {
    if (row.children[2]) row.children[2].disabled = busy || assessmentImporting;
  });
  ['navDocumentBusy', 'homeDocumentBusy'].forEach((id) => setHidden(id, !exportBusy));
  ['navAssessBusy', 'homeAssessBusy'].forEach((id) => setHidden(id, !assessmentBusy));
}

function clearAssessmentEvidence() {
  assessmentResult = null;
  ['assessmentResults', 'assessmentSummary', 'assessmentPolicies'].forEach((id) => { $(id).innerHTML = ''; });
  ['assessmentReportPaths', 'assessmentContextResult', 'assessmentPackResult', 'assessmentIssues',
    'assessmentProgress'].forEach((id) => { $(id).textContent = ''; });
  $('assessmentBar').style.width = '0%';
}

function clearAssessment() {
  assessmentGeneration++;
  assessmentCatalogRequest++;
  clearInterval(assessmentTimer);
  assessmentTimer = null;
  assessmentBusy = false;
  assessmentStarting = false;
  assessmentPolling = false;
  assessmentImporting = false;
  assessmentImportQueue = [];
  renderAssessmentImportQueue();
  clearAssessmentEvidence();
  $('assessmentOutputPath').value = '';
  $('assessmentImportFile').value = '';
  $('assessmentStatusFilter').value = '';
  Object.keys(assessmentPlatforms).forEach((p) => { $(assessmentOsId(p)).value = ''; });
  $('assessmentEnrollment').value = '';
  $('assessmentIosOwnership').value = '';
  ['assessmentImportSummary', 'assessmentReview', 'assessmentContextWarning'].forEach((id) => { $(id).textContent = ''; });
  ['assessmentImportSummary', 'assessmentReview'].forEach((id) => { $(id).innerHTML = ''; });
  setHidden('assessmentContextWarning', true);
  showAssessmentError(null);
  setAssessmentStep('platforms');
  syncJobAdmission();
}

const assessmentOsId = (platform) => 'assessmentOs' + platform[0].toUpperCase() + platform.slice(1);

function assessmentSessionFailure(r) {
  if (r.status !== 401) return false;
  clearWorkspace();
  if (state) state.auth = { connected: false };
  if (state) renderAuth();
  syncJobAdmission();
  showAssessmentError('401: Session expired. Sign in again before assessing policies.');
  showSigninError('Your session ended. Sign in again to continue.');
  return true;
}

async function loadAssessmentCatalog() {
  const generation = assessmentGeneration;
  const request = ++assessmentCatalogRequest;
  try {
    const r = await api('/api/assessment/packs');
    if (generation !== assessmentGeneration || request !== assessmentCatalogRequest) return;
    if (!r.ok) throw new Error(`${r.status}: ${r.body?.error || 'Catalog unavailable.'}`);
    if (Array.isArray(r.body?.packs)) renderAssessmentPacks(r.body);
  } catch (e) {
    if (generation === assessmentGeneration && request === assessmentCatalogRequest) showAssessmentError(e.message);
  }
}

function startAssessmentPolling() {
  if (!assessmentTimer) assessmentTimer = setInterval(refreshAssessment, 1000);
}

async function refreshAssessment() {
  if (assessmentPolling || !policiesReady()) return;
  const generation = assessmentGeneration;
  assessmentPolling = true;
  try {
    await refreshState();
    if (generation !== assessmentGeneration || !policiesReady()) return;
    const r = await api('/api/assessment');
    if (generation !== assessmentGeneration) return;
    if (assessmentSessionFailure(r)) return;
    if (r.status === 404) {
      clearAssessment();
      showAssessmentError('Assessment session reset. Select context and destination again.');
      return;
    }
    if (!r.ok || !r.body) throw new Error(`${r.status}: ${r.body?.error || 'Progress unavailable.'}`);
    const progress = r.body;
    if (progress.running && (assessmentResult || $('assessmentReportPaths').textContent)) clearAssessmentEvidence();
    assessmentBusy = assessmentStarting || !!progress.running;
    const percent = Math.max(0, Math.min(100, Number(progress.percent) || 0));
    $('assessmentBar').style.width = percent + '%';
    $('assessmentProgress').textContent = `${percent}% · ${progress.phase || 'Ready'}` +
      (progress.partial ? ' · Partial evidence — review collection limitations' : '');
    if (progress.running) startAssessmentPolling();
    else { clearInterval(assessmentTimer); assessmentTimer = null; }
    if (progress.error) {
      clearAssessmentEvidence();
      throw new Error(progress.error);
    }
    if (progress.running) setAssessmentStep('results');
    if (progress.done) {
      clearAssessmentEvidence();
      const results = await api('/api/assessment/results');
      if (generation !== assessmentGeneration) return;
      if (assessmentSessionFailure(results)) return;
      if (results.status === 404) {
        clearAssessment();
        showAssessmentError('Assessment results reset. Run a new assessment.');
        return;
      }
      if (!results.ok || !results.body) throw new Error(`${results.status}: ${results.body?.error || 'Results unavailable.'}`);
      renderAssessmentResult(results.body);
      setAssessmentStep('results');
      $('assessmentBar').style.width = percent + '%';
      $('assessmentProgress').textContent = `${percent}% · ${progress.phase || 'Complete'}` +
        (progress.partial ? ' · Partial evidence — review collection limitations' : '');
      const paths = progress.reportPaths;
      $('assessmentReportPaths').textContent = paths?.markdownPath && paths?.jsonPath
        ? `Markdown: ${paths.markdownPath}\nJSON: ${paths.jsonPath}` : '';
    } else if (!assessmentStarting && !progress.running && (assessmentResult || $('assessmentReportPaths').textContent)) {
      clearAssessment();
    }
    showAssessmentError(null);
  } catch (e) {
    if (generation === assessmentGeneration) showAssessmentError(e.message);
  } finally {
    if (generation === assessmentGeneration) { assessmentPolling = false; syncJobAdmission(); }
  }
}

$('btnAssessmentRun').addEventListener('click', async () => {
  if (assessmentImporting) { showAssessmentError('Wait for the pack import to finish.'); return; }
  if (assessmentBusy || exportBusy) { showAssessmentError('An export or assessment is already running.'); return; }
  if (!state?.auth?.connected && state?.policies?.source?.kind !== 'offline') {
    showAssessmentError('Sign in or import a policy set before assessing policies.'); return;
  }
  if (!policiesReady()) { showAssessmentError('Load policies before assessing.'); return; }
  const { platforms, packs: selectedPacks } = assessmentSelection();
  if (!platforms.length || platforms.some((p) => !selectedPacks.some((pack) => pack.platform === p))) {
    showAssessmentError('Every selected platform requires a selected applicable pack; choose at least one platform.');
    return;
  }
  if (!selectedPacks.length || selectedPacks.length > 64 || !$('assessmentOutputPath').value.trim()) {
    showAssessmentError('Select 1–64 packs and an absolute assessment report destination.');
    return;
  }
  const context = { platforms, osVersions: {}, enrollmentModes: {} };
  platforms.forEach((p) => {
    const version = $(assessmentOsId(p)).value.trim();
    if (version) context.osVersions[p] = version;
  });
  if (platforms.includes('androidEnterprise') && $('assessmentEnrollment').value) {
    context.enrollmentModes.androidEnterprise = $('assessmentEnrollment').value;
  }
  if (platforms.includes('iosIpados') && $('assessmentIosOwnership').value) {
    context.enrollmentModes.iosIpados = $('assessmentIosOwnership').value;
  }
  const generation = ++assessmentGeneration;
  clearInterval(assessmentTimer);
  assessmentTimer = null;
  assessmentPolling = false;
  assessmentBusy = true;
  assessmentStarting = true;
  syncJobAdmission();
  showAssessmentError(null);
  try {
    const r = await post('/api/assessment', {
      packIds: selectedPacks.map(assessmentIdentity), context, outputPath: $('assessmentOutputPath').value.trim()
    });
    if (generation !== assessmentGeneration) return;
    assessmentStarting = false;
    if (assessmentSessionFailure(r)) return;
    if (r.status !== 202 || !r.body?.started) throw new Error(`${r.status}: ${r.body?.error || 'Assessment did not start.'}`);
    clearAssessmentEvidence();
    $('assessmentProgress').textContent = 'Assessment admitted. Collecting policy evidence…';
    setAssessmentStep('results', true);
    startAssessmentPolling();
    await refreshAssessment();
  } catch (e) {
    if (generation === assessmentGeneration) {
      assessmentStarting = false;
      assessmentBusy = false;
      showAssessmentError(e.message);
    }
  } finally {
    if (generation === assessmentGeneration) syncJobAdmission();
  }
});

$('btnAssessmentRefresh').addEventListener('click', async () => {
  await loadAssessmentCatalog();
  await refreshAssessment();
});

function assessmentArchiveBase64(buffer) {
  const bytes = new Uint8Array(buffer);
  let binary = '';
  // Chunking keeps fromCharCode within argument limits; btoa runs once because 0x8000 is not a multiple of 3.
  for (let i = 0; i < bytes.length; i += 0x8000) {
    binary += String.fromCharCode.apply(null, bytes.subarray(i, i + 0x8000));
  }
  return btoa(binary);
}

function assessmentSkippedLines(body) {
  const skipped = Array.isArray(body?.skipped) ? body.skipped : [];
  const total = Number.isInteger(body?.skippedCount) ? body.skippedCount : skipped.length;
  const lines = [];
  if (total > 0) {
    lines.push(`Skipped ${total} archive ${total === 1 ? 'entry' : 'entries'}:`);
    skipped.slice(0, 10).forEach((s) => lines.push(`${s.entry}: ${s.reason}`));
    const shown = Math.min(skipped.length, 10);
    if (total > shown) lines.push(`…and ${total - shown} more.`);
  }
  if (body?.ignored > 0) {
    lines.push(`${body.ignored} other ${body.ignored === 1 ? 'file was' : 'files were'} ignored (not JSON).`);
  }
  return lines;
}

function assessmentImportReport(body, packs) {
  const lines = [`Imported ${packs.length} rule ${packs.length === 1 ? 'pack' : 'packs'} locally. ` +
    'Select the platforms and packs to assess; imports are never selected automatically.'];
  if (typeof body.added === 'number') lines.push(`${body.added} new, ${packs.length - body.added} already present.`);
  packs.forEach((p) => {
    let line = `${p.id} @ ${p.version} — ${assessmentPlatforms[p.platform]} · ${p.profile}`;
    if (typeof p.controlCount === 'number') {
      line += ` · ${p.controlCount} ${p.controlCount === 1 ? 'control' : 'controls'}`;
    }
    if (typeof p.added === 'boolean') line += p.added ? ' · new' : ' · already present';
    lines.push(line);
  });
  return [...lines, ...assessmentSkippedLines(body)].join('\n');
}

function renderAssessmentImportQueue() {
  const host = $('assessmentImportQueue');
  host.innerHTML = '';
  assessmentImportQueue.forEach((item) => {
    const row = document.createElement('div');
    row.className = 'import-queue-row';
    const text = document.createElement('div');
    text.innerHTML = `<strong>${escapeHtml(item.name)}</strong><small>${escapeHtml(item.kind === 'reference'
      ? 'Custom reference policy set' : 'Schema-1 packs / licensed CIS ZIP')} · ${item.path ? 'Host folder' : 'File'} · ${escapeHtml(item.status)}</small>
      ${item.status === 'importing' ? '<span class="spinner" aria-hidden="true"></span>' : ''}`;
    const remove = document.createElement('button');
    remove.className = 'btn ghost small';
    remove.disabled = assessmentImporting || assessmentBusy || exportBusy;
    remove.setAttribute('aria-label', `Remove ${item.name} from the import queue only`);
    remove.innerHTML = '<svg class="icon" viewBox="0 0 24 24" aria-hidden="true"><path d="M3 6h18M9 6V3h6v3M5 6l1 15h12l1-15M10 10v7M14 10v7"/></svg>';
    remove.addEventListener('click', () => {
      if (assessmentImporting) return;
      assessmentImportQueue = assessmentImportQueue.filter((candidate) => candidate.id !== item.id);
      renderAssessmentImportQueue();
    });
    row.appendChild(text); row.appendChild(remove); host.appendChild(row);
  });
  $('assessmentQueueStatus').textContent = assessmentImporting
    ? 'Importing the highlighted item. Completed independent items remain in your library if another item fails.'
    : `${assessmentImportQueue.length} queued items. Removing a queue item does not remove a library pack.`;
}

function queueAssessmentFiles() {
  if (assessmentImporting || assessmentBusy || exportBusy) return;
  for (const file of Array.from($('assessmentImportFile').files)) {
    assessmentImportQueue.push({ id: ++assessmentQueueSequence, file, name: file.name,
      kind: $('assessmentImportKind').value || 'packs', status: 'queued', result: null });
  }
  $('assessmentImportFile').value = '';
  renderAssessmentImportQueue();
}
$('btnQueueAssessmentFiles').addEventListener('click', queueAssessmentFiles);
$('btnQueueAssessmentPath').addEventListener('click', () => {
  if (assessmentImporting || assessmentBusy || exportBusy) return;
  const path = $('assessmentImportHostPath').value.trim();
  if (!path) { showAssessmentError('Enter an absolute host folder path first.'); return; }
  assessmentImportQueue.push({ id: ++assessmentQueueSequence, path, name: path,
    kind: $('assessmentImportKind').value || 'packs', status: 'queued', result: null });
  renderAssessmentImportQueue();
});
$('btnQueueAssessmentFolder').addEventListener('click', async () => {
  try {
    const path = await chooseHostFolder('assessmentImportHostPath', 'assessmentQueueStatus');
    if (!path) return;
    assessmentImportQueue.push({ id: ++assessmentQueueSequence, path, name: path,
      kind: $('assessmentImportKind').value || 'packs', status: 'queued', result: null });
    renderAssessmentImportQueue();
  } catch (e) { showAssessmentError(e.message); }
});

function renderAssessmentImportSummary() {
  let added = 0, present = 0, skipped = 0, ignored = 0, failed = 0;
  const items = assessmentImportQueue.filter((item) => item.result);
  const details = items.map((item) => {
    const result = item.result;
    const packs = Array.isArray(result.packs) ? result.packs : result.pack ? [result.pack] : [];
    const newCount = Number.isInteger(result.added) ? result.added : packs.length;
    added += newCount; present += packs.length - newCount;
    skipped += Number.isInteger(result.skippedCount) ? result.skippedCount : (result.skipped || []).length;
    ignored += Number(result.ignored) || 0;
    if (item.status === 'failed') failed++;
    return `<article class="import-result ${item.status === 'failed' ? 'import-failed' : ''}">
      <h4>${escapeHtml(item.name)} · ${escapeHtml(item.status)}</h4>
      ${result.error ? `<p>${escapeHtml(result.error)}</p>` : ''}
      <ul>${packs.map((pack) => `<li><strong>${escapeHtml(pack.framework)}${pack.frameworkVersion ? ' · ' + escapeHtml(pack.frameworkVersion) : ''} · ${escapeHtml(pack.profile)}</strong>
        <span>${escapeHtml(assessmentPlatforms[pack.platform])} · ${escapeHtml(pack.id)} · ${escapeHtml(pack.version)}
        ${pack.controlCount == null ? '' : ' · ' + Number(pack.controlCount) + ' checks'}
        · ${pack.added === false ? 'Already present' : 'Imported'}</span></li>`).join('')}</ul>
      ${(result.skipped || []).length ? `<details><summary>Skipped entries and reasons (${Number(result.skippedCount) || result.skipped.length})</summary>
        <ul>${result.skipped.map((entry) => `<li>${escapeHtml(entry.entry)}: ${escapeHtml(entry.reason)}</li>`).join('')}</ul>
        ${result.skippedCount > result.skipped.length ? `<p>${result.skippedCount - result.skipped.length} additional reasons not returned by the server.</p>` : ''}</details>` : ''}
      ${result.ignored ? `<p>${Number(result.ignored)} non-JSON files ignored.</p>` : ''}</article>`;
  });
  $('assessmentImportSummary').innerHTML = items.length
    ? `<div class="import-totals"><span><b>${added}</b> Added</span><span><b>${present}</b> Already present</span>
      <span><b>${skipped}</b> Skipped</span><span><b>${ignored}</b> Ignored files</span><span><b>${failed}</b> Failed items</span></div>
      <p class="muted">Select exact packs on the next step. Imports are never selected automatically.</p>${details.join('')}` : '';
}

async function removeAssessmentPack(pack) {
  if (assessmentImporting || assessmentBusy || exportBusy || sourceTransferBusy || pack.origin !== 'imported') return;
  if (!confirm(`Remove ${pack.id} version ${pack.version} from the local library? Saved reports remain unchanged.`)) return;
  const r = await post('/api/assessment/packs/remove', { selectionId: assessmentIdentity(pack), confirm: true });
  if (!r.ok) { showAssessmentError(r.body?.error || 'Could not remove the imported pack.'); return; }
  await loadAssessmentCatalog();
}

$('btnAssessmentImport').addEventListener('click', async () => {
  if (assessmentImporting || assessmentBusy || exportBusy) return;
  if (!assessmentImportQueue.length) queueAssessmentFiles();
  const pending = assessmentImportQueue.filter((item) => ['queued', 'failed'].includes(item.status));
  if (!pending.length) { showAssessmentError('Add files or a host folder to the queue first.'); return; }
  const generation = assessmentGeneration;
  assessmentCatalogRequest++;
  assessmentImporting = true;
  syncJobAdmission();
  showAssessmentError(null);
  renderAssessmentImportQueue();
  for (const item of pending) {
    item.status = 'importing'; item.result = null; renderAssessmentImportQueue();
    try {
    const file = item.file;
    let payload;
    if (item.path) {
      payload = { path: item.path, kind: item.kind };
    } else if (file && /\.zip$/i.test(file.name)) {
      if (!file.size || file.size > 32 * 1024 * 1024) throw new Error('Choose a nonempty ZIP archive, at most 32 MiB.');
      const buffer = await file.arrayBuffer();
      if (generation !== assessmentGeneration) return;
      payload = { archive: assessmentArchiveBase64(buffer), ...(item.kind === 'reference' ? { kind: 'reference' } : {}) };
    } else if (file && /\.json$/i.test(file.name)) {
      if (!file.size || file.size > 10 * 1024 * 1024) throw new Error('Choose a nonempty JSON rule pack, at most 10 MiB.');
      const content = await file.text();
      if (generation !== assessmentGeneration) return;
      if (new TextEncoder().encode(content).length > 10 * 1024 * 1024) {
        throw new Error('Decoded UTF-8 pack exceeds 10 MiB.');
      }
      if (item.kind === 'reference') throw new Error('A reference policy set must be a complete policy folder or ZIP, not a single JSON file.');
      payload = { content };
    } else {
      throw new Error('Choose a JSON rule pack (at most 10 MiB) or a ZIP archive (at most 32 MiB).');
    }
    const r = await post('/api/assessment/packs', payload);
    if (generation !== assessmentGeneration) return;
    if (assessmentSessionFailure(r)) return;
    const imported = Array.isArray(r.body?.packs) ? r.body.packs : r.body?.pack ? [r.body.pack] : null;
    item.result = r.body || {};
    if (!r.ok || !imported) {
      throw new Error(`${r.status}: ${r.body?.error || 'Pack import failed.'}`);
    }
    assessmentCatalogRequest++;
    const identities = new Set(imported.map(assessmentIdentity));
    const packs = assessmentPacks.filter((p) => !identities.has(assessmentIdentity(p)));
    renderAssessmentPacks({ packs: [...packs, ...imported], errors: assessmentCatalogIssues });
    item.status = 'completed';
  } catch (e) {
    if (generation !== assessmentGeneration) return;
    item.status = 'failed'; item.result = { ...(item.result || {}), error: e.message };
    showAssessmentError(e.message);
  }
  renderAssessmentImportQueue(); renderAssessmentImportSummary();
  }
  if (generation === assessmentGeneration) {
    assessmentImporting = false; renderAssessmentImportQueue(); syncJobAdmission();
  }
});

function renderAssessmentPolicySettings(policy) {
  const tables = (policy.settingsTables || []).map((table) => `
    ${table.title ? `<h4>${escapeHtml(table.title)}</h4>` : ''}
    <div class="assessment-settings-wrap"><table class="assessment-settings">
      <thead><tr>${(table.headers || []).map((header) => `<th scope="col">${escapeHtml(header)}</th>`).join('')}</tr></thead>
      <tbody>${(table.rows || []).map((row) =>
        `<tr>${(row.cells || []).map((cell) => `<td>${escapeHtml(cell)}</td>`).join('')}</tr>`).join('')}</tbody>
    </table></div>`).join('');
  return `<p class="muted">${escapeHtml(policy.settingsNote || 'Readable settings are unavailable for this saved result. See technical evidence.')}</p>${tables}`;
}

function renderAssessmentTypedValues(records, expected) {
  if (!Array.isArray(records)) return assessmentText(records);
  if (!records.length) return 'No mapped values';
  return records.map((record) => {
    const name = record.displayName || record.property || record.settingId || 'Unmapped setting';
    const raw = expected ? record.expected : record.value;
    const value = record.displayValue ?? (!expected && (record.secret === true || record.supported === false)
      ? 'Unavailable (secret or unsupported evidence)' : JSON.stringify(raw));
    return `<p><strong>${escapeHtml(name)}</strong>: ${expected ? escapeHtml(record.operator || '') + ' ' : ''}${escapeHtml(value)}</p>`;
  }).join('');
}

function renderAssessmentResult(result) {
  assessmentResult = result;
  $('assessmentLimitations').textContent = assessmentLimits;
  $('assessmentSummary').innerHTML = (result.summaries || []).map((s) => `
    <div class="assessment-pack">
      <strong>${escapeHtml(s.packId)} · ${escapeHtml(s.platform)} · ${escapeHtml(s.profile)}</strong>
      <p>${escapeHtml(s.inventory)} inventory — listed controls only</p>
      <p>Assessment coverage: ${assessmentPercent(s.coveragePercent)} (${escapeHtml(s.assessed)} assessed /
        ${escapeHtml(s.coverageDenominator)} applicable or unknown listed controls).
        Configuration alignment: ${assessmentPercent(s.alignmentPercent)} of assessed controls.</p>
      <p>${Object.entries(assessmentStatuses).map(([key, label]) =>
        `${label}: ${escapeHtml((s.counts || {})[key] || 0)}`).join(' · ')}</p>
    </div>`).join('');
  $('assessmentContextResult').textContent = 'User-selected context: ' + JSON.stringify(result.context || {});
  $('assessmentPackResult').textContent = 'Assessed pack identities, sources and coverage: ' + JSON.stringify(result.packs || []);
  $('assessmentIssues').textContent = 'Collection completeness and limitations: ' +
    JSON.stringify({ sources: result.sources || [], issues: result.collectionIssues || [] });
  $('assessmentPolicies').innerHTML = (result.policies || []).map((p) => `
    <div class="assessment-pack"><strong>${escapeHtml(p.name || p.key)}</strong>
      <p>${p.assignmentsComplete !== true ? 'Assignment evidence incomplete'
        : !(p.assignments || []).length ? 'Unassigned' : 'Assignment targets present — effective targeting not resolved'}</p>
      ${renderAssessmentPolicySettings(p)}
      <details><summary>Technical policy and assignment evidence</summary>
        <pre class="assessment-text">${assessmentText({ ...p, settingsTables: undefined, settingsNote: undefined })}</pre>
      </details></div>`).join('');
  renderAssessmentEvidence();
}

function renderAssessmentEvidence() {
  const result = assessmentResult || {};
  const filter = $('assessmentStatusFilter').value;
  const policies = new Map((result.policies || []).map((p) => [p.key, p]));
  $('assessmentResults').innerHTML = (result.controls || [])
    .filter((c) => !filter || c.status === filter).map((c) => {
      const evidence = (c.policyResults || []).map((p) => {
        const policy = policies.get(p.policyKey) || {};
        const incomplete = p.assignmentsComplete === false || policy.assignmentsComplete === false ||
          (p.assignmentsComplete !== true && policy.assignmentsComplete !== true);
        const assignment = (p.assigned === false ? 'Unassigned' : p.assigned === true ? 'Assigned' : 'Assignment unknown') +
          (incomplete ? ' · Assignment evidence incomplete' : '');
        return `<div class="assessment-policy"><strong>${escapeHtml(policy.name || p.policyKey)}</strong>
          <p>${escapeHtml(p.policyKey)} · ${escapeHtml(policy.family)} · ${escapeHtml(policy.policyType)}</p>
          <p>${escapeHtml(assessmentStatuses[p.status] || p.status)}: ${escapeHtml(p.reason)}</p>
          <p>${assignment}</p>
          <details><summary>Readable policy settings</summary>${renderAssessmentPolicySettings(policy)}</details>
          <details><summary>Exact mappings and assignment evidence</summary>
            <pre>${assessmentText(policy.assignments || [])}</pre>
            <p>Expected: ${assessmentText(p.expected || [])}</p>
            <p>Configured: ${assessmentText(p.observed || [])}</p>
          </details></div>`;
      }).join('');
      return `<tr><td><strong>${escapeHtml(c.controlId)} ${escapeHtml(c.title)}</strong>
        <p>${escapeHtml(c.packId)} @ ${escapeHtml(c.packVersion)} · ${escapeHtml(c.platform)} · ${escapeHtml(c.profile)}</p>
        <details><summary>Framework references</summary><pre>${assessmentText(c.references || [])}</pre></details></td>
        <td><strong>${escapeHtml(assessmentStatuses[c.status] || c.status)}</strong><p>${escapeHtml(c.reason)}</p></td>
        <td><strong>Expected</strong>${renderAssessmentTypedValues(c.expected, true)}
          <strong>Configured</strong>${renderAssessmentTypedValues(c.observed || [], false)}
          <details><summary>Exact typed evidence</summary>
            <p>Expected: ${assessmentText(c.expected)}</p><p>Configured: ${assessmentText(c.observed || [])}</p>
          </details></td>
        <td>${evidence || 'No policy evidence'}</td></tr>`;
    }).join('');
}

$('assessmentStatusFilter').addEventListener('change', renderAssessmentEvidence);

// --- Boot ------------------------------------------------------------------

async function loadInitialState() {
  $('loadingText').textContent = 'Connecting to the local server…';
  setHidden('loadingSpinner', false);
  setHidden('btnRetryState', true);
  try { await refreshState(); } catch (e) { /* reported below */ }
  if (state) return true;
  renderRoute();
  $('loadingText').textContent = 'The local server is not responding. Restart Intune Docs Studio.';
  setHidden('loadingSpinner', true);
  setHidden('btnRetryState', false);
  return false;
}

async function start() {
  if (booting) return;
  booting = true;
  try {
    if (!(await loadInitialState())) return;
    await loadAssessmentCatalog();
    await refreshAssessment();
    const { body } = await api('/api/export/log?from=0');
    if (body && body.running) {
      $('cardRun').classList.remove('hidden');
      setDocumentStep('generate');
      startLogPolling();
    }
  } finally {
    booting = false;
  }
}

$('btnRetryState').addEventListener('click', start);

(function init() {
  const params = new URLSearchParams(window.location.search);
  if (params.has('signin')) {
    window.history.replaceState({}, '', '/' + (window.location.hash || ''));
    if (params.get('signin') === 'state-mismatch') {
      showSigninError('Sign-in could not be verified (state mismatch). Please try again.');
    }
  }
  setDocumentStep('configure');
  setAssessmentStep('platforms');
  start();
})();
