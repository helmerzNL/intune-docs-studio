'use strict';

const { test } = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');
const { installI18n, withoutTranslationSpans } = require('./i18n-test-helpers');
require('./localization-ui.cases');

const webRoot = path.join(__dirname, '..', 'web');
const html = withoutTranslationSpans(fs.readFileSync(path.join(webRoot, 'index.html'), 'utf8'));
const script = fs.readFileSync(path.join(webRoot, 'app.js'), 'utf8');
const css = fs.readFileSync(path.join(webRoot, 'style.css'), 'utf8');
const build = { version: '0.1.0', channel: 'beta', commit: 'development' };
const signedIn = (extra = {}) => ({
  build,
  policies: { status: 'ready', count: 0, families: [], issues: [] },
  auth: { connected: true, account: 'admin@contoso.example', tenantId: '00000000-0000-0000-0000-000000000001',
    client: 'synthetic', method: 'portal', scopes: [] },
  ...extra
});
const signedOut = (extra = {}) => ({ build, auth: { connected: false }, ...extra });
const viewIds = ['viewLoading', 'viewLanding', 'viewImport', 'viewPolicies', 'viewHome', 'viewDocument', 'viewAssess', 'viewSettings'];
const requestedIds = new Set();

function shell({ hash = '', search = '', respond = () => ({}), seed = () => {}, locale = {} } = {}) {
  const elements = new Map();
  const requests = [];
  const listeners = {};
  const history = [];
  const alerts = [];
  const timeouts = [];
  let focused = null;
  function element(id) {
    if (!elements.has(id)) {
      const classes = new Set();
      const attributes = new Map();
      const el = {
        id, value: '', checked: false, disabled: false, open: false, className: '', children: [], options: [],
        handlers: {}, files: [], textContent: '', style: {}, dataset: {},
        classList: { add(name) { classes.add(name); }, remove(name) { classes.delete(name); },
          contains(name) { return classes.has(name); } },
        setAttribute(name, value) { attributes.set(name, String(value)); },
        getAttribute(name) { return attributes.has(name) ? attributes.get(name) : null; },
        removeAttribute(name) { attributes.delete(name); },
        addEventListener(event, handler) { this.handlers[event] = handler; },
        appendChild(child) { this.children.push(child); },
        scrollIntoView() {},
        focus() { focused = id; }
      };
      let inner = '';
      Object.defineProperty(el, 'innerHTML', {
        get() { return inner; }, set(value) { inner = value; el.children = []; }
      });
      elements.set(id, el);
    }
    return elements.get(id);
  }
  const location = { search, hash };
  const context = vm.createContext({
    document: {
      body: element('body'),
      getElementById(id) { requestedIds.add(id); return element(id); },
      querySelectorAll(selector) {
        if (selector === '#sections input') return [{ checked: true, value: 'compliance' }];
        return [];
      },
      createElement: () => element(Symbol('created'))
    },
    window: {
      location,
      history: { replaceState(_state, _title, url) { history.push(url); } },
      addEventListener(event, handler) { listeners[event] = handler; },
      scrollTo() {}
    },
    URLSearchParams, TextEncoder,
    btoa: (text) => Buffer.from(text, 'binary').toString('base64'),
    fetch: async (url, options) => {
      const request = { url, method: options?.method || 'GET', payload: options?.body && JSON.parse(options.body),
        headers: options?.headers };
      requests.push(request);
      const response = await respond(url, request);
      if (response instanceof Error) throw response;
      const status = response?.httpStatus || 200;
      return { ok: status >= 200 && status < 300, status,
        json: async () => (response?.body === undefined ? (response ?? {}) : response.body) };
    },
    setInterval() { return Symbol('timer'); }, clearInterval() {},
    setTimeout(callback) { timeouts.push(callback); return timeouts.length; },
    alert(message) { alerts.push(message); }, confirm() { return true; }
  });
  seed(element);
  installI18n(context, locale);
  vm.runInContext(script, context);
  return {
    element, requests, history, alerts,
    run: (code) => vm.runInContext(code, context),
    settle: () => new Promise(setImmediate),
    runTimeout() { assert.ok(timeouts.length, 'expected a scheduled timeout'); timeouts.shift()(); },
    focused: () => focused,
    clearFocus() { focused = null; },
    navigate(next) { location.hash = next; listeners.hashchange(); },
    visible: (id) => !element(id).classList.contains('hidden'),
    visibleViews() { return viewIds.filter((id) => this.visible(id)); }
  };
}

const stateOnly = (body) => (url) => (url === '/api/state' ? body : {});

test('boot waits for browser-selected catalogs and static translations before the first state request', async () => {
  let release;
  const gate = new Promise(resolve => { release = resolve; });
  const d = shell({
    locale: { languages: ['fr-CA'], beforeCatalog: () => gate },
    respond: stateOnly(signedOut())
  });
  await d.settle();
  assert.equal(d.requests.length, 0);
  release();
  await d.settle();
  assert.equal(d.requests[0].url, '/api/state');
  assert.equal(d.requests[0].headers['X-Ids-Locale'], 'fr-FR');
  assert.equal(d.run('document.documentElement.getAttribute("lang")'), 'fr-FR');
  assert.equal(d.run('window.IdsI18n.locale'), 'fr-FR');
});

