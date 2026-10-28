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
  const { body } = await api('/api/state');
  if (!body) return;
  state = body;
  renderBuild(body.build);
  renderAuth();
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

  const auth = state.auth || {};
  const badge = $('connBadge');

  if (auth.connected) {
    badge.textContent = auth.account || 'Connected';
    badge.className = 'badge badge-on';
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
}

$('btnBrowser').addEventListener('click', async () => {
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
  await post('/api/signin/browser/forget');
  $('bsText').textContent = 'Saved browser session cleared.';
  $('browserStatus').classList.remove('hidden');
  setTimeout(() => $('browserStatus').classList.add('hidden'), 2500);
});

$('btnInteractive').addEventListener('click', async () => {
  showSigninError(null);
  const { body } = await post('/api/signin/interactive', {
    tenant: $('tenant').value.trim() || 'organizations',
    client: $('client').value
  });
  if (body && body.url) { window.location.href = body.url; }
  else { showSigninError('Could not start sign-in.'); }
});

$('btnDeviceCode').addEventListener('click', async () => {
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
  showSigninError(null);
  const { body } = await post('/api/signin/azurecli');
  if (body && body.error) { showSigninError(body.error); return; }
  await refreshState();
});

$('btnMgGraph').addEventListener('click', async () => {
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
}

$('btnSignout').addEventListener('click', async () => {
  const { body } = await post('/api/signout');
  if (body && body.error) { alert(body.error); return; }
  clearWorkspace();
  if (body && body.outputPath) $('outputPath').value = body.outputPath;
  if (body && body.tenant) $('tenant').value = body.tenant;
  await refreshState();
});

// --- Configure -------------------------------------------------------------

async function checkFolder() {
  const path = $('outputPath').value.trim();
  if (!path || !state || !state.auth || !state.auth.connected) return;
  const { body } = await api('/api/checkfolder?path=' + encodeURIComponent(path));
  const el = $('folderWarn');
  if (body && body.conflict) {
    el.innerHTML = body.conflict +
      (body.suggestion ? ` <button class="linkbtn" id="btnUseSuggestion">use ${body.suggestion}</button>` : '');
    el.classList.remove('hidden');
    const b = $('btnUseSuggestion');
    if (b) b.addEventListener('click', () => {
      $('outputPath').value = body.suggestion;
      el.classList.add('hidden');
    });
  } else {
    el.classList.add('hidden');
  }
}

$('outputPath').addEventListener('change', checkFolder);
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

  const { body } = await post('/api/export', payload);
  if (body && body.error) { alert(body.error); return; }

  logCursor = 0;
  $('log').textContent = '';
  $('cardRun').classList.remove('hidden');
  $('cardResult').classList.add('hidden');
  $('cardConfigure').classList.add('disabled');
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
  const { body } = await api('/api/export/log?from=' + logCursor);
  if (!body) return;

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
    $('cardConfigure').classList.remove('disabled');
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
    html += '<h3>Warnings</h3><ul class="muted">' + s.warnings.map((w) => `<li>${escapeHtml(w)}</li>`).join('') + '</ul>';
  }
  $('summary').innerHTML = html;
}

async function loadFiles() {
  const { body } = await api('/api/files');
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
      $('preview').textContent = r.body && r.body.content ? r.body.content : '(unable to read file)';
      $('preview').scrollTop = 0;
    });
    host.appendChild(btn);
  });
}

$('btnOpen').addEventListener('click', () => post('/api/open'));

$('btnQuit').addEventListener('click', async () => {
  if (state && state.export && state.export.running) {
    alert('An export is still running. Wait for it to finish before stopping the server.');
    return;
  }
  if (!confirm('Stop the Intune Docs Studio server?')) return;
  clearInterval(logTimer);
  clearInterval(deviceTimer);
  try { await post('/api/quit'); } catch (e) { /* the server goes away mid-request */ }
  document.body.innerHTML =
    '<div style="font-family:Segoe UI,system-ui,sans-serif;padding:4rem;text-align:center;color:#9aa4b8">' +
    '<h2 style="color:#e7eaf0">Intune Docs Studio has stopped.</h2>' +
    '<p>You can close this tab. Run <code>Start-IntuneDocs.cmd</code> to start it again.</p></div>';
});
$('btnAgain').addEventListener('click', () => {
  $('cardResult').classList.add('hidden');
  $('cardRun').classList.add('hidden');
  $('cardConfigure').scrollIntoView({ behavior: 'smooth' });
});

// --- Boot ------------------------------------------------------------------

(async function init() {
  const params = new URLSearchParams(window.location.search);
  if (params.has('signin')) {
    window.history.replaceState({}, '', '/');
    if (params.get('signin') === 'state-mismatch') {
      showSigninError('Sign-in could not be verified (state mismatch). Please try again.');
    }
  }
  await refreshState();
  const { body } = await api('/api/export/log?from=0');
  if (body && body.running) {
    $('cardRun').classList.remove('hidden');
    startLogPolling();
  }
})();
