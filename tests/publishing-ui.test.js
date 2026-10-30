'use strict';

const { test } = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');
const { installI18n, withoutTranslationSpans } = require('./i18n-test-helpers');

async function dashboard(respond = () => ({}), { httpOk = true, httpStatus = 200 } = {}) {
  const elements = new Map();
  const requests = [];
  const timers = [];
  function element(id) {
    if (!elements.has(id)) elements.set(id, {
      value: '', checked: false, children: [], options: [], handlers: {},
      classList: { add() {}, remove() {} },
      style: {}, dataset: {},
      addEventListener(event, handler) { this.handlers[event] = handler; },
      appendChild(child) { this.children.push(child); },
      setAttribute() {}, removeAttribute() {}, focus() {},
      scrollIntoView() {}
    });
    return elements.get(id);
  }
  const context = vm.createContext({
    document: {
      getElementById: element,
      querySelectorAll: () => [{ checked: true, value: 'compliance' }],
      createElement: () => element(Symbol())
    },
    window: { location: { search: '' }, addEventListener() {}, scrollTo() {} },
    URLSearchParams,
    fetch: async (url, options) => {
      requests.push({ url, payload: options?.body && JSON.parse(options.body) });
      const body = respond(url);
      return { ok: httpOk, status: httpStatus, json: async () => url === '/api/state' ?
        { auth: { connected: true, scopes: [] }, policies: { status: 'ready' }, ...body } : body };
    },
    setInterval(callback) { timers.push(callback); return timers.length; },
    clearInterval(id) { timers[id - 1] = null; }, setTimeout() {},
    alert(message) { throw new Error(message); }
  });
  await installI18n(context).ready;
  vm.runInContext(fs.readFileSync(path.join(__dirname, '..', 'web', 'app.js'), 'utf8'), context);
  return { element, requests, context, timers };
}

test('export sends the selected Azure DevOps repository and branch and commits when pushing', async () => {
  const { element, requests } = await dashboard();
  await new Promise(setImmediate);
  element('gitRemoteUrl').value = ' https://dev.azure.com/org/project/_git/docs ';
  element('gitBranch').value = ' docs/update ';
  element('optPush').checked = true;
  await element('btnExport').handlers.click();
  const request = requests.find((r) => r.url === '/api/export');
  assert.equal(request.payload.gitRemoteUrl, 'https://dev.azure.com/org/project/_git/docs');
  assert.equal(request.payload.gitBranch, 'docs/update');
  assert.equal(request.payload.gitCommit, true);
  assert.equal(request.payload.gitPush, true);
});

test('entering a repository enables publishing and pushing keeps commit selected', async () => {
  const { element } = await dashboard();
  element('gitRemoteUrl').value = 'https://dev.azure.com/org/project/_git/docs';
  element('gitRemoteUrl').handlers.change();
  assert.equal(element('optPush').checked, true);
  assert.equal(element('optGit').checked, true);
  element('optGit').checked = false;
  element('optGit').handlers.change();
  assert.equal(element('optGit').checked, true);
});

test('sign-out clears the previous tenant publishing destination', async () => {
  const { element, context } = await dashboard();
  element('gitRemoteUrl').value = 'https://dev.azure.com/org/project/_git/docs';
  element('gitBranch').value = 'docs';
  vm.runInContext('clearWorkspace()', context);
  assert.equal(element('gitRemoteUrl').value, '');
  assert.equal(element('gitBranch').value, '');
  assert.equal(element('optPush').checked, false);
  assert.equal(element('optGit').checked, false);
});

test('a successful retry displays the push even without a new commit', async () => {
  const { element, context } = await dashboard();
  vm.runInContext('renderSummary({ git: { committed: false, pushed: true }, stats: {} })', context);
  assert.match(element('summary').innerHTML, /pushed to remote/i);
});

test('Git warnings are displayed as text instead of executable HTML', async () => {
  const { element, context } = await dashboard();
  vm.runInContext('renderSummary({ warnings: ["<script>bad()</script>"], stats: {} })', context);
  assert.doesNotMatch(element('summary').innerHTML, /<script>/);
  assert.match(element('summary').innerHTML, /&lt;script&gt;/);
});