test('declining policy consent keeps signed-in Home idle across refreshes without collecting', async () => {
  let declined = false;
  const d = shell({ respond(url) {
    if (url === '/api/policies/decline') { declined = true; return { ok: true }; }
    return url === '/api/state' ? signedIn({ policies: { status: 'idle', consentRequired: !declined } }) : {};
  } });
  await d.settle();
  assert.deepEqual(d.visibleViews(), ['viewPolicies']);
  await d.element('btnPoliciesNotNow').handlers.click();
  await d.run('refreshState()');
  await d.run('refreshState()');
  assert.deepEqual(d.visibleViews(), ['viewHome']);
  assert.equal(d.element('btnExport').disabled, true);
  assert.equal(d.element('btnAssessmentRun').disabled, true);
  assert.equal(d.requests.some((r) => r.url === '/api/policies/reload'), false);
});

test('an explicit offline source enables both workflows without authentication or connection probes', async () => {
  const body = signedOut({ policies: { status: 'partial', count: 1, families: [], issues: [],
    source: { kind: 'offline', name: 'Synthetic imported environment' } } });
  const d = shell({ respond: stateOnly(body) });
  await d.settle();
  assert.deepEqual(d.visibleViews(), ['viewHome']);
  d.navigate('#/document');
  assert.deepEqual(d.visibleViews(), ['viewDocument']);
  d.navigate('#/assess');
  assert.deepEqual(d.visibleViews(), ['viewAssess']);
  assert.equal(d.element('btnAssessmentRun').disabled, false);
  d.navigate('#/signin');
  assert.deepEqual(d.visibleViews(), ['viewLanding']);
  assert.equal(d.visible('returnOfflineWorkspace'), true);
  d.navigate('#/');
  assert.deepEqual(d.visibleViews(), ['viewHome']);
  assert.equal(d.run('state.policies.count'), 1);
  assert.equal(d.element('btnShowPolicyExport').disabled, false);
  d.element('btnShowPolicyExport').handlers.click();
  assert.equal(d.element('policyExportPanel').open, true);
  assert.equal(d.requests.some((r) => /\/api\/(probe|signin)/.test(r.url)), false);
});

test('importing a chosen host folder sends its path and opens the offline workspace', async () => {
  let imported = false;
  const folder = 'C:\\synthetic\\documentation\\_raw';
  const d = shell({ respond(url, request) {
    if (url === '/api/folders/picker') {
      return request.method === 'POST' ? { started: true } : { status: 'selected', path: folder };
    }
    if (url === '/api/policies/import') { imported = true; return { started: true }; }
    if (url === '/api/policies/transfer') {
      return { status: 'completed', running: false, result: { policies: 1 } };
    }
    if (url === '/api/state') {
      const policies = imported
        ? { status: 'partial', count: 1, families: [], issues: [], source: { kind: 'offline', name: 'Synthetic' } }
        : { status: 'idle' };
      return signedOut({ policies });
    }
    return {};
  } });
  await d.settle();
  d.element('btnOpenPolicyImport').handlers.click();
  assert.deepEqual(d.visibleViews(), ['viewImport']);
  await d.element('btnBrowsePolicyImport').handlers.click();
  assert.equal(d.element('policyImportPath').value, folder);
  await d.element('btnImportPolicySource').handlers.click();
  const request = d.requests.find((item) => item.url === '/api/policies/import');
  assert.equal(request.payload.path, folder);
  assert.equal(request.payload.replace, false);
  assert.equal(request.payload.archive, undefined);
  assert.deepEqual(d.visibleViews(), ['viewHome']);
  assert.equal(d.run('state.policies.count'), 1);
});

test('policy ZIP import shows activity while reading and actual file progress while processing', async () => {
  let releaseFile;
  const fileRead = new Promise((resolve) => { releaseFile = resolve; });
  let completed = false;
  let polls = 0;
  const d = shell({ respond(url) {
    if (url === '/api/policies/import') return { started: true };
    if (url === '/api/policies/transfer') {
      polls++;
      if (polls === 1) return { status: 'running', running: true,
        progress: { stage: 'reading', completed: 2, total: null } };
      if (polls === 2) return { status: 'running', running: true,
        progress: { stage: 'validating', completed: 3, total: 7 } };
      completed = true;
      return { status: 'completed', running: false, result: { policies: 1 } };
    }
    if (url === '/api/state') return signedOut({ policies: completed
      ? { status: 'partial', count: 1, families: [], issues: [], source: { kind: 'offline' } }
      : { status: 'idle' } });
    return {};
  } });
  await d.settle();
  d.element('btnOpenPolicyImport').handlers.click();
  d.element('policyImportZip').files = [{ name: 'synthetic.zip', size: 3, arrayBuffer: () => fileRead }];
  const importing = d.element('btnImportPolicySource').handlers.click();
  await d.settle();
  assert.match(d.element('policyImportStatus').textContent, /read/i);
  assert.equal(d.visible('policyImportProgress'), true);
  assert.equal(d.element('btnImportPolicySource').disabled, true);
  assert.equal(d.element('btnCancelPolicyImport').disabled, true);
  assert.equal(d.requests.some((request) => request.url === '/api/policies/import'), false);

  releaseFile(Uint8Array.from([1, 2, 3]).buffer);
  await d.settle();
  assert.match(d.element('policyImportStatus').textContent, /read.*2/i);
  assert.doesNotMatch(d.element('policyImportStatus').textContent, /%/);
  d.runTimeout();
  await d.settle();
  assert.match(d.element('policyImportStatus').textContent, /validat.*3\s*\/\s*7/i);
  await d.run("window.IdsI18n.setLocale('nl-NL')");
  assert.match(d.element('policyImportStatus').textContent, /valideren.*3\s*\/\s*7/i);
  d.runTimeout();
  await importing;
  assert.equal(d.visible('policyImportProgress'), false);
  assert.deepEqual(d.visibleViews(), ['viewHome']);
});

