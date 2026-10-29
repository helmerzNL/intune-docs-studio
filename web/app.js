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

const setHidden = (id, hidden) => {
  if (hidden) $(id).classList.add('hidden');
  else $(id).classList.remove('hidden');
};

// --- Navigation ------------------------------------------------------------

const views = { loading: 'viewLoading', landing: 'viewLanding', home: 'viewHome', document: 'viewDocument', assess: 'viewAssess' };
const viewHeadings = { landing: 'landingTitle', home: 'homeTitle', document: 'documentTitle', assess: 'assessTitle' };
const navLinks = { home: 'navHome', document: 'navDocument', assess: 'navAssess' };
const routes = { '#/document': 'document', '#/assess': 'assess' };
let lastRoute = 'home';

// In-page anchors such as the skip link (#main) keep the current route.
const isRouteHash = (hash) => !hash || hash.startsWith('#/');

function routeView() {
  if (!state) return 'loading';
  if (!state.auth?.connected) return 'landing';
  const hash = window.location.hash || '';
  if (isRouteHash(hash)) lastRoute = routes[hash] || 'home';
  return lastRoute;
}

function renderRoute() {
  const view = routeView();
  Object.entries(views).forEach(([key, id]) => setHidden(id, key !== view));
  const signedIn = !!navLinks[view];
  setHidden('appNav', !signedIn);
  setHidden('sessionControls', !signedIn);
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
  const identity = (s) => JSON.stringify(s?.auth || {}, ['connected', 'tenantId', 'account', 'client', 'method']);
  if (state && identity(state) !== identity(body)) clearWorkspace();
  state = body;
  if (body.export) exportBusy = exportStarting || !!body.export.running;
  renderBuild(body.build);
  renderAuth();
  syncJobAdmission();
}

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
  if (host.children.length || !state.sections) return;
  state.sections.forEach((s) => {
    const label = document.createElement('label');
    label.className = 'check';
    label.innerHTML = `<input type="checkbox" value="${s.key}" checked><span>${s.label}</span>`;
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
    checkFolder();

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
    $('cardConfigure').classList.add('disabled');
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
  if (!path || !state || !state.auth || !state.auth.connected) return;
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
    'Unavailable platform/profile combinations are disabled. ' +
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
    box.disabled = !available;
    box.checked = available && platforms.has(key);
    box.addEventListener('change', updateAssessmentSelection);
    const text = document.createElement('span');
    text.textContent = name + (available ? '' : ' — unavailable, import a pack');
    label.appendChild(box);
    label.appendChild(text);
    $('assessmentPlatforms').appendChild(label);
  });
  const profile = $('assessmentProfile');
  const previous = profile.value;
  const profiles = Array.from(new Set(assessmentPacks.map((p) => p.profile)));
  profile.innerHTML = '';
  ['', ...profiles].forEach((value) => {
    const option = document.createElement('option');
    option.value = value;
    option.textContent = value || 'All available profiles (select packs below)';
    profile.appendChild(option);
  });
  profile.value = profiles.includes(previous) ? previous : '';
  $('assessmentPacks').innerHTML = '';
  assessmentPacks.forEach((p) => {
    const label = document.createElement('label');
    label.className = 'check assessment-pack';
    const box = document.createElement('input');
    box.type = 'checkbox';
    box.value = assessmentIdentity(p);
    box.checked = selected.has(box.value);
    box.addEventListener('change', updateAssessmentSelection);
    const text = document.createElement('span');
    const classification = p.origin === 'imported'
      ? `${p.framework} — customer-imported local pack; author-declared ${p.classification}`
      : p.origin !== 'bundled' ? `${p.framework} — unverified origin; author-declared ${p.classification}`
      : p.framework === 'Microsoft' ? (p.classification === 'baseline'
        ? 'Official Microsoft security baseline — partial mapped checks' : 'Microsoft recommendations')
        : `${p.framework} — local rule pack`;
    text.innerHTML = `<strong>${escapeHtml(p.id)} @ ${escapeHtml(p.version)}</strong>
      <small>${escapeHtml(classification)} · ${escapeHtml(p.frameworkVersion)}</small>
      <small>${escapeHtml(assessmentPlatforms[p.platform])} · ${escapeHtml(p.profile)}</small>
      <small>${escapeHtml(p.coverage?.inventory)} inventory; source total: ${escapeHtml(p.coverage?.totalSourceControls ?? 'unknown')}.
        Source revision: ${escapeHtml(p.sourceRevision)}</small>
      <small>Sources: ${assessmentText(p.sources || [])}</small>
      <small>SHA-256: ${escapeHtml(p.sha256)}</small>`;
    label.appendChild(box);
    label.appendChild(text);
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
    box.disabled = !platforms.includes(pack.platform) || (!!profile && profile !== pack.profile);
    if (box.disabled) {
      box.checked = false;
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
  setHidden('assessImportPanel', current > 1);
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
  assessmentPackBoxes().forEach((b) => { if (!b.disabled) b.checked = checked; });
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
    return line;
  });
  const lines = [
    'Platforms: ' + (platforms.map((p) => assessmentPlatforms[p]).join(', ') || 'none'),
    '',
    'Rule packs:',
    ...(packs.length ? packs.map((p) => `${p.id} @ ${p.version} — ${assessmentPlatforms[p.platform]} · ${p.profile}`)
      : ['none']),
    '',
    'Context (user-selected, not discovered device inventory):',
    ...context
  ];
  if (platforms.includes('windows11') && !$('assessmentOsWindows11').value.trim()) {
    lines.push('', assessmentWindowsWarning);
  }
  $('assessmentReview').textContent = lines.join('\n');
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
  else moveAssessmentStep('baselines');
});
$('btnAssessBaselinesBack').addEventListener('click', () => moveAssessmentStep('platforms'));
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
  const busy = exportBusy || assessmentBusy;
  $('btnExport').disabled = busy || !!(state?.auth && !state.auth.connected);
  $('btnAssessmentRun').disabled = busy || assessmentImporting || !state?.auth?.connected;
  $('btnAssessmentImport').disabled = busy || assessmentImporting;
  $('btnAssessNew').disabled = assessmentBusy;
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
  clearAssessmentEvidence();
  $('assessmentOutputPath').value = '';
  $('assessmentImportFile').value = '';
  $('assessmentStatusFilter').value = '';
  Object.keys(assessmentPlatforms).forEach((p) => { $(assessmentOsId(p)).value = ''; });
  $('assessmentEnrollment').value = '';
  $('assessmentIosOwnership').value = '';
  ['assessmentImportSummary', 'assessmentReview', 'assessmentContextWarning'].forEach((id) => { $(id).textContent = ''; });
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
  if (assessmentPolling || !state?.auth?.connected) return;
  const generation = assessmentGeneration;
  assessmentPolling = true;
  try {
    await refreshState();
    if (generation !== assessmentGeneration || !state?.auth?.connected) return;
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
  if (!state?.auth?.connected) { showAssessmentError('Sign in before assessing policies.'); return; }
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

$('btnAssessmentImport').addEventListener('click', async () => {
  if (assessmentImporting || assessmentBusy || exportBusy) return;
  const generation = assessmentGeneration;
  assessmentCatalogRequest++;
  assessmentImporting = true;
  syncJobAdmission();
  showAssessmentError(null);
  $('assessmentImportSummary').textContent = '';
  try {
    const file = $('assessmentImportFile').files[0];
    let payload;
    if (file && /\.zip$/i.test(file.name)) {
      if (!file.size || file.size > 32 * 1024 * 1024) throw new Error('Choose a nonempty ZIP archive, at most 32 MiB.');
      const buffer = await file.arrayBuffer();
      if (generation !== assessmentGeneration) return;
      payload = { archive: assessmentArchiveBase64(buffer) };
    } else if (file && /\.json$/i.test(file.name)) {
      if (!file.size || file.size > 10 * 1024 * 1024) throw new Error('Choose a nonempty JSON rule pack, at most 10 MiB.');
      const content = await file.text();
      if (generation !== assessmentGeneration) return;
      if (new TextEncoder().encode(content).length > 10 * 1024 * 1024) {
        throw new Error('Decoded UTF-8 pack exceeds 10 MiB.');
      }
      payload = { content };
    } else {
      throw new Error('Choose a JSON rule pack (at most 10 MiB) or a ZIP archive (at most 32 MiB).');
    }
    const r = await post('/api/assessment/packs', payload);
    if (generation !== assessmentGeneration) return;
    if (assessmentSessionFailure(r)) return;
    const imported = Array.isArray(r.body?.packs) ? r.body.packs : r.body?.pack ? [r.body.pack] : null;
    if (!r.ok || !imported) {
      if (Array.isArray(r.body?.skipped)) {
        $('assessmentImportSummary').textContent =
          ['Nothing was imported.', ...assessmentSkippedLines(r.body)].join('\n');
      }
      throw new Error(`${r.status}: ${r.body?.error || 'Pack import failed.'}`);
    }
    assessmentCatalogRequest++;
    const identities = new Set(imported.map(assessmentIdentity));
    const packs = assessmentPacks.filter((p) => !identities.has(assessmentIdentity(p)));
    renderAssessmentPacks({ packs: [...packs, ...imported], errors: assessmentCatalogIssues });
    $('assessmentImportSummary').textContent = assessmentImportReport(r.body, imported);
  } catch (e) {
    if (generation === assessmentGeneration) showAssessmentError(e.message);
  } finally {
    if (generation === assessmentGeneration) {
      assessmentImporting = false;
      syncJobAdmission();
    }
  }
});

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
      <pre class="assessment-text">${assessmentText(p)}</pre></div>`).join('');
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
          <pre>${assessmentText(policy.assignments || [])}</pre>
          <p>Expected: ${assessmentText(p.expected || [])}</p>
          <p>Configured: ${assessmentText(p.observed || [])}</p></div>`;
      }).join('');
      return `<tr><td><strong>${escapeHtml(c.controlId)} ${escapeHtml(c.title)}</strong>
        <p>${escapeHtml(c.packId)} @ ${escapeHtml(c.packVersion)} · ${escapeHtml(c.platform)} · ${escapeHtml(c.profile)}</p>
        <details><summary>Framework references</summary><pre>${assessmentText(c.references || [])}</pre></details></td>
        <td><strong>${escapeHtml(assessmentStatuses[c.status] || c.status)}</strong><p>${escapeHtml(c.reason)}</p></td>
        <td><p>Expected: ${assessmentText(c.expected)}</p><p>Configured: ${assessmentText(c.observed || [])}</p></td>
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
