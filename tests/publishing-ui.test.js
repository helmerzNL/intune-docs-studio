'use strict';

const { test } = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');
const { installI18n, withoutTranslationSpans } = require('./i18n-test-helpers');

async function dashboard(respond = () => ({})) {
  const elements = new Map();
  const requests = [];
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
      return { ok: true, status: 200, json: async () => url === '/api/state' ?
        { auth: { connected: true, scopes: [] }, policies: { status: 'ready' }, ...respond(url) } : respond(url) };
    },
    setInterval() {}, clearInterval() {}, setTimeout() {},
    alert(message) { throw new Error(message); }
  });
  await installI18n(context).ready;
  vm.runInContext(fs.readFileSync(path.join(__dirname, '..', 'web', 'app.js'), 'utf8'), context);
  return { element, requests, context };
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