test('a resumed policy export opens its progress panel and reports real preparation counts', async () => {
  let running = true;
  let polls = 0;
  const d = shell({ respond(url) {
    if (url === '/api/state') return signedOut({
      policies: { status: 'partial', count: 1, families: [], issues: [], source: { kind: 'offline' } },
      transfer: { running, operation: 'export' }
    });
    if (url === '/api/policies/transfer') {
      polls++;
      if (polls === 1) return { status: 'running', running: true,
        progress: { stage: 'preparing', completed: 1, total: 6 } };
      running = false;
      return { status: 'completed', running: false, result: { path: 'C:\\synthetic\\policy-set' } };
    }
    return {};
  } });
  await d.settle();
  assert.equal(d.element('policyExportPanel').open, true);
  assert.equal(d.visible('policyExportProgress'), true);
  assert.match(d.element('policyExportStatus').textContent, /prepar.*1\s*\/\s*6/i);
  d.runTimeout();
  await d.settle();
  assert.equal(d.visible('policyExportProgress'), false);
  assert.match(d.element('policyExportStatus').textContent, /policy-set/);
});

test('policy transfer reports a temporary polling outage and resumes progress', async () => {
  let polls = 0;
  const d = shell({ respond(url) {
    if (url === '/api/state') return signedOut({
      policies: { status: 'partial', count: 1, families: [], issues: [], source: { kind: 'offline' } }
    });
    if (url === '/api/policies/export') return { started: true };
    if (url === '/api/policies/transfer') {
      polls++;
      if (polls === 1) return new Error('Synthetic connection interruption');
      return { status: 'completed', running: false, result: { path: 'C:\\synthetic\\policy-set' } };
    }
    return {};
  } });
  await d.settle();
  d.element('btnShowPolicyExport').handlers.click();
  const exporting = d.element('btnExportPolicySource').handlers.click();
  await d.settle();
  assert.equal(d.visible('policyExportProgress'), true);
  assert.match(d.element('policyExportStatus').textContent, /unavailable.*checking/i);
  d.runTimeout();
  await exporting;
  assert.equal(d.visible('policyExportProgress'), false);
  assert.match(d.element('policyExportStatus').textContent, /policy-set/);
});

test('policy transfer retries a server error but surfaces a worker failure without an activity indicator', async () => {
  let polls = 0;
  const d = shell({ respond(url) {
    if (url === '/api/state') return signedOut({
      policies: { status: 'partial', count: 1, families: [], issues: [], source: { kind: 'offline' } }
    });
    if (url === '/api/policies/export') return { started: true };
    if (url === '/api/policies/transfer') {
      polls++;
      if (polls === 1) return { httpStatus: 503, body: { error: 'Synthetic temporary outage' } };
      return { status: 'failed', running: false, error: 'Synthetic worker failure' };
    }
    return {};
  } });
  await d.settle();
  d.element('btnShowPolicyExport').handlers.click();
  const exporting = d.element('btnExportPolicySource').handlers.click();
  await d.settle();
  assert.match(d.element('policyExportStatus').textContent, /unavailable.*checking/i);
  assert.equal(d.visible('policyExportProgress'), true);
  d.runTimeout();
  await exporting;
  assert.equal(d.visible('policyExportProgress'), false);
  assert.match(d.element('policyExportStatus').textContent, /Synthetic worker failure/);
});

test('a stale policy export start failure cannot overwrite the reset workspace', async () => {
  let release;
  const d = shell({ respond(url) {
    if (url === '/api/state') return signedOut({
      policies: { status: 'partial', count: 1, families: [], issues: [], source: { kind: 'offline' } }
    });
    if (url === '/api/policies/export') return new Promise((resolve) => { release = resolve; });
    return {};
  } });
  await d.settle();
  d.element('btnShowPolicyExport').handlers.click();
  const exporting = d.element('btnExportPolicySource').handlers.click();
  await d.settle();
  d.run('clearWorkspace()');
  d.element('policyExportStatus').textContent = 'New workspace';
  release(new Error('Synthetic stale start failure'));
  await exporting;
  assert.equal(d.element('policyExportStatus').textContent, 'New workspace');
  assert.equal(d.visible('policyExportProgress'), false);
});

test('an imported policy source reports a failed workspace refresh', async () => {
  for (const failure of [new Error('Synthetic refresh failure'), { httpStatus: 500, body: { error: 'Synthetic HTTP failure' } }]) {
    let imported = false;
    const d = shell({ respond(url) {
      if (url === '/api/state') return imported ? failure
        : signedOut({ policies: { status: 'idle' } });
      if (url === '/api/policies/import') return { started: true };
      if (url === '/api/policies/transfer') {
        imported = true;
        return { status: 'completed', running: false, result: { policies: 1 } };
      }
      return {};
    } });
    await d.settle();
    d.element('btnOpenPolicyImport').handlers.click();
    d.element('policyImportPath').value = 'C:\\synthetic\\policies';
    await d.element('btnImportPolicySource').handlers.click();
    assert.deepEqual(d.visibleViews(), ['viewImport']);
    assert.equal(d.visible('policyImportProgress'), false);
    assert.equal(d.visible('policyImportError'), true);
    assert.match(d.element('policyImportError').textContent, /imported.*refresh.*reload/i);
    assert.equal(d.run('policiesReady()'), false);
  }
});

test('resetting the workspace during ZIP preparation never starts a stale import', async () => {
  let releaseFile;
  const fileRead = new Promise((resolve) => { releaseFile = resolve; });
  const d = shell({ respond: stateOnly(signedOut({ policies: { status: 'idle' } })) });
  await d.settle();
  d.element('btnOpenPolicyImport').handlers.click();
  d.element('policyImportZip').files = [{ name: 'synthetic.zip', size: 3, arrayBuffer: () => fileRead }];
  const importing = d.element('btnImportPolicySource').handlers.click();
  await d.settle();
  d.run('clearWorkspace()');
  releaseFile(Uint8Array.from([1, 2, 3]).buffer);
  await importing;
  assert.equal(d.requests.some((request) => request.url === '/api/policies/import'), false);
  assert.equal(d.visible('policyImportProgress'), false);
});

