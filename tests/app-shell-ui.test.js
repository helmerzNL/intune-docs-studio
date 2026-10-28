'use strict';

const { test } = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');

const webRoot = path.join(__dirname, '..', 'web');
const html = fs.readFileSync(path.join(webRoot, 'index.html'), 'utf8');
const script = fs.readFileSync(path.join(webRoot, 'app.js'), 'utf8');
const css = fs.readFileSync(path.join(webRoot, 'style.css'), 'utf8');
const build = { version: '0.1.0', channel: 'beta', commit: 'development' };
const signedIn = (extra = {}) => ({
  build,
  auth: { connected: true, account: 'admin@contoso.example', tenantId: '00000000-0000-0000-0000-000000000001',
    client: 'synthetic', method: 'portal', scopes: [] },
  ...extra
});
const signedOut = (extra = {}) => ({ build, auth: { connected: false }, ...extra });
const viewIds = ['viewLoading', 'viewLanding', 'viewHome', 'viewDocument', 'viewAssess'];
const requestedIds = new Set();

function shell({ hash = '', search = '', respond = () => ({}), seed = () => {} } = {}) {
  const elements = new Map();
  const requests = [];
  const listeners = {};
  const history = [];
  const alerts = [];
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
    fetch: async (url, options) => {
      const request = { url, method: options?.method || 'GET', payload: options?.body && JSON.parse(options.body) };
      requests.push(request);
      const response = await respond(url, request);
      if (response instanceof Error) throw response;
      const status = response?.httpStatus || 200;
      return { ok: status >= 200 && status < 300, status,
        json: async () => (response?.body === undefined ? (response ?? {}) : response.body) };
    },
    setInterval() { return Symbol('timer'); }, clearInterval() {}, setTimeout() {},
    alert(message) { alerts.push(message); }, confirm() { return true; }
  });
  seed(element);
  vm.runInContext(script, context);
  return {
    element, requests, history, alerts,
    run: (code) => vm.runInContext(code, context),
    settle: () => new Promise(setImmediate),
    focused: () => focused,
    clearFocus() { focused = null; },
    navigate(next) { location.hash = next; listeners.hashchange(); },
    visible: (id) => !element(id).classList.contains('hidden'),
    visibleViews() { return viewIds.filter((id) => this.visible(id)); }
  };
}

const stateOnly = (body) => (url) => (url === '/api/state' ? body : {});

test('signed-out operators see only the landing page whatever the route', async () => {
  for (const hash of ['', '#/', '#/document', '#/assess', '#/unknown']) {
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
    ['#/assess', 'viewAssess', 'navAssess'], ['#/unknown', 'viewHome', 'navHome']
  ];
  for (const [hash, view, link] of cases) {
    const d = shell({ hash, respond: stateOnly(signedIn()) });
    await d.settle();
    assert.deepEqual(d.visibleViews(), [view], hash);
    assert.equal(d.visible('appNav'), true, hash);
    assert.equal(d.visible('sessionControls'), true, hash);
    for (const other of ['navHome', 'navDocument', 'navAssess']) {
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
