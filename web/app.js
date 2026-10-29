'use strict';

const $ = (id) => document.getElementById(id);
const escapeHtml = (value) => String(value == null ? '' : value)
  .replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;')
  .replace(/"/g, '&quot;').replace(/'/g, '&#39;');
const i18n = window.IdsI18n;
const t = (key, args) => i18n.t(key, args);
const h = (key, args) => escapeHtml(t(key, args));
const number = (value) => i18n.formatNumber(Number(value) || 0);
const countControls = (count) => t(`count.control_${i18n.plural(count)}`, { count });
const countPolicies = (count) => t(`count.policy_${i18n.plural(count)}`, { count });
const sectionKeys = {
  settingsCatalog: 'section.settingsCatalog', deviceConfigs: 'section.deviceConfigs',
  deviceConfiguration: 'section.deviceConfigs', admx: 'section.admx', groupPolicyConfigurations: 'section.admx',
  compliance: 'section.compliance', deviceCompliance: 'section.compliance',
  endpointSecurity: 'section.endpointSecurity', intent: 'section.endpointSecurity', intents: 'section.endpointSecurity',
  apps: 'section.apps', appManagement: 'section.appManagement', scripts: 'section.scripts',
  remediations: 'section.remediations', enrollment: 'section.enrollment',
  reference: 'section.reference', groups: 'section.groups'
};
const sectionLabel = (key, fallback = key) => sectionKeys[key] ? t(sectionKeys[key]) : fallback;
const inventoryLabel = (key) => ({
  partial: t('inventory.partial'), complete: t('inventory.full'), full: t('inventory.full')
})[key] || key || t('text.unknown');
const classificationLabel = (key) => ({
  baseline: t('classification.baseline'), recommendations: t('classification.recommendations'), custom: t('classification.custom')
})[key] || key;
const queueStatus = (key) => ({
  queued: t('queue.queued'), importing: t('queue.importing'), completed: t('text.complete'), failed: t('text.failed')
})[key] || key;
const scopeKeys = {
  'DeviceManagementConfiguration.Read.All': 'scope.configuration', 'DeviceManagementApps.Read.All': 'scope.apps',
  'DeviceManagementServiceConfig.Read.All': 'scope.enrollment', 'DeviceManagementRBAC.Read.All': 'scope.roles',
  'DeviceManagementManagedDevices.Read.All': 'scope.devices', 'Group.Read.All': 'scope.groups'
};
const authMethodLabel = (method) => {
  const keys = { portal: 'method.portal', browser: 'method.portal', interactive: 'method.interactive', devicecode: 'method.devicecode' };
  return keys[method] ? t(keys[method]) : method;
};
const textBindings = new Map();
function writeText(element, value) {
  textBindings.delete(element);
  element.textContent = value;
}
function localizeText(element, render) {
  const value = render();
  writeText(element, value);
  textBindings.set(element, { render, value });
}
class UiError extends Error {
  constructor(render) { super(render()); this.render = render; }
}
function showMessage(element, message) {
  if (typeof message === 'function') localizeText(element, message);
  else if (message instanceof UiError) localizeText(element, message.render);
  else writeText(element, typeof message?.message === 'string' ? message.message : message || '');
}
const api = async (path, options) => {
  const res = await fetch(path, {
    ...options, headers: { ...options?.headers, 'X-Ids-Locale': i18n.locale }
  });
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
let documentSummary = null;

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
  showMessage(el, message);
  el.classList.remove('hidden');
}

function renderBuild(build) {
  if (!build) return;
  const name = 'Intune Docs Studio' + (build.channel === 'stable' ? '' : ' (' + build.channel + ')');
  writeText($('appName'), name);
  document.title = name;
  writeText($('buildInfo'), 'v' + build.version + ' ' + build.channel);
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
    void transferPolicySource(operation, null, statusId, true).catch((e) => { showMessage($(statusId), e); });
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

function renderPolicyState(updateTimers = true) {
  const policies = state?.policies || {};
  const waiting = policies.status === 'loading';
  const consent = !!policies.consentRequired;
  const failed = policies.status === 'failed';
  const percent = Math.max(0, Math.min(100, Number(policies.percent) || 0));
  $('policyLoadBar').style.width = percent + '%';
  $('policyLoadProgress').setAttribute('aria-valuenow', percent);
  localizeText($('policyLoadPhase'), () => policies.phase || t("text.no_collection_has_started"));
  localizeText($('policyLoadTitle'), () => consent && !waiting ? t("text.load_policies_now") : t("text.loading_your_intune_policies"));
  setHidden('policyConsentActions', !consent && !failed);
  setHidden('policyLoadProgress', !waiting);
  localizeText($('policyLoadTenant'), () => state?.auth?.tenantId ? (t("text.tenant") + " ") + state.auth.tenantId : '');
  if (updateTimers) {
    writeText($('policyLoadError'), policies.error || '');
    setHidden('policyLoadError', !policies.error);
  }
  setHidden('policyLoadSpinner', !waiting);
  setHidden('btnRetryPolicies', !failed);
  const offline = policies.source?.kind === 'offline';
  const ready = ['ready', 'partial'].includes(policies.status);
  localizeText($('policySummary'), () => ready ? [
    [countPolicies(Number(policies.count) || 0), offline ? t("text.offline_import") : t("text.live_snapshot")].join(' · '),
    t("text.collected_202", { v0: i18n.formatDate(policies.capturedAt) }),
    ...(policies.source?.importedAt ? [t("text.imported_201", { v0: i18n.formatDate(policies.source.importedAt) })] : [])
  ].join(' ') : t("text.no_policies_loaded_yet"));
  localizeText($('policySourceDescription'), () => offline
    ? t("text.both_workflows_use_this_offline_source_no_graph_or")
    : ready ? t("text.both_workflows_use_this_snapshot_refresh_explicitly_to_read")
      : t("text.you_can_stay_signed_in_without_loading_data_load"));
  localizeText($('btnRefreshPolicies'), () => offline ? t("text.replace_with_live_policies") : ready ? t("text.refresh_live_policies") : t("text.load_live_policies"));
  ['homeDocument', 'homeAssess', 'navDocument', 'navAssess'].forEach((id) => {
    $(id).setAttribute('aria-disabled', ready ? 'false' : 'true');
  });
  $('policyFamilies').innerHTML = (policies.families || []).map((family) =>
    `<div class="stat"><b>${number(family.count)}</b><span>${escapeHtml(sectionLabel(family.key || family.family, family.label))}</span>` +
    (family.complete ? '' : `<p class="muted">${h("text.incomplete_evidence")}</p>`) + '</div>').join('');
  const partial = policies.status === 'partial';
  setHidden('policyLimitations', !partial);
  localizeText($('policyLimitations'), () => partial ?
    (t("text.some_policies_could_not_be_fully_read_assessment_keeps") + " ") +
      (policies.issues || []).map((issue) =>
        `${issue.family}: ${issue.stage} — ${issue.reason}${issue.statusCode ? ` (HTTP ${issue.statusCode})` : ''}`).join('\n') : '');
  if (updateTimers) {
    if (waiting && !failed && !policyTimer) policyTimer = setInterval(pollPolicyState, 1000);
    if (!waiting || failed) { clearInterval(policyTimer); policyTimer = null; }
  }
}

async function pollPolicyState() {
  if (policyPolling || !state?.auth?.connected) return;
  const generation = workspaceGeneration;
  policyPolling = true;
  try { await refreshState(); }
  catch (e) {
    if (generation === workspaceGeneration) {
      localizeText($('policyLoadError'), () => t("text.policy_progress_is_unavailable_checking_the_local_server_again"));
      setHidden('policyLoadError', false);
    }
  } finally { if (generation === workspaceGeneration) policyPolling = false; }
}

async function reloadPolicies() {
  if (policyReloading || exportBusy || assessmentBusy || !state?.auth?.connected) return;
  const replace = ['ready', 'partial'].includes(state?.policies?.status);
  if (replace && !confirm(t("text.replace_the_active_policy_source_with_a_new_live"))) return;
  const generation = workspaceGeneration;
  policyReloading = true;
  syncJobAdmission();
  try {
    const r = await post('/api/policies/reload', { replace });
    if (generation !== workspaceGeneration) return;
    if (assessmentSessionFailure(r)) return;
    if (!r.ok) throw new UiError(() => r.body?.error || t("text.could_not_reload_policies"));
    state.policies = { status: 'loading', percent: 0 };
    clearAssessment();
    writeText($('policyRefreshError'), '');
    setHidden('policyRefreshError', true);
  } catch (e) {
    if (generation !== workspaceGeneration) return;
    ['policyLoadError', 'policyRefreshError'].forEach((id) => {
      showMessage($(id), e); setHidden(id, false);
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
  if (!r.ok) { localizeText($('policyLoadError'), () => r.body?.error || t("text.could_not_save_your_choice")); setHidden('policyLoadError', false); return; }
  await refreshState();
  $('homeTitle').focus({ preventScroll: true });
});

const waitForLocalJob = () => new Promise((resolve) => setTimeout(resolve, 300));

async function chooseHostFolder(inputId, statusId) {
  if (folderPickerBusy) throw new UiError(() => t("text.a_folder_dialog_is_already_open_on_the_application"));
  folderPickerBusy = true;
  localizeText($(statusId), () => t("text.choose_a_folder_in_the_windows_dialog_on_the"));
  try {
    const started = await post('/api/folders/picker', { initialPath: $(inputId).value });
    if (!started.ok) throw new UiError(() => started.body?.error || t("text.could_not_open_folder_selection"));
    while (true) {
      const r = await api('/api/folders/picker');
      if (!r.ok) throw new UiError(() => r.body?.error || t("text.folder_selection_is_unavailable"));
      if (r.body?.status === 'selected') {
        $(inputId).value = r.body.path;
        localizeText($(statusId), () => t("text.host_folder_selected"));
        return r.body.path;
      }
      if (r.body?.status === 'cancelled') { localizeText($(statusId), () => t("text.folder_selection_cancelled_current_path_unchanged")); return null; }
      if (r.body?.status !== 'running') throw new UiError(() => r.body?.error || t("text.folder_selection_ended_unexpectedly_enter_the_host_path_manually"));
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
$('btnShowPolicyExport').addEventListener('click', () => {
  if (!policiesReady() || exportBusy || assessmentBusy || assessmentImporting) return;
  $('policyExportPanel').open = true;
  $('policyExportPath').focus({ preventScroll: true });
  $('policyExportPanel').scrollIntoView({ block: 'nearest' });
});
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
    catch (e) { showMessage($(status), e); }
  });
}

async function transferPolicySource(operation, payload, statusId, resume = false) {
  if (sourceTransferBusy || exportBusy || assessmentBusy || assessmentImporting) return;
  sourceTransferBusy = true;
  syncJobAdmission();
  localizeText($(statusId), () => operation === 'import' ? t("text.reading_and_validating_policy_files") : t("text.writing_policy_json_files"));
  try {
    if (!resume) {
      const started = await post(`/api/policies/${operation}`, payload);
      if (!started.ok) throw new UiError(() => started.body?.error || t("text.could_not_start_policy_transfer"));
    }
    while (true) {
      const r = await api('/api/policies/transfer');
      if (!r.ok || r.body?.status === 'failed') throw new UiError(() => r.body?.error || t("text.policy_transfer_failed"));
      writeText($(statusId), r.body?.phase || 'Working…');
      if (r.body?.status === 'completed') {
        localizeText($(statusId), () => operation === 'export' ? t("text.policy_set_written_to", { v0: r.body.result?.path }) : t("text.policy_set_imported"));
        if (operation === 'import') {
          sourceImportOpen = false;
          clearWorkspace();
          lastRoute = 'home'; window.location.hash = '#/';
        }
        break;
      }
      if (!r.body?.running) throw new UiError(() => t("text.policy_transfer_ended_without_a_completed_result"));
      await waitForLocalJob();
    }
  } finally {
    sourceTransferBusy = false; syncJobAdmission(); await refreshState();
  }
}
$('btnImportPolicySource').addEventListener('click', async () => {
  try {
    const replace = ['ready', 'partial'].includes(state?.policies?.status);
    if (replace && !confirm(t("text.replace_the_active_policy_source_existing_assessment_results_will"))) return;
    const file = $('policyImportZip').files[0];
    let payload;
    if (file) {
      if (!file.size || file.size > 32 * 1024 * 1024 || !/\.zip$/i.test(file.name)) throw new UiError(() => t("text.choose_a_nonempty_policy_zip_at_most_32_mib"));
      payload = { archive: assessmentArchiveBase64(await file.arrayBuffer()), replace };
    } else {
      const path = $('policyImportPath').value.trim();
      if (!path) throw new UiError(() => t("text.choose_a_policy_zip_or_enter_a_host_folder"));
      payload = { path, replace };
    }
    setHidden('policyImportError', true);
    await transferPolicySource('import', payload, 'policyImportStatus');
  } catch (e) { showMessage($('policyImportError'), e); setHidden('policyImportError', false); }
});
$('btnExportPolicySource').addEventListener('click', async () => {
  try {
    if (!policiesReady()) throw new UiError(() => t("text.load_or_import_policies_before_exporting_a_policy_set"));
    await transferPolicySource('export', { path: $('policyExportPath').value.trim() }, 'policyExportStatus');
  } catch (e) { showMessage($('policyExportStatus'), e); }
});

function renderClients() {
  const sel = $('client');
  if (sel.options.length || !state.clients) return;
  state.clients.forEach((c) => {
    const opt = document.createElement('option');
    opt.value = c.key;
    writeText(opt, c.name);
    opt.dataset.note = c.note || '';
    sel.appendChild(opt);
  });
  const setNote = () => {
    const key = sel.value || sel.selectedOptions[0]?.value;
    localizeText($('clientNote'), () => ['graphcli', 'azurecli', 'intuneps'].includes(key)
      ? t(`client.${key}`) : sel.selectedOptions[0]?.dataset.note || '');
  };
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
    label.innerHTML = `<input type="checkbox" value="${escapeHtml(s.key)}" ${s.available === false ? 'disabled' : 'checked'}><span>${escapeHtml(sectionLabel(s.key, s.label))}${s.available === false ? ' ' + h("text.unavailable_offline") : ''}</span>`;
    host.appendChild(label);
  });
}

function renderScopes() {
  const host = $('scopeList');
  host.innerHTML = '';
  (state?.auth?.scopes || []).forEach((scope) => {
    const row = document.createElement('div');
    row.className = 'scope';
    const impact = scopeKeys[scope.scope] ? t(scopeKeys[scope.scope]) : scope.impact;
    row.innerHTML = `<span class="dot ${scope.granted ? 'on' : 'off'}"></span>
      <span><code>${escapeHtml(scope.scope)}</code></span>
      <span class="impact">${escapeHtml(impact)}${scope.granted ? '' : ' — ' + h("text.may_be_incomplete")}</span>`;
    host.appendChild(row);
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
    localizeText(badge, () => auth.account || t("text.connected"));
    badge.className = 'badge badge-on';
    localizeText($('homeGreeting'), () => t("text.welcome") + (auth.account ? ', ' + auth.account : ''));
    localizeText($('homeTenant'), () => auth.tenantId ? (t("text.tenant") + " ") + auth.tenantId : '');
    $('signinPane').classList.add('hidden');
    $('connectedPane').classList.remove('hidden');
    $('cardConfigure').classList.remove('disabled');
    writeText($('cAccount'), auth.account || '—');
    writeText($('cTenant'), auth.tenantId || '—');
    writeText($('cClient'), auth.client || '—');
    localizeText($('cMethod'), () => authMethodLabel(auth.method) || '—');
    if (policiesReady()) checkFolder();

    renderScopes();
  } else {
    localizeText(badge, () => t("text.not_connected"));
    badge.className = 'badge badge-off';
    $('signinPane').classList.remove('hidden');
    $('connectedPane').classList.add('hidden');
    if (policiesReady()) $('cardConfigure').classList.remove('disabled');
    else $('cardConfigure').classList.add('disabled');
  }
  if (state.policies?.source?.kind === 'offline') {
    localizeText($('homeGreeting'), () => t("text.offline_policy_workspace"));
    localizeText($('homeTenant'), () => state.policies.tenant?.name || t("text.environment_name_unavailable"));
  } else if (!policiesReady()) {
    localizeText($('homeGreeting'), () => t("text.welcome"));
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
  localizeText($('bsText'), () => t("text.starting_browser"));

  await post('/api/signin/browser', {
    tenant: $('tenant').value.trim(),
    forcePicker: $('optForcePicker').checked
  });

  const timer = setInterval(async () => {
    const r = await api('/api/signin/browser/status');
    if (!r.body) return;
    if (r.body.status) writeText($('bsText'), r.body.status);
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
  localizeText($('bsText'), () => t("text.saved_browser_session_cleared"));
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
  else { showSigninError(() => t("text.could_not_start_signin")); }
});

$('btnDeviceCode').addEventListener('click', async () => {
  clearAssessment();
  showSigninError(null);
  const { body } = await post('/api/signin/devicecode', {
    tenant: $('tenant').value.trim() || 'organizations',
    client: $('client').value
  });
  if (!body || body.error) { showSigninError(() => body ? body.error : t("text.device_code_request_failed")); return; }

  writeText($('dcUri'), body.verificationUri);
  $('dcUri').href = body.verificationUri;
  writeText($('dcCode'), body.userCode);
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
      showSigninError(() => r.body.message || (() => t(`signin.${r.body.status}`)));
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
  localizeText($('btnMgGraph'), () => t("text.check_the_signin_window"));
  const { body } = await post('/api/signin/mggraph', { tenant: $('tenant').value.trim() });
  $('btnMgGraph').disabled = false;
  localizeText($('btnMgGraph'), () => t("text.use_graph_powershell_session"));
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
    writeText($(id), '');
  });
  $('policyFamilies').innerHTML = '';
  setHidden('policyRefreshError', true);
  exportBusy = false;
  exportStarting = false;
  clearAssessment();
  clearInterval(logTimer);
  logCursor = 0;
  writeText($('log'), '');
  $('summary').innerHTML = '';
  documentSummary = null;
  $('fileList').innerHTML = '';
  localizeText($('preview'), () => t("text.select_a_file_to_preview"));
  $('bar').style.width = '0%';
  writeText($('phase'), '');
  writeText($('pct'), '');
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
    el.innerHTML = escapeHtml(body.conflict) +
      (body.suggestion ? ` <button class="linkbtn" id="btnUseSuggestion">${h("text.use", { v0: body.suggestion })}</button>` : '');
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
  if (!policiesReady()) { alert(t("text.load_policies_before_documenting")); return; }
  if (assessmentBusy || exportBusy) { alert(t("text.an_export_or_assessment_is_already_running")); return; }
  const sections = sectionBoxes().filter((b) => b.checked).map((b) => b.value);
  if (!sections.length) { alert(t("text.select_at_least_one_area_to_document")); return; }

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
    alert(body?.error || t("text.export_request_failed"));
    return;
  }

  logCursor = 0;
  writeText($('log'), '');
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
    writeText(span, `[${e.time}] ${e.message}\n`);
    $('log').appendChild(span);
  });
  if (body.entries && body.entries.length) {
    logCursor = body.total;
    $('log').scrollTop = $('log').scrollHeight;
  }

  $('bar').style.width = (body.percent || 0) + '%';
  writeText($('phase'), body.phase || '');
  writeText($('pct'), body.percent ? `· ${i18n.formatNumber(body.percent / 100, { style: 'percent' })}` : '');

  if (body.done) {
    clearInterval(logTimer);
    exportBusy = false;
    syncJobAdmission();
    $('cardConfigure').classList.remove('disabled');
    setDocumentStep('review');
    if (body.error) {
      localizeText($('phase'), () => t("text.failed"));
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
  documentSummary = s;
  const st = s.stats || {};
  const counts = s.counts || {};
  let html = `<div class="stats">
    <div class="stat"><b>${number(st.created)}</b><span>${h("text.created")}</span></div>
    <div class="stat"><b>${number(st.updated)}</b><span>${h("text.updated")}</span></div>
    <div class="stat"><b>${number(st.unchanged)}</b><span>${h("text.unchanged")}</span></div>
    <div class="stat"><b>${number(st.deleted)}</b><span>${h("text.removed")}</span></div>
  </div>`;

  html += `<p class="muted">${h("text.output")} <code>${escapeHtml(s.root)}</code></p>`;

  html += `<table class="counts">`;
  Object.keys(counts).forEach((k) => {
    html += `<tr><td>${escapeHtml(k)}</td><td>${typeof counts[k] === 'number' ? number(counts[k]) : escapeHtml(counts[k])}</td></tr>`;
  });
  html += '</table>';

  if (s.git) {
    html += s.git.committed
      ? `<p class="muted">${h("text.committed")} <code>${escapeHtml(s.git.message)}</code></p>`
      : `<p class="muted">${h("text.no_configuration_changes_since_the_last_export_mdash_nothing")}</p>`;
    if (s.git.pushed) html += `<p class="muted">${h("text.successfully_pushed_to_remote")}</p>`;
  }
  if (s.warnings && s.warnings.length) {
    html += `<h4 class="section-label">${h("text.warnings")}</h4><ul class="muted">` + s.warnings.map((w) => `<li>${escapeHtml(w)}</li>`).join('') + '</ul>';
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
    writeText(btn, f.path);
    btn.addEventListener('click', async () => {
      Array.from(host.children).forEach((c) => c.classList.remove('active'));
      btn.classList.add('active');
      const r = await api('/api/file?path=' + encodeURIComponent(f.path));
      if (generation !== workspaceGeneration) return;
      localizeText($('preview'), () => r.body && r.body.content ? r.body.content : t("text.unable_to_read_file"));
      $('preview').scrollTop = 0;
    });
    host.appendChild(btn);
  });
}

$('btnOpen').addEventListener('click', () => post('/api/open'));

$('btnQuit').addEventListener('click', async () => {
  if (exportBusy || assessmentBusy) {
    alert(t("text.an_export_or_assessment_is_still_running_wait_for"));
    return;
  }
  if (!confirm(t("text.stop_the_intune_docs_studio_server"))) return;
  try {
    const r = await post('/api/quit');
    if (!r.ok || r.body?.error) { alert(r.body?.error || t("text.the_server_could_not_stop")); return; }
  } catch (e) { /* the server goes away mid-request */ }
  clearInterval(logTimer);
  clearInterval(deviceTimer);
  clearAssessment();
  document.body.innerHTML =
    `<main class="stopped"><span class="mark" aria-hidden="true"></span>` +
    `<h2>${h("text.intune_docs_studio_has_stopped")}</h2>` +
    `<p>${h("text.you_can_close_this_tab_run")} <code>Start-IntuneDocs.cmd</code> ${h("text.to_start_it_again")}</p></main>`;
});
$('btnAgain').addEventListener('click', () => {
  $('cardResult').classList.add('hidden');
  $('cardRun').classList.add('hidden');
  setDocumentStep('configure');
  $('cardConfigure').scrollIntoView({ behavior: 'smooth' });
});

// --- Assessment ------------------------------------------------------------

const assessmentStatuses = {
  get aligned() { return t("text.aligned"); }, get misaligned() { return t("text.misaligned"); }, get missing() { return t("text.missing"); },
  get potentialConflict() { return t("text.potential_conflict"); }, get notApplicable() { return t("text.not_applicable"); }, get notAssessed() { return t("text.not_assessed"); }
};
const assessmentLimits = () => t("text.configuration_alignment_only_not_device_compliance_or_certification_missing");
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
const assessmentValue = (value) => typeof value === 'string' ? value : JSON.stringify(value);
const assessmentPercent = (value) => value == null ? t("text.not_available") :
  i18n.formatNumber(Number(value) / 100, { style: 'percent', maximumFractionDigits: 2 });

function renderAssessmentPacks(catalog) {
  const selected = new Set(assessmentPackBoxes().filter((b) => b.checked).map((b) => b.value));
  const platforms = new Set(assessmentPlatformBoxes().filter((b) => b.checked).map((b) => b.value));
  assessmentPacks = catalog.packs || [];
  assessmentCatalogIssues = catalog.errors || [];
  localizeText($('assessmentCatalogNote'), () => t("text.cis_content_is_never_bundled_or_downloaded_import_your"));
  writeText($('assessmentCatalogErrors'), assessmentCatalogIssues.map((e) => `${e.origin}: ${e.reason}`).join('\n'));
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
    localizeText(text, () => name + (available ? '' : (" " + t("text.no_library_packs_yet_import_after_next"))));
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
    localizeText(option, () => pack
      ? `${pack.profile} — ${pack.framework} / ${pack.frameworkVersion || pack.id} (${pack.id}) · ${pack.origin === 'imported' ? t("text.imported") : t("text.bundled")} · ${pack.version}`
      : t("text.all_available_profiles_select_packs_below"));
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
    box.setAttribute('aria-label', t("text.select_version", { v0: p.framework, v1: p.profile, v2: p.id, v3: p.version }));
    box.checked = selected.has(box.value);
    box.addEventListener('change', updateAssessmentSelection);
    const text = document.createElement('span');
    const classification = p.origin === 'imported'
      ? t("text.customerimported_local_pack_authordeclared", { v0: p.framework, v1: classificationLabel(p.classification) })
      : p.origin !== 'bundled' ? t("text.unverified_origin_authordeclared", { v0: p.framework, v1: classificationLabel(p.classification) })
      : p.framework === 'Microsoft' ? (p.classification === 'baseline'
        ? t("text.official_microsoft_security_baseline_partial_mapped_checks") : t("text.microsoft_recommendations"))
        : t("text.local_rule_pack", { v0: p.framework });
    text.innerHTML = `<strong>${escapeHtml(p.framework)} · ${escapeHtml(p.profile)}</strong>
      <small>${h("text.version", { v2: assessmentPlatforms[p.platform], v3: p.frameworkVersion, v4: p.version })}</small>
      <span class="badge">${p.origin === 'imported' ? t("text.imported") : t("text.bundled")}</span>
      <small>${escapeHtml(classification)}</small>
      <small>${h("text.inventory_source_total", { v7: inventoryLabel(p.coverage?.inventory), v8: p.coverage?.totalSourceControls ?? t("text.unknown") })}</small>
      <details class="pack-technical"><summary>${h("text.identity_and_source_details")}</summary>
        <p>${escapeHtml(p.id)}</p><p>${escapeHtml(p.sourceRevision)}</p>
        <pre>${assessmentText(p.sources || [])}</pre><p>SHA-256: ${escapeHtml(p.sha256)}</p></details>`;
    label.appendChild(box);
    label.appendChild(text);
    if (p.origin === 'imported') {
      const remove = document.createElement('button');
      remove.className = 'btn ghost small pack-remove';
      remove.innerHTML = `<svg class="icon" viewBox="0 0 24 24" aria-hidden="true"><path d="M3 6h18M9 6V3h6v3M5 6l1 15h12l1-15M10 10v7M14 10v7"/></svg>`;
      remove.setAttribute('aria-label', t("text.remove_imported_pack_from_the_local_library", { v0: p.id }));
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
  localizeText($('assessmentPacksEmpty'), () => enabled ? '' : (t("text.no_rule_pack_matches_the_selected_platforms_and_profile") + " ") +
    t("text.choose_other_platforms_or_a_different_profile_or_import"));
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
let assessmentCurrentStep = 'platforms';
function syncAssessmentStepNavigation() {
  const order = Object.keys(assessmentSteps);
  const busy = exportBusy || assessmentBusy || assessmentImporting || sourceTransferBusy || !!state?.transfer?.running;
  order.forEach((name, i) => {
    $(assessmentSteps[name][0].replace('assessStep', 'btnAssessStep')).disabled =
      busy || i >= order.indexOf(assessmentCurrentStep);
  });
}
Object.entries(assessmentSteps).forEach(([name, [item]]) => {
  const button = item.replace('assessStep', 'btnAssessStep');
  $(button).addEventListener('click', () => {
    if (!$(button).disabled) moveAssessmentStep(name);
  });
});
const assessmentContextFields = {
  windows11: ['assessmentContextWindows11'],
  macos: ['assessmentContextMacos'],
  iosIpados: ['assessmentContextIosIpados', 'assessmentContextIosOwnership'],
  androidEnterprise: ['assessmentContextAndroidEnterprise', 'assessmentContextEnrollment']
};
// These mirror the <option> labels in index.html; the review must not depend on selectedIndex.
const assessmentEnrollmentLabels = {
  get workProfile() { return t("text.personallyowned_work_profile"); }, get fullyManaged() { return t("text.fully_managed"); }, get dedicated() { return t("text.dedicated"); },
  get corporateOwnedWorkProfile() { return t("text.corporateowned_work_profile"); }
};
const assessmentOwnershipLabels = {
  get personallyOwned() { return t("text.personally_owned"); }, get corporateOwned() { return t("text.corporate_owned_excluded_by_personalonly_guidance"); }
};
const assessmentWindowsWarning = () => t("text.windows_policies_targeting_windows_10_and_later_such_as");

function setAssessmentStep(step, focus) {
  assessmentCurrentStep = step;
  const order = Object.keys(assessmentSteps);
  const current = order.indexOf(step);
  order.forEach((name, i) => {
    const [item, panel] = assessmentSteps[name];
    $(item).className = i < current ? 'done' : i === current ? 'active' : '';
    if (i === current) $(item).setAttribute('aria-current', 'step');
    else $(item).removeAttribute('aria-current');
    setHidden(panel, i !== current);
  });
  syncAssessmentStepNavigation();
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
    return () => t("text.every_selected_platform_requires_a_selected_applicable_pack_choose");
  }
  return !packs.length || packs.length > 64 ? () => t("text.select_164_packs") : null;
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
  localizeText($('assessmentContextWarning'), () => warn ? assessmentWindowsWarning() : '');
  setHidden('assessmentContextWarning', !warn);
}

function renderAssessmentReview() {
  const { platforms, packs } = assessmentSelection();
  const context = platforms.map((p) => {
    let line = t("text.os_version", { v0: assessmentPlatforms[p], v1: $(assessmentOsId(p)).value.trim() || t("text.unknown") });
    if (p === 'iosIpados') {
      line += (t("text.ownership_scope") + " ") + (assessmentOwnershipLabels[$('assessmentIosOwnership').value] || t("text.unknown"));
    }
    if (p === 'androidEnterprise') {
      line += (t("text.enrollment_mode") + " ") + (assessmentEnrollmentLabels[$('assessmentEnrollment').value] || t("text.unknown"));
    }
    const selected = packs.filter((pack) => pack.platform === p);
    return `<article class="review-platform"><h4>${escapeHtml(assessmentPlatforms[p])}</h4>
      <p>${escapeHtml(line)}</p><ul>${selected.map((pack) => `<li><strong>${escapeHtml(pack.framework)}${pack.frameworkVersion ? ' · ' + escapeHtml(pack.frameworkVersion) : ''} · ${escapeHtml(pack.profile)}</strong>
        <span>${h("text.version_inventory", { v3: pack.id, v4: pack.version, v5: pack.origin === 'imported' ? t("text.imported") : t("text.bundled"), v6: inventoryLabel(pack.coverage?.inventory) })}</span></li>`).join('')}</ul></article>`;
  });
  const source = state?.policies;
  $('assessmentReview').innerHTML = `<div class="notice"><strong>${h("text.target_policy_source")}</strong>
    <p>${h("text.collected", { v0: source?.source?.kind === 'offline' ? t("text.offline_import") : t("text.live_snapshot"), v1: source?.tenant?.name || source?.tenant?.id || t("text.environment_name_unavailable"), v2: i18n.formatDate(source?.capturedAt), v3: source?.source?.importedAt ? (" " + t("text.imported_90") + " ") + i18n.formatDate(source.source.importedAt) : '' })}</p>
    <p>${escapeHtml(countPolicies(Number(source?.count) || 0))} · ${source?.status === 'partial' ? h("text.incomplete_evidence_some_checks_may_remain_not_assessed") : h("text.loaded_snapshot")}</p></div>
    <p class="muted">${h("text.each_platform_below_connects_the_selected_packs_to_your")}</p>
    ${context.join('')}${platforms.includes('windows11') && !$('assessmentOsWindows11').value.trim()
      ? `<p class="notice">${escapeHtml(assessmentWindowsWarning())}</p>` : ''}`;
}

function blockAssessmentStep(message) {
  showAssessmentError(message);
  $('assessmentError').scrollIntoView({ block: 'nearest' });
}

function moveAssessmentStep(step) {
  if (exportBusy || assessmentBusy || assessmentImporting || sourceTransferBusy || state?.transfer?.running) return;
  showAssessmentError(null);
  if (step === 'context') updateAssessmentContext();
  if (step === 'review') renderAssessmentReview();
  setAssessmentStep(step, true);
}

$('btnAssessmentSelectAll').addEventListener('click', () => selectAssessmentPacks(true));
$('btnAssessmentSelectNone').addEventListener('click', () => selectAssessmentPacks(false));
$('assessmentOsWindows11').addEventListener('input', updateAssessmentContext);
$('btnAssessPlatformsNext').addEventListener('click', () => {
  if (!assessmentSelection().platforms.length) blockAssessmentStep(() => t("text.choose_at_least_one_platform_to_assess"));
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
  showMessage($('assessmentError'), message);
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
  ['btnImportPolicySource', 'btnReplacePolicySource', 'btnOpenPolicyImport', 'btnExportPolicySource', 'btnShowPolicyExport'].forEach((id) => {
    $(id).disabled = busy || assessmentImporting || (['btnExportPolicySource', 'btnShowPolicyExport'].includes(id) && !policiesReady());
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
  syncAssessmentStepNavigation();
}

function clearAssessmentEvidence() {
  assessmentResult = null;
  ['assessmentResults', 'assessmentSummary', 'assessmentPolicies'].forEach((id) => { $(id).innerHTML = ''; });
  ['assessmentReportPaths', 'assessmentContextResult', 'assessmentPackResult', 'assessmentIssues',
    'assessmentProgress'].forEach((id) => { writeText($(id), ''); });
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
  ['assessmentImportSummary', 'assessmentReview', 'assessmentContextWarning'].forEach((id) => { writeText($(id), ''); });
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
  showAssessmentError(() => t("text.401_session_expired_sign_in_again_before_assessing_policies"));
  showSigninError(() => t("text.your_session_ended_sign_in_again_to_continue"));
  return true;
}

async function loadAssessmentCatalog() {
  const generation = assessmentGeneration;
  const request = ++assessmentCatalogRequest;
  try {
    const r = await api('/api/assessment/packs');
    if (generation !== assessmentGeneration || request !== assessmentCatalogRequest) return;
    if (!r.ok) throw new UiError(() => `${r.status}: ${r.body?.error || t("text.catalog_unavailable")}`);
    if (Array.isArray(r.body?.packs)) renderAssessmentPacks(r.body);
  } catch (e) {
    if (generation === assessmentGeneration && request === assessmentCatalogRequest) showAssessmentError(e);
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
      showAssessmentError(() => t("text.assessment_session_reset_select_context_and_destination_again"));
      return;
    }
    if (!r.ok || !r.body) throw new UiError(() => `${r.status}: ${r.body?.error || t("text.progress_unavailable")}`);
    const progress = r.body;
    if (progress.running && (assessmentResult || $('assessmentReportPaths').textContent)) clearAssessmentEvidence();
    assessmentBusy = assessmentStarting || !!progress.running;
    const percent = Math.max(0, Math.min(100, Number(progress.percent) || 0));
    $('assessmentBar').style.width = percent + '%';
    localizeText($('assessmentProgress'), () => `${i18n.formatNumber(percent / 100, { style: 'percent' })} · ${progress.phase || t("text.ready")}` +
      (progress.partial ? (" " + t("text.partial_evidence_review_collection_limitations")) : ''));
    if (progress.running) startAssessmentPolling();
    else { clearInterval(assessmentTimer); assessmentTimer = null; }
    if (progress.error) {
      clearAssessmentEvidence();
      throw new Error(progress.error);
    }
    if (progress.running) setAssessmentStep('results');
    if (progress.done) {
      const firstResult = !assessmentResult;
      clearAssessmentEvidence();
      const results = await api('/api/assessment/results');
      if (generation !== assessmentGeneration) return;
      if (assessmentSessionFailure(results)) return;
      if (results.status === 404) {
        clearAssessment();
        showAssessmentError(() => t("text.assessment_results_reset_run_a_new_assessment"));
        return;
      }
      if (!results.ok || !results.body) throw new UiError(() => `${results.status}: ${results.body?.error || t("text.results_unavailable")}`);
      renderAssessmentResult(results.body);
      if (firstResult) setAssessmentStep('results');
      $('assessmentBar').style.width = percent + '%';
      localizeText($('assessmentProgress'), () => `${i18n.formatNumber(percent / 100, { style: 'percent' })} · ${progress.phase || t("text.complete")}` +
        (progress.partial ? (" " + t("text.partial_evidence_review_collection_limitations")) : ''));
      const paths = progress.reportPaths;
      writeText($('assessmentReportPaths'), paths?.markdownPath && paths?.jsonPath
        ? `Markdown: ${paths.markdownPath}\nJSON: ${paths.jsonPath}` : '');
    } else if (!assessmentStarting && !progress.running && (assessmentResult || $('assessmentReportPaths').textContent)) {
      clearAssessment();
    }
    showAssessmentError(null);
  } catch (e) {
    if (generation === assessmentGeneration) showAssessmentError(e);
  } finally {
    if (generation === assessmentGeneration) { assessmentPolling = false; syncJobAdmission(); }
  }
}

$('btnAssessmentRun').addEventListener('click', async () => {
  if (assessmentImporting) { showAssessmentError(() => t("text.wait_for_the_pack_import_to_finish")); return; }
  if (assessmentBusy || exportBusy) { showAssessmentError(() => t("text.an_export_or_assessment_is_already_running")); return; }
  if (!state?.auth?.connected && state?.policies?.source?.kind !== 'offline') {
    showAssessmentError(() => t("text.sign_in_or_import_a_policy_set_before_assessing")); return;
  }
  if (!policiesReady()) { showAssessmentError(() => t("text.load_policies_before_assessing")); return; }
  const { platforms, packs: selectedPacks } = assessmentSelection();
  if (!platforms.length || platforms.some((p) => !selectedPacks.some((pack) => pack.platform === p))) {
    showAssessmentError(() => t("text.every_selected_platform_requires_a_selected_applicable_pack_choose"));
    return;
  }
  if (!selectedPacks.length || selectedPacks.length > 64 || !$('assessmentOutputPath').value.trim()) {
    showAssessmentError(() => t("text.select_164_packs_and_an_absolute_assessment_report_destination"));
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
    if (r.status !== 202 || !r.body?.started) {
      throw new UiError(() => r.status === 400
        ? r.body?.error || t("text.check_the_selected_report_folder_and_context_before_trying")
        : `${r.status}: ${r.body?.error || t("text.assessment_did_not_start")}`);
    }
    clearAssessmentEvidence();
    localizeText($('assessmentProgress'), () => t("text.assessment_admitted_collecting_policy_evidence"));
    setAssessmentStep('results', true);
    startAssessmentPolling();
    await refreshAssessment();
  } catch (e) {
    if (generation === assessmentGeneration) {
      assessmentStarting = false;
      assessmentBusy = false;
      showAssessmentError(e);
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
    lines.push(t("text.skipped_archive", { v0: total,  }));
    skipped.slice(0, 10).forEach((s) => lines.push(`${s.entry}: ${s.reason}`));
    const shown = Math.min(skipped.length, 10);
    if (total > shown) lines.push(t("text.and_more", { v0: total - shown }));
  }
  if (body?.ignored > 0) {
    lines.push(t("text.other_ignored_not_json", { v0: body.ignored,  }));
  }
  return lines;
}

function assessmentImportReport(body, packs) {
  const lines = [t("text.imported_rule_locally", { v0: packs.length,  }) +
    t("text.select_the_platforms_and_packs_to_assess_imports_are")];
  if (typeof body.added === 'number') lines.push(t("text.new_already_present", { v0: body.added, v1: packs.length - body.added }));
  packs.forEach((p) => {
    let line = `${p.id} @ ${p.version} — ${assessmentPlatforms[p.platform]} · ${p.profile}`;
    if (typeof p.controlCount === 'number') {
      line += ' · ' + countControls(p.controlCount);
    }
    if (typeof p.added === 'boolean') line += p.added ? (" " + t("text.new")) : (" " + t("text.already_present_58"));
    lines.push(line);
  });
  return [...lines, ...assessmentSkippedLines(body)].join('\n');
}

function renderAssessmentImportQueue(updateStatus = true) {
  const host = $('assessmentImportQueue');
  host.innerHTML = '';
  assessmentImportQueue.forEach((item) => {
    const row = document.createElement('div');
    row.className = 'import-queue-row';
    const text = document.createElement('div');
    text.innerHTML = `<strong>${escapeHtml(item.name)}</strong><small>${escapeHtml(item.kind === 'reference'
      ? t("text.custom_reference_policy_set") : t("text.schema1_packs_licensed_cis_zip"))} · ${item.path ? t("text.host_folder") : t("text.file")} · ${escapeHtml(queueStatus(item.status))}</small>
      ${item.status === 'importing' ? `<span class="spinner" aria-hidden="true"></span>` : ''}`;
    const remove = document.createElement('button');
    remove.className = 'btn ghost small';
    remove.disabled = assessmentImporting || assessmentBusy || exportBusy;
    remove.setAttribute('aria-label', t("text.remove_from_the_import_queue_only", { v0: item.name }));
    remove.innerHTML = `<svg class="icon" viewBox="0 0 24 24" aria-hidden="true"><path d="M3 6h18M9 6V3h6v3M5 6l1 15h12l1-15M10 10v7M14 10v7"/></svg>`;
    remove.addEventListener('click', () => {
      if (assessmentImporting) return;
      assessmentImportQueue = assessmentImportQueue.filter((candidate) => candidate.id !== item.id);
      renderAssessmentImportQueue();
    });
    row.appendChild(text); row.appendChild(remove); host.appendChild(row);
  });
  if (updateStatus) localizeText($('assessmentQueueStatus'), () => assessmentImporting
    ? t("text.importing_the_highlighted_item_completed_independent_items_remain_in")
    : t("text.queued_items_removing_a_queue_item_does_not_remove", { v0: assessmentImportQueue.length }));
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
  if (!path) { showAssessmentError(() => t("text.enter_an_absolute_host_folder_path_first")); return; }
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
  } catch (e) { showAssessmentError(e); }
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
      <h4>${escapeHtml(item.name)} · ${escapeHtml(queueStatus(item.status))}</h4>
      ${result.error ? `<p>${escapeHtml(item.errorMessage ? item.errorMessage() : result.error)}</p>` : ''}
      <ul>${packs.map((pack) => `<li><strong>${escapeHtml(pack.framework)}${pack.frameworkVersion ? ' · ' + escapeHtml(pack.frameworkVersion) : ''} · ${escapeHtml(pack.profile)}</strong>
        <span>${escapeHtml(assessmentPlatforms[pack.platform])} · ${escapeHtml(pack.id)} · ${escapeHtml(pack.version)}
        ${pack.controlCount == null ? '' : ' · ' + escapeHtml(countControls(pack.controlCount))}
        · ${pack.added === false ? t("text.already_present") : t("text.imported")}</span></li>`).join('')}</ul>
      ${(result.skipped || []).length ? `<details><summary>${h("text.skipped_entries_and_reasons", { v0: Number(result.skippedCount) || result.skipped.length })}</summary>
        <ul>${result.skipped.map((entry) => `<li>${escapeHtml(entry.entry)}: ${escapeHtml(entry.reason)}</li>`).join('')}</ul>
        ${result.skippedCount > result.skipped.length ? `<p>${h("text.additional_reasons_not_returned_by_the_server", { v0: result.skippedCount - result.skipped.length })}</p>` : ''}</details>` : ''}
      ${result.ignored ? `<p>${h("text.nonjson_files_ignored", { v0: Number(result.ignored) })}</p>` : ''}</article>`;
  });
  $('assessmentImportSummary').innerHTML = items.length
    ? `<div class="import-totals"><span><b>${number(added)}</b> ${h("text.added")}</span><span><b>${number(present)}</b> ${h("text.already_present")}</span>
      <span><b>${number(skipped)}</b> ${h("text.skipped")}</span><span><b>${number(ignored)}</b> ${h("text.ignored_files")}</span><span><b>${number(failed)}</b> ${h("text.failed_items")}</span></div>
      <p class="muted">${h("text.select_exact_packs_on_the_next_step_imports_are")}</p>${details.join('')}` : '';
}

async function removeAssessmentPack(pack) {
  if (assessmentImporting || assessmentBusy || exportBusy || sourceTransferBusy || pack.origin !== 'imported') return;
  if (!confirm(t("text.remove_version_from_the_local_library_saved_reports_remain", { v0: pack.id, v1: pack.version }))) return;
  const r = await post('/api/assessment/packs/remove', { selectionId: assessmentIdentity(pack), confirm: true });
  if (!r.ok) { showAssessmentError(() => r.body?.error || t("text.could_not_remove_the_imported_pack")); return; }
  await loadAssessmentCatalog();
}

$('btnAssessmentImport').addEventListener('click', async () => {
  if (assessmentImporting || assessmentBusy || exportBusy) return;
  if (!assessmentImportQueue.length) queueAssessmentFiles();
  const pending = assessmentImportQueue.filter((item) => ['queued', 'failed'].includes(item.status));
  if (!pending.length) { showAssessmentError(() => t("text.add_files_or_a_host_folder_to_the_queue")); return; }
  const generation = assessmentGeneration;
  assessmentCatalogRequest++;
  assessmentImporting = true;
  syncJobAdmission();
  showAssessmentError(null);
  renderAssessmentImportQueue();
  for (const item of pending) {
    item.status = 'importing'; item.result = null; item.errorMessage = null; renderAssessmentImportQueue();
    try {
    const file = item.file;
    let payload;
    if (item.path) {
      payload = { path: item.path, kind: item.kind };
    } else if (file && /\.zip$/i.test(file.name)) {
      if (!file.size || file.size > 32 * 1024 * 1024) throw new UiError(() => t("text.choose_a_nonempty_zip_archive_at_most_32_mib"));
      const buffer = await file.arrayBuffer();
      if (generation !== assessmentGeneration) return;
      payload = { archive: assessmentArchiveBase64(buffer), ...(item.kind === 'reference' ? { kind: 'reference' } : {}) };
    } else if (file && /\.json$/i.test(file.name)) {
      if (!file.size || file.size > 10 * 1024 * 1024) throw new UiError(() => t("text.choose_a_nonempty_json_rule_pack_at_most_10"));
      const content = await file.text();
      if (generation !== assessmentGeneration) return;
      if (new TextEncoder().encode(content).length > 10 * 1024 * 1024) {
        throw new UiError(() => t("text.decoded_utf8_pack_exceeds_10_mib"));
      }
      if (item.kind === 'reference') throw new UiError(() => t("text.a_reference_policy_set_must_be_a_complete_policy"));
      payload = { content };
    } else {
      throw new UiError(() => t("text.choose_a_json_rule_pack_at_most_10_mib"));
    }
    const r = await post('/api/assessment/packs', payload);
    if (generation !== assessmentGeneration) return;
    if (assessmentSessionFailure(r)) return;
    const imported = Array.isArray(r.body?.packs) ? r.body.packs : r.body?.pack ? [r.body.pack] : null;
    item.result = r.body || {};
    if (!r.ok || !imported) {
      throw new UiError(() => `${r.status}: ${r.body?.error || t("text.pack_import_failed")}`);
    }
    assessmentCatalogRequest++;
    const identities = new Set(imported.map(assessmentIdentity));
    const packs = assessmentPacks.filter((p) => !identities.has(assessmentIdentity(p)));
    renderAssessmentPacks({ packs: [...packs, ...imported], errors: assessmentCatalogIssues });
    item.status = 'completed';
  } catch (e) {
    if (generation !== assessmentGeneration) return;
    item.status = 'failed'; item.result = { ...(item.result || {}), error: e.message };
    item.errorMessage = e instanceof UiError ? e.render : null;
    showAssessmentError(e);
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
  return `<p class="muted">${escapeHtml(policy.settingsNote || t("text.readable_settings_are_unavailable_for_this_saved_result_see"))}</p>${tables}`;
}

function renderAssessmentTypedValues(records, expected) {
  if (!Array.isArray(records)) return assessmentText(records);
  if (!records.length) return t("text.no_mapped_values");
  return records.map((record) => {
    const name = record.displayName || record.property || record.settingId || t("text.unmapped_setting");
    const raw = expected ? record.expected : record.value;
    const value = record.displayValue ?? (!expected && (record.secret === true || record.supported === false)
      ? t("text.unavailable_secret_or_unsupported_evidence") : JSON.stringify(raw));
    return `<p><strong>${escapeHtml(name)}</strong>: ${expected ? escapeHtml(record.operator || '') + ' ' : ''}${escapeHtml(value)}</p>`;
  }).join('');
}

function renderAssessmentResult(result) {
  assessmentResult = result;
  localizeText($('assessmentLimitations'), () => assessmentLimits());
  $('assessmentSummary').innerHTML = (result.summaries || []).map((s) => `
    <div class="assessment-pack">
      <strong>${escapeHtml(s.packId)} · ${escapeHtml(assessmentPlatforms[s.platform] || s.platform)} · ${escapeHtml(s.profile)}</strong>
      <p>${h("text.inventory_listed_controls_only", { v3: inventoryLabel(s.inventory) })}</p>
      <p>${h("text.assessment_coverage_assessed_applicable_or_unknown_listed_controls_configuration", { v4: assessmentPercent(s.coveragePercent), v5: s.assessed, v6: s.coverageDenominator, v7: assessmentPercent(s.alignmentPercent) })}</p>
      <p>${Object.entries(assessmentStatuses).map(([key, label]) =>
        `${label}: ${number((s.counts || {})[key])}`).join(' · ')}</p>
    </div>`).join('');
  localizeText($('assessmentContextResult'), () => (t("text.userselected_context") + " ") + JSON.stringify(result.context || {}));
  localizeText($('assessmentPackResult'), () => (t("text.assessed_pack_identities_sources_and_coverage") + " ") + JSON.stringify(result.packs || []));
  localizeText($('assessmentIssues'), () => (t("text.collection_completeness_and_limitations") + " ") +
    JSON.stringify({ sources: result.sources || [], issues: result.collectionIssues || [] }));
  $('assessmentPolicies').innerHTML = (result.policies || []).map((p) => `
    <div class="assessment-pack"><strong>${escapeHtml(p.name || p.key)}</strong>
      <p>${p.assignmentsComplete !== true ? t("text.assignment_evidence_incomplete_19")
        : !(p.assignments || []).length ? t("text.unassigned") : t("text.assignment_targets_present_effective_targeting_not_resolved")}</p>
      ${renderAssessmentPolicySettings(p)}
      <details><summary>${h("text.technical_policy_and_assignment_evidence")}</summary>
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
        const assignment = (p.assigned === false ? t("text.unassigned") : p.assigned === true ? t("text.assigned") : t("text.assignment_unknown")) +
          (incomplete ? (" " + t("text.assignment_evidence_incomplete")) : '');
        return `<div class="assessment-policy"><strong>${escapeHtml(policy.name || p.policyKey)}</strong>
          <p>${escapeHtml(p.policyKey)} · ${escapeHtml(policy.family)} · ${escapeHtml(policy.policyType)}</p>
          <p>${escapeHtml(assessmentStatuses[p.status] || p.status)}: ${escapeHtml(p.displayReason ?? p.reason)}</p>
          <p>${assignment}</p>
          <details><summary>${h("text.readable_policy_settings")}</summary>${renderAssessmentPolicySettings(policy)}</details>
          <details><summary>${h("text.exact_mappings_and_assignment_evidence")}</summary>
            <pre>${assessmentText(policy.assignments || [])}</pre>
            <p>${h("text.expected_12", { v9: assessmentValue(p.expected || []) })}</p>
            <p>${h("text.configured_13", { v10: assessmentValue(p.observed || []) })}</p>
          </details></div>`;
      }).join('');
      return `<tr><td><strong>${escapeHtml(c.controlId)} ${escapeHtml(c.title)}</strong>
        <p>${escapeHtml(c.packId)} @ ${escapeHtml(c.packVersion)} · ${escapeHtml(assessmentPlatforms[c.platform] || c.platform)} · ${escapeHtml(c.profile)}</p>
        <details><summary>${h("text.framework_references")}</summary><pre>${assessmentText(c.references || [])}</pre></details></td>
        <td><strong>${escapeHtml(assessmentStatuses[c.status] || c.status)}</strong><p>${escapeHtml(c.displayReason ?? c.reason)}</p></td>
        <td><strong>${h("text.expected")}</strong>${renderAssessmentTypedValues(c.expected, true)}
          <strong>${h("text.configured")}</strong>${renderAssessmentTypedValues(c.observed || [], false)}
          <details><summary>${h("text.exact_typed_evidence")}</summary>
            <p>${h("text.expected_8", { v11: assessmentValue(c.expected) })}</p><p>${h("text.configured_9", { v12: assessmentValue(c.observed || []) })}</p>
          </details></td>
        <td>${evidence || t("text.no_policy_evidence")}</td></tr>`;
    }).join('');
}

$('assessmentStatusFilter').addEventListener('change', renderAssessmentEvidence);

function renderLocale() {
  // Only presentation is refreshed. Never re-enter boot, collection, authentication or job polling.
  for (const [element, binding] of [...textBindings]) {
    if (element.textContent === binding.value) localizeText(element, binding.render);
    else textBindings.delete(element); // A later server/customer message owns this element now.
  }
  if (state) {
    renderPolicyState(false);
    renderScopes();
    for (const label of $('sections').children) {
      const box = label.querySelector('input');
      const text = label.querySelector('span');
      const section = state.sections?.find(item => item.key === box?.value);
      if (text && section) writeText(text, sectionLabel(section.key, section.label) +
        (section.available === false ? ' ' + t('text.unavailable_offline') : ''));
    }
    const clientKey = $('client').value;
    if (['graphcli', 'azurecli', 'intuneps'].includes(clientKey)) writeText($('clientNote'), t(`client.${clientKey}`));
  }
  const details = Array.from(document.querySelectorAll('#assessmentPacks details')).map(item => item.open);
  if (assessmentPacks.length) renderAssessmentPacks({ packs: assessmentPacks, errors: assessmentCatalogIssues });
  Array.from(document.querySelectorAll('#assessmentPacks details')).forEach((item, index) => { item.open = details[index]; });
  renderAssessmentImportQueue(false);
  renderAssessmentImportSummary();
  if ($('assessmentReview').innerHTML) renderAssessmentReview();
  if (assessmentResult) renderAssessmentResult(assessmentResult);
  if (documentSummary) renderSummary(documentSummary);
}
i18n.subscribe(renderLocale);

// --- Boot ------------------------------------------------------------------

async function loadInitialState() {
  localizeText($('loadingText'), () => t("text.connecting_to_the_local_server"));
  setHidden('loadingSpinner', false);
  setHidden('btnRetryState', true);
  try { await refreshState(); } catch (e) { /* reported below */ }
  if (state) return true;
  renderRoute();
  localizeText($('loadingText'), () => t("text.the_local_server_is_not_responding_restart_intune_docs"));
  setHidden('loadingSpinner', true);
  setHidden('btnRetryState', false);
  return false;
}

async function start() {
  if (booting) return;
  booting = true;
  try {
    await i18n.ready;
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

(async function init() {
  await i18n.ready;
  const params = new URLSearchParams(window.location.search);
  if (params.has('signin')) {
    window.history.replaceState({}, '', '/' + (window.location.hash || ''));
    if (params.get('signin') === 'state-mismatch') {
      showSigninError(() => t("text.signin_could_not_be_verified_state_mismatch_please_try"));
    }
  }
  setDocumentStep('configure');
  setAssessmentStep('platforms');
  start();
})();