test('large policy ZIP preparation yields to the UI and preserves the exact archive bytes', async () => {
  const bytes = Uint8Array.from({ length: 3 * 0x4000 * 9 + 2 }, (_, index) => index % 256);
  const d = shell({ respond(url) {
    if (url === '/api/state') return signedOut({ policies: { status: 'idle' } });
    if (url === '/api/policies/import') return { started: true };
    if (url === '/api/policies/transfer') return { status: 'completed', running: false, result: { policies: 1 } };
    return {};
  } });
  await d.settle();
  d.element('btnOpenPolicyImport').handlers.click();
  d.element('policyImportZip').files = [{ name: 'synthetic.zip', size: bytes.length, arrayBuffer: async () => bytes.buffer }];
  const importing = d.element('btnImportPolicySource').handlers.click();
  await d.settle();
  assert.match(d.element('policyImportStatus').textContent, /prepar.*zip/i);
  assert.equal(d.visible('policyImportProgress'), true);
  assert.equal(d.requests.some((request) => request.url === '/api/policies/import'), false);
  d.runTimeout();
  await importing;
  assert.equal(d.requests.find((request) => request.url === '/api/policies/import').payload.archive,
    Buffer.from(bytes).toString('base64'));
});

test('resetting while encoding a large policy ZIP prevents its upload', async () => {
  const bytes = new Uint8Array(3 * 0x4000 * 9 + 2);
  const d = shell({ respond: stateOnly(signedOut({ policies: { status: 'idle' } })) });
  await d.settle();
  d.element('btnOpenPolicyImport').handlers.click();
  d.element('policyImportZip').files = [{ name: 'synthetic.zip', size: bytes.length, arrayBuffer: async () => bytes.buffer }];
  const importing = d.element('btnImportPolicySource').handlers.click();
  await d.settle();
  assert.equal(d.requests.some((request) => request.url === '/api/policies/import'), false);
  d.run('clearWorkspace()');
  d.runTimeout();
  await importing;
  assert.equal(d.requests.some((request) => request.url === '/api/policies/import'), false);
  assert.equal(d.visible('policyImportProgress'), false);
});

test('documentation export displays activity while its start request is pending', async () => {
  let releaseStart;
  const start = new Promise((resolve) => { releaseStart = resolve; });
  const d = shell({ hash: '#/document', respond(url) {
    if (url === '/api/state') return signedIn();
    if (url === '/api/export') return start;
    if (url.startsWith('/api/export/log')) return { running: true, done: false, percent: 5, phase: 'Preparing' };
    return {};
  } });
  await d.settle();
  assert.equal(d.visible('documentExportStarting'), false);
  const exporting = d.element('btnExport').handlers.click();
  await d.settle();
  assert.equal(d.visible('documentExportStarting'), true);
  assert.equal(d.element('btnExport').disabled, true);
  releaseStart({ started: true });
  await exporting;
  assert.equal(d.visible('documentExportStarting'), false);
  assert.equal(d.visible('cardRun'), true);
});

test('documentation export surfaces a polling outage and clears it when progress returns', async () => {
  let fail = false;
  const d = shell({ respond(url) {
    if (url === '/api/state') return signedIn();
    if (url.startsWith('/api/export/log')) {
      return fail ? new Error('Synthetic connection interruption')
        : { running: true, done: false, percent: 35, phase: 'Collecting policies', entries: [] };
    }
    return {};
  } });
  await d.settle();
  fail = true;
  await d.run('pollLog()');
  assert.equal(d.visible('documentExportProgressError'), true);
  assert.match(d.element('documentExportProgressError').textContent, /progress.*unavailable/i);
  fail = false;
  await d.run('pollLog()');
  assert.equal(d.visible('documentExportProgressError'), false);
  assert.equal(d.element('bar').style.width, '35%');
  assert.equal(d.element('phase').textContent, 'Collecting policies');
});

test('a resumed documentation export keeps retrying when its first log request fails', async () => {
  let fail = true;
  const d = shell({ hash: '#/document', respond(url) {
    if (url === '/api/state') return signedIn({ export: { running: true } });
    if (url.startsWith('/api/export/log')) {
      return fail ? new Error('Synthetic connection interruption')
        : { running: true, done: false, percent: 45, phase: 'Writing files', entries: [] };
    }
    return {};
  } });
  await d.settle();
  assert.equal(d.visible('cardRun'), true);
  assert.equal(d.visible('documentExportProgressError'), true);
  assert.match(d.element('documentExportProgressError').textContent, /progress.*unavailable/i);
  fail = false;
  await d.run('pollLog()');
  assert.equal(d.visible('documentExportProgressError'), false);
  assert.equal(d.element('bar').style.width, '45%');
});

test('a resumed documentation export shows progress before other initialization finishes', async () => {
  for (const delayedUrl of ['/api/assessment', '/api/assessment/packs', '/api/settings']) {
    let release;
    const pending = new Promise((resolve) => { release = resolve; });
    const d = shell({
      hash: '#/document',
      seed(element) { element('cardRun').classList.add('hidden'); },
      respond(url) {
        if (url === '/api/state') return signedIn({ export: { running: true } });
        if (url === delayedUrl) return pending;
        if (url.startsWith('/api/export/log')) {
          return { running: true, done: false, percent: 45, phase: 'Writing files', entries: [] };
        }
        return {};
      }
    });
    await d.settle();
    assert.ok(d.requests.some((request) => request.url === delayedUrl), `expected ${delayedUrl} to be pending`);
    assert.equal(d.visible('cardRun'), true, `progress is visible while ${delayedUrl} is pending`);
    assert.equal(d.element('bar').style.width, '45%');
    assert.equal(d.element('phase').textContent, 'Writing files');
    assert.equal(d.element('btnExport').disabled, true);
    release({});
    await d.settle();
  }
});