test('build identity marks beta in the name and title and removes the marker for stable', async () => {
  const { element, context } = await dashboard();
  const render = (build) => vm.runInContext('renderBuild(' + JSON.stringify(build) + ')', context);
  render({ version: '0.1.0', channel: 'beta', commit: 'development' });
  assert.equal(element('appName').textContent, 'Intune Docs Studio (beta)');
  assert.equal(context.document.title, 'Intune Docs Studio (beta)');
  assert.match(element('buildInfo').textContent, /0\.1\.0/);
  render({ version: '0.1.0', channel: 'beta', commit: 'development' });
  assert.equal(element('appName').textContent, 'Intune Docs Studio (beta)');
  render({ version: '1.0.0', channel: 'stable', commit: 'a'.repeat(40) });
  assert.equal(element('appName').textContent, 'Intune Docs Studio');
  assert.equal(context.document.title, 'Intune Docs Studio');
  assert.match(element('buildInfo').textContent, /1\.0\.0/);
});
test('refreshing state displays the build identity reported by the server', async () => {
  const build = { version: '0.2.0', channel: 'beta', commit: 'development' };
  const { element, context } = await dashboard((url) => (url === '/api/state' ? { build, auth: {} } : {}));
  await vm.runInContext('refreshState()', context);
  assert.equal(element('appName').textContent, 'Intune Docs Studio (beta)');
  assert.equal(context.document.title, 'Intune Docs Studio (beta)');
  assert.match(element('buildInfo').textContent, /0\.2\.0/);
});

test('portal sign-in sends the selected browser and account picker preference', async () => {
  const { element, requests, timers } = await dashboard(() => ({ started: true }));
  element('portalBrowser').value = 'chrome';
  element('tenant').value = ' organizations ';
  element('optForcePicker').checked = true;
  await element('btnBrowser').handlers.click();
  const request = requests.find((r) => r.url === '/api/signin/browser');
  assert.deepEqual(request.payload, { tenant: 'organizations', forcePicker: true, browser: 'chrome' });
  assert.equal(timers.length, 1);
});

test('portal browser markup defaults to automatic and includes explicit choices', () => {
  const html = fs.readFileSync(path.join(__dirname, '..', 'web', 'index.html'), 'utf8');
  const select = html.match(/<select id="portalBrowser"[^>]*>([\s\S]*?)<\/select>/)[1];
  assert.deepEqual([...select.matchAll(/value="([^"]+)"/g)].map((m) => m[1]), ['auto', 'edge', 'chrome']);
});

test('a rejected portal start displays the server error and does not poll or change browsers', async () => {
  const { element, requests, timers } = await dashboard(() => ({ error: 'Select auto, edge or chrome.' }),
    { httpOk: false, httpStatus: 400 });
  element('portalBrowser').value = 'invalid';
  await element('btnBrowser').handlers.click();
  assert.equal(element('btnBrowser').disabled, false);
  assert.equal(element('signinError').textContent, 'Select auto, edge or chrome.');
  assert.equal(timers.length, 0);
  assert.equal(requests.filter((r) => r.url === '/api/signin/browser').length, 1);
  assert.equal(element('portalBrowser').value, 'invalid');
});

test('policy diagnostics from the sign-in worker are shown as text without browser fallback', async () => {
  const message = 'RemoteDebuggingAllowed at HKLM: disabled. Check edge://policy. <not HTML>';
  const { element, requests, timers } = await dashboard((url) =>
    url === '/api/signin/browser/status' ? { running: false, error: message } : { started: true });
  element('portalBrowser').value = 'edge';
  await element('btnBrowser').handlers.click();
  await timers[0]();
  assert.equal(element('signinError').textContent, message);
  assert.equal(element('btnBrowser').disabled, false);
  assert.equal(element('portalBrowser').value, 'edge');
  assert.equal(timers[0], null);
  assert.equal(requests.filter((r) => r.url === '/api/signin/browser').length, 1);
});

test('a network failure starting portal sign-in restores the button and displays the error', async () => {
  const { element, timers } = await dashboard((url) => {
    if (url === '/api/signin/browser') throw new Error('Network unavailable');
    return {};
  });
  await element('btnBrowser').handlers.click();
  assert.equal(element('btnBrowser').disabled, false);
  assert.equal(element('signinError').textContent, 'Network unavailable');
  assert.equal(timers.length, 0);
});

test('a status network failure stops polling and restores the sign-in button', async () => {
  const { element, timers } = await dashboard((url) => {
    if (url === '/api/signin/browser/status') throw new Error('Status unavailable');
    return { started: true };
  });
  await element('btnBrowser').handlers.click();
  await timers[0]();
  assert.equal(element('btnBrowser').disabled, false);
  assert.equal(element('signinError').textContent, 'Status unavailable');
  assert.equal(timers[0], null);
});

test('forget saved sessions surfaces deletion errors instead of claiming success', async () => {
  const { element } = await dashboard(() => ({ error: 'Profile is locked' }), { httpOk: false, httpStatus: 400 });
  await element('btnForget').handlers.click();
  assert.equal(element('signinError').textContent, 'Profile is locked');
  assert.notEqual(element('bsText').textContent, 'Saved Edge and Chrome sessions cleared.');
});