test('a stale documentation progress response cannot restore a reset workspace', async () => {
  let release;
  let block = false;
  const d = shell({ respond(url) {
    if (url === '/api/state') return signedIn();
    if (url.startsWith('/api/export/log') && block) return new Promise((resolve) => { release = resolve; });
    return {};
  } });
  await d.settle();
  block = true;
  const polling = d.run('pollLog()');
  await d.settle();
  d.run('clearWorkspace()');
  release({ running: true, percent: 75, phase: 'Old progress', entries: [] });
  await polling;
  assert.equal(d.element('bar').style.width, '0%');
  assert.equal(d.visible('cardRun'), false);
  assert.equal(d.visible('documentExportProgressError'), false);
});

test('signed-in Home is available without policies while deep-linked workflows remain gated', async () => {
  for (const status of ['idle', 'loading', 'failed', undefined]) {
    const d = shell({ hash: '#/assess', respond: stateOnly(signedIn({ policies: { status } })) });
    await d.settle();
    const expected = status === 'loading' || status === 'failed' ? 'viewPolicies' : 'viewHome';
    assert.deepEqual(d.visibleViews(), [expected]);
    assert.equal(d.visible('appNav'), expected === 'viewHome');
    assert.equal(d.visible('sessionControls'), true);
    assert.equal(d.element('btnExport').disabled, true);
    assert.equal(d.element('btnAssessmentRun').disabled, true);
    d.navigate('#/document');
    assert.deepEqual(d.visibleViews(), [expected]);
    await d.element('btnExport').handlers.click();
    assert.equal(d.requests.some((r) => r.url === '/api/export'), false);
  }
});

test('finishing policy loading leads to the workspace choice, not a stale deep link', async () => {
  let policies = { status: 'loading', percent: 35, phase: 'Loading compliance' };
  const d = shell({ hash: '#/assess', respond: () => signedIn({ policies }) });
  await d.settle();
  assert.equal(d.element('policyLoadBar').style.width, '35%');
  policies = { status: 'ready', count: 0, capturedAt: '2026-10-29T10:00:00Z', families: [], issues: [] };
  await d.run('refreshState()');
  assert.deepEqual(d.visibleViews(), ['viewHome']);
  assert.equal(d.focused(), 'homeTitle');
  assert.match(d.element('policySummary').textContent, /0 policies/);
});

test('partial policy loading surfaces escaped limitations without blocking the choice', async () => {
  const d = shell({ respond: stateOnly(signedIn({ policies: {
    status: 'partial', count: 2, families: [{ label: '<b>Policy</b>', count: 2, complete: false }],
    issues: [{ family: 'compliance', stage: 'inventory', reason: '<script>bad()</script>', statusCode: 403 }]
  } })) });
  await d.settle();
  assert.deepEqual(d.visibleViews(), ['viewHome']);
  assert.equal(d.visible('policyLimitations'), true);
  assert.match(d.element('policyLimitations').textContent, /403/);
  assert.doesNotMatch(d.element('policyFamilies').innerHTML, /<b>Policy<\/b>/);
});

test('failed loading offers retry and never leaves old workflow choices enabled', async () => {
  const d = shell({ respond: stateOnly(signedIn({ policies: { status: 'failed', error: 'Synthetic loading failure' } })) });
  await d.settle();
  assert.equal(d.visible('btnRetryPolicies'), true);
  assert.match(d.element('policyLoadError').textContent, /Synthetic loading failure/);
  assert.equal(d.element('btnExport').disabled, true);
});

test('signed-out operators see only the landing page whatever the route', async () => {
  for (const hash of ['', '#/', '#/document', '#/assess', '#/settings', '#/unknown']) {
    const d = shell({ hash, respond: stateOnly(signedOut()) });
    await d.settle();
    assert.deepEqual(d.visibleViews(), ['viewLanding'], hash);
    assert.equal(d.visible('appNav'), false, hash);
    assert.equal(d.visible('sessionControls'), false, hash);
    assert.equal(d.element('connBadge').textContent, 'Not connected');
  }
});

test('signed-in routes show exactly one workspace view and mark the active link', async () => {
  const cases = [
    ['', 'viewHome', 'navHome'], ['#/', 'viewHome', 'navHome'], ['#/document', 'viewDocument', 'navDocument'],
    ['#/assess', 'viewAssess', 'navAssess'], ['#/settings', 'viewSettings', 'navSettings'], ['#/unknown', 'viewHome', 'navHome']
  ];
  for (const [hash, view, link] of cases) {
    const d = shell({ hash, respond: stateOnly(signedIn()) });
    await d.settle();
    assert.deepEqual(d.visibleViews(), [view], hash);
    assert.equal(d.visible('appNav'), true, hash);
    assert.equal(d.visible('sessionControls'), true, hash);
    for (const other of ['navHome', 'navDocument', 'navAssess', 'navSettings']) {
      assert.equal(d.element(other).getAttribute('aria-current'), other === link ? 'page' : null, `${hash} ${other}`);
    }
  }
});

test('the skip link keeps the current workspace instead of routing Home', async () => {
  const d = shell({ hash: '#/assess', respond: stateOnly(signedIn()) });
  await d.settle();
  d.clearFocus();
  d.navigate('#main');
  assert.deepEqual(d.visibleViews(), ['viewAssess']);
  assert.equal(d.element('navAssess').getAttribute('aria-current'), 'page');
  assert.notEqual(d.focused(), 'homeTitle');
  d.navigate('#/document');
  assert.deepEqual(d.visibleViews(), ['viewDocument']);
});

test('Home greets the account and shows the tenant as text', async () => {
  const d = shell({ respond: stateOnly(signedIn({ auth: { ...signedIn().auth, account: '<b>admin</b>' } })) });
  await d.settle();
  assert.match(d.element('homeGreeting').textContent, /Welcome, <b>admin<\/b>/);
  assert.match(d.element('homeTenant').textContent, /00000000-0000-0000-0000-000000000001/);
  assert.equal(d.element('homeGreeting').innerHTML, '');
});

test('hash changes re-render the route and move focus only on navigation', async () => {
  const d = shell({ respond: stateOnly(signedIn()) });
  await d.settle();
  d.navigate('#/assess');
  assert.deepEqual(d.visibleViews(), ['viewAssess']);
  assert.equal(d.focused(), 'assessTitle');
  d.navigate('#/document');
  assert.deepEqual(d.visibleViews(), ['viewDocument']);
  assert.equal(d.focused(), 'documentTitle');
  d.navigate('#/');
  assert.equal(d.focused(), 'homeTitle');
  d.clearFocus();
  await d.run('refreshState()');
  assert.equal(d.focused(), null);
});

test('signing out returns to the landing page', async () => {
  let connected = true;
  const d = shell({ hash: '#/document', respond: (url) => {
    if (url === '/api/state') return connected ? signedIn() : signedOut();
    if (url === '/api/signout') { connected = false; return {}; }
    return {};
  } });
  await d.settle();
  assert.deepEqual(d.visibleViews(), ['viewDocument']);
  await d.element('btnSignout').handlers.click();
  assert.deepEqual(d.visibleViews(), ['viewLanding']);
  assert.equal(d.visible('appNav'), false);
});

test('an expired session during assessment returns to sign-in with an explanation', async () => {
  const d = shell({ hash: '#/assess', respond: (url, r) => {
    if (url === '/api/state') return signedIn();
    if (r.method === 'POST') return { httpStatus: 401, body: { error: 'Not signed in.' } };
    return {};
  } });
  await d.settle();
  d.element('assessmentImportFile').files = [{ name: 'synthetic.json', size: 2, text: async () => '{}' }];
  await d.element('btnAssessmentImport').handlers.click();
  assert.deepEqual(d.visibleViews(), ['viewLanding']);
  assert.match(d.element('signinError').textContent, /session ended/i);
  assert.equal(d.visible('signinError'), true);
  assert.match(d.element('assessmentError').textContent, /401/);
});

test('activity indicators follow export and assessment work', async () => {
  let release;
  const d = shell({ respond: (url, r) => {
    if (url === '/api/state') return signedIn();
    if (url === '/api/export' && r.method === 'POST') return new Promise((resolve) => { release = resolve; });
    return {};
  } });
  await d.settle();
  for (const id of ['navDocumentBusy', 'homeDocumentBusy', 'navAssessBusy', 'homeAssessBusy']) {
    assert.equal(d.visible(id), false, id);
  }
  const exporting = d.element('btnExport').handlers.click();
  await d.settle();
  assert.equal(d.visible('navDocumentBusy'), true);
  assert.equal(d.visible('homeDocumentBusy'), true);
  assert.equal(d.visible('navAssessBusy'), false);
  release({ httpStatus: 500, body: { error: 'Synthetic failure' } });
  await exporting;
  assert.equal(d.visible('navDocumentBusy'), false);
  assert.equal(d.visible('homeDocumentBusy'), false);
  d.run('assessmentBusy = true; syncJobAdmission()');
  assert.equal(d.visible('navAssessBusy'), true);
  assert.equal(d.visible('homeAssessBusy'), true);
});

test('the documentation stepper follows configure, generate and review', async () => {
  let done = false;
  const d = shell({ hash: '#/document', respond: (url) => {
    if (url === '/api/state') return signedIn();
    if (url.startsWith('/api/export/log')) return done ? { done: true, summary: { stats: {} } } : { percent: 10 };
    return {};
  } });
  await d.settle();
  const step = (id) => [d.element(id).className, d.element(id).getAttribute('aria-current')];
  assert.deepEqual(step('stepConfigure'), ['active', 'step']);
  await d.element('btnExport').handlers.click();
  await d.settle();
  assert.deepEqual(step('stepConfigure'), ['done', null]);
  assert.deepEqual(step('stepGenerate'), ['active', 'step']);
  done = true;
  await d.run('pollLog()');
  assert.deepEqual(step('stepGenerate'), ['done', null]);
  assert.deepEqual(step('stepReview'), ['active', 'step']);
  d.element('btnAgain').handlers.click();
  assert.deepEqual(step('stepConfigure'), ['active', 'step']);
  assert.deepEqual(step('stepReview'), ['', null]);
});

test('advanced sign-in options open for a remembered tenant only', async () => {
  const seed = (element) => { element('tenant').value = 'organizations'; };
  const remembered = shell({ seed, respond: stateOnly(signedOut({ tenant: 'contoso.example' })) });
  await remembered.settle();
  assert.equal(remembered.element('tenant').value, 'contoso.example');
  assert.equal(remembered.element('advancedSignin').open, true);
  const fresh = shell({ seed, respond: stateOnly(signedOut()) });
  await fresh.settle();
  assert.equal(fresh.element('advancedSignin').open, false);
});

test('an unreachable local server offers a retry that recovers', async () => {
  let up = false;
  const d = shell({ respond: (url) => {
    if (url === '/api/state') return up ? signedOut() : new Error('Synthetic connection refused');
    return {};
  } });
  await d.settle();
  assert.deepEqual(d.visibleViews(), ['viewLoading']);
  assert.match(d.element('loadingText').textContent, /not responding/i);
  assert.equal(d.visible('btnRetryState'), true);
  up = true;
  await d.element('btnRetryState').handlers.click();
  assert.deepEqual(d.visibleViews(), ['viewLanding']);
  assert.equal(d.visible('btnRetryState'), false);
});

test('returning from browser sign-in strips the query but keeps the route', async () => {
  const d = shell({ search: '?signin=state-mismatch', hash: '#/assess', respond: stateOnly(signedOut()) });
  await d.settle();
  assert.deepEqual(d.history, ['/#/assess']);
  assert.match(d.element('signinError').textContent, /state mismatch/);
});

test('the stopped page keeps the theme without inline styles', async () => {
  const d = shell({ respond: (url) => (url === '/api/state' ? signedIn() : {}) });
  await d.settle();
  await d.element('btnQuit').handlers.click();
  assert.match(d.element('body').innerHTML, /has stopped/);
  assert.doesNotMatch(d.element('body').innerHTML, /style=/);
});

test('the page has unique IDs, no external resources and honors reduced motion', () => {
  const ids = [...html.matchAll(/\sid="([^"]+)"/g)].map((m) => m[1]);
  const duplicates = ids.filter((id, i) => ids.indexOf(id) !== i);
  assert.deepEqual(duplicates, []);
  assert.doesNotMatch(html, /\s(?:src|href)\s*=\s*["']\s*(?:https?:)?\/\//i);
  assert.doesNotMatch(css, /@import|url\(\s*["']?\s*(?:https?:)?\/\//i);
  assert.match(css, /@media\s*\(prefers-reduced-motion:\s*reduce\)/);
});

test('landing blocks share top and bottom edges and centre their content', () => {
  const rule = (selector) => {
    const escaped = selector.replace(/[.*+?^${}()|[\]\\]/g, '\\$&');
    const match = css.match(new RegExp(`(?:^|\\n)${escaped}\\s*\\{([^}]*)\\}`));
    assert.ok(match, `top-level ${selector} rule`);
    return match[1];
  };
  const landing = rule('.landing');
  assert.match(landing, /align-items:\s*stretch/);
  assert.doesNotMatch(landing, /align-items:\s*center/);
  assert.match(landing, /align-content:\s*center/);
  for (const block of ['.hero', '.signin-card']) {
    const body = rule(block);
    assert.match(body, /display:\s*flex/, block);
    assert.match(body, /flex-direction:\s*column/, block);
    assert.match(body, /justify-content:\s*center/, block);
  }
});

test('the assessment stepper has six numbered steps and wraps at 900 px; the documentation stepper is unchanged', () => {
  const narrow = css.match(/@media \(max-width: 900px\) \{([\s\S]*?)\n\}/);
  assert.ok(narrow, '900 px media query');
  assert.match(narrow[1], /\.stepper\.wide \{ flex-wrap: wrap; \}/);
  assert.match(narrow[1], /\.stepper\.wide li \{ flex: 1 1 140px; \}/);
  assert.match(html, /<ol class="stepper" aria-label="Export steps">/);
  const wizard = html.match(/<ol class="stepper wide" aria-label="Assessment steps">([\s\S]*?)<\/ol>/);
  assert.ok(wizard, 'assessment stepper');
  const items = [...wizard[1].matchAll(
    /<li id="(\w+)"(?: class="active")?><button type="button" id="\w+" disabled aria-label="[^"]+"><span class="step-num" aria-hidden="true">(\d)<\/span>([^<]+)<\/button><\/li>/g
  )].map((m) => [m[1], m[2], m[3]]);
  assert.deepEqual(items, [
    ['assessStepPlatforms', '1', 'Platforms'], ['assessStepImport', '2', 'Import packs'], ['assessStepBaselines', '3', 'Baselines'],
    ['assessStepContext', '4', 'Context'], ['assessStepReview', '5', 'Review &amp; run'],
    ['assessStepResults', '6', 'Results']
  ]);
  assert.match(wizard[1], /<li id="assessStepPlatforms" class="active">/);
});

test('the assessment wizard opens with platforms only and every wizard element exists once', async () => {
  const d = shell({ hash: '#/assess', respond: stateOnly(signedIn()) });
  await d.settle();
  assert.deepEqual(d.visibleViews(), ['viewAssess']);
  const steps = ['assessStepPlatforms', 'assessStepImport', 'assessStepBaselines', 'assessStepContext', 'assessStepReview',
    'assessStepResults'];
  assert.deepEqual(steps.map((id) => [d.element(id).className, d.element(id).getAttribute('aria-current')]),
    [['active', 'step'], ['', null], ['', null], ['', null], ['', null], ['', null]]);
  const panels = ['assessPanelPlatforms', 'assessPanelBaselines', 'assessPanelContext', 'assessPanelReview',
    'assessPanelResults', 'assessImportPanel'];
  assert.deepEqual(panels.filter((id) => d.visible(id)), ['assessPanelPlatforms']);
  assert.equal(d.focused(), null);
  d.run("updateAssessmentContext(); renderAssessmentReview(); setAssessmentStep('results', true)");
  assert.equal(d.focused(), 'resultsTitle');
  assert.equal(d.visible('assessImportPanel'), false);
  const headings = ['platformsTitle', 'baselinesTitle', 'contextTitle', 'runAssessmentTitle', 'resultsTitle'];
  for (const id of headings) assert.match(html, new RegExp(`<h3 id="${id}" class="card-title" tabindex="-1">`), id);
  const added = [...steps, ...panels, ...headings, 'assessImportTitle', 'btnAssessPlatformsNext',
    'btnAssessBaselinesBack', 'btnAssessBaselinesNext', 'btnAssessContextBack', 'btnAssessContextNext',
    'btnAssessReviewBack', 'btnAssessNew', 'btnAssessmentSelectAll', 'btnAssessmentSelectNone',
    'assessmentPacksEmpty', 'assessmentContextWarning', 'assessmentReview', 'assessmentImportSummary',
    'assessmentContextWindows11', 'assessmentContextMacos', 'assessmentContextIosIpados',
    'assessmentContextAndroidEnterprise', 'assessmentContextEnrollment', 'assessmentContextIosOwnership'];
  added.push('btnAssessmentWindowsBuild26H2', 'btnAssessmentWindowsBuild26H1',
    'btnAssessmentWindowsBuild25H2', 'btnAssessmentWindowsBuild24H2');
  for (const id of added) assert.equal(html.split(` id="${id}"`).length - 1, 1, id);
});

test('settings load saved thresholds, validate input, save and restore defaults', async () => {
  const defaults = { good: 90, attention: 70, coverage: 80 };
  let saveResponse = null;
  const d = shell({ hash: '#/settings', respond(url, request) {
    if (url === '/api/state') return signedIn();
    if (url === '/api/settings' && request.method === 'GET') {
      return { settings: { verdictThresholds: { good: 85, attention: 60, coverage: 75 } }, defaults: { verdictThresholds: defaults } };
    }
    if (url === '/api/settings') return saveResponse(request);
    return {};
  } });
  await d.settle();
  assert.deepEqual(d.visibleViews(), ['viewSettings']);
  assert.equal(d.element('navSettings').getAttribute('aria-current'), 'page');
  assert.deepEqual(['settingGood', 'settingAttention', 'settingCoverage'].map((id) => d.element(id).value), ['85', '60', '75']);
  assert.equal(d.element('settingsStatus').textContent, '');
  assert.match(d.element('settingsPreview').innerHTML, /Score of 85% or higher/);
  assert.match(d.element('settingsPreview').innerHTML, /Score from 60%, below 85%/);
  assert.equal(d.element('btnSettingsSave').disabled, false);

  d.element('settingAttention').value = '85';
  d.element('settingAttention').handlers.input();
  assert.equal(d.element('btnSettingsSave').disabled, true);
  assert.match(d.element('settingsPreview').innerHTML, /settings-error.*must be lower/);
  d.element('settingAttention').value = '7.5';
  d.element('settingAttention').handlers.input();
  assert.match(d.element('settingsPreview').innerHTML, /whole numbers from 0 to 100/);
  const before = d.requests.length;
  await d.element('btnSettingsSave').handlers.click();
  assert.equal(d.requests.length, before, 'invalid thresholds are never posted');

  d.element('settingAttention').value = '65';
  d.element('settingAttention').handlers.input();
  saveResponse = () => ({ httpStatus: 400, body: { error: 'Synthetic server rejection' } });
  await d.element('btnSettingsSave').handlers.click();
  await d.settle();
  assert.deepEqual(d.requests.at(-1).payload, { verdictThresholds: { good: 85, attention: 65, coverage: 75 } });
  assert.equal(d.requests.at(-1).headers['Content-Type'], 'application/json');
  assert.equal(d.element('settingsStatus').textContent, 'Synthetic server rejection');

  saveResponse = (request) => ({ settings: request.payload, defaults: { verdictThresholds: defaults } });
  await d.element('btnSettingsSave').handlers.click();
  await d.settle();
  assert.equal(d.element('settingsStatus').textContent, 'Settings saved.');
  assert.deepEqual({ ...d.run('appSettings.verdictThresholds') }, { good: 85, attention: 65, coverage: 75 });
  assert.equal(d.element('btnSettingsSave').disabled, false);

  d.element('btnSettingsReset').handlers.click();
  assert.deepEqual(['settingGood', 'settingAttention', 'settingCoverage'].map((id) => d.element(id).value), ['90', '70', '80']);
  assert.match(d.element('settingsStatus').textContent, /Default values restored/);
  assert.deepEqual({ ...d.run('appSettings.verdictThresholds') }, { good: 85, attention: 65, coverage: 75 }, 'reset is not saved');
});

test('unavailable settings fall back to the default thresholds with a visible message', async () => {
  const d = shell({ hash: '#/settings', respond(url) {
    if (url === '/api/state') return signedIn();
    if (url === '/api/settings') return new Error('offline');
    return {};
  } });
  await d.settle();
  assert.deepEqual(['settingGood', 'settingAttention', 'settingCoverage'].map((id) => d.element(id).value), ['90', '70', '80']);
  assert.match(d.element('settingsStatus').textContent, /could not be loaded/);
});

test('every element the script uses exists exactly once in the page', () => {
  const ids = [...html.matchAll(/\sid="([^"]+)"/g)].map((m) => m[1]);
  const literal = [...script.matchAll(/\$\('([A-Za-z][\w-]*)'\)/g)].map((m) => m[1]);
  const generatedByScript = new Set(['btnUseSuggestion']);
  const used = new Set([...literal, ...requestedIds]);
  assert.ok(used.size > 80, `only ${used.size} IDs observed`);
  for (const id of used) {
    if (generatedByScript.has(id)) continue;
    assert.equal(ids.filter((x) => x === id).length, 1, id);
  }
});
