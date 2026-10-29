'use strict';

const { test } = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');

function assessmentDashboard(respond = () => ({})) {
  const elements = new Map();
  const requests = [];
  const timers = new Map();
  const alerts = [];
  let focused = null;
  function element(id) {
    if (!elements.has(id)) {
      const classes = new Set();
      const attributes = new Map();
      const el = {
        id, value: '', checked: false, disabled: false, children: [], options: [], handlers: {},
        files: [], textContent: '', style: {}, dataset: {},
        classList: { add(name) { classes.add(name); }, remove(name) { classes.delete(name); },
          contains(name) { return classes.has(name); } },
        addEventListener(event, handler) { this.handlers[event] = handler; },
        appendChild(child) { this.children.push(child); },
        setAttribute(name, value) { attributes.set(name, String(value)); },
        getAttribute(name) { return attributes.has(name) ? attributes.get(name) : null; },
        removeAttribute(name) { attributes.delete(name); },
        focus() { focused = id; },
        scrollIntoView() {}
      };
      let html = '';
      Object.defineProperty(el, 'innerHTML', {
        get() { return html; }, set(value) { html = value; el.children = []; }
      });
      elements.set(id, el);
    }
    return elements.get(id);
  }
  const descendants = (el) => el.children.flatMap((child) => [child, ...descendants(child)]);
  const context = vm.createContext({
    document: {
      body: element('body'),
      getElementById: element,
      querySelectorAll(selector) {
        if (selector === '#sections input') return [{ checked: true, value: 'compliance' }];
        const id = selector.split(' ')[0].slice(1);
        return descendants(element(id)).filter((el) => el.type === 'checkbox');
      },
      createElement: () => element(Symbol())
    },
    window: { location: { search: '' }, history: { replaceState() {} }, addEventListener() {}, scrollTo() {} },
    URLSearchParams, TextEncoder, btoa,
    fetch: async (url, options) => {
      const request = { url, payload: options && JSON.parse(options.body), method: options?.method || 'GET' };
      requests.push(request);
      const response = await respond(url, request) || {};
      const status = response.httpStatus || 200;
      return { ok: status >= 200 && status < 300, status,
        json: async () => response.body === undefined ? response : response.body };
    },
    setInterval(fn) { const id = Symbol(); timers.set(id, fn); return id; },
    clearInterval(id) { timers.delete(id); }, setTimeout() {},
    alert(message) { alerts.push(message); }, confirm() { return true; }
  });
  vm.runInContext(fs.readFileSync(path.join(__dirname, '..', 'web', 'app.js'), 'utf8'), context);
  return { element, requests, context, timers, alerts, focused: () => focused,
    run(code) { return vm.runInContext(code, context); } };
}

test('assessment rendering treats imported control names as text', () => {
  const { element, run } = assessmentDashboard();
  run(`renderAssessmentResult({
    summaries: [],
    controls: [{
      controlId: 'SYN-1', title: '<script>bad()</script>',
      status: 'notAssessed', reason: 'Unsupported mapping',
      expected: true, observed: [], policyResults: [], references: []
    }]
  })`);
  assert.doesNotMatch(element('assessmentResults').innerHTML, /<script>/);
  assert.match(element('assessmentResults').innerHTML, /&lt;script&gt;/);
});

test('readable policy tables show shared documentation formatting and escape every cell', () => {
  const d = assessmentDashboard();
  d.run(`renderAssessmentResult({
    policies: [{ key: 'settingsCatalog:synthetic', name: 'Firewall policy', assignmentsComplete: true,
      settingsNote: 'Supported evidence only', settingsTables: [{
        title: '<Security>', headers: ['Setting', 'Value'],
        rows: [{ cells: ['Enable firewall', 'Enabled'] }, { cells: ['<script>bad()</script>', 'No'] }]
      }] }],
    controls: [{ controlId: 'SYN-1', title: 'Firewall check',
      expected: [{ settingId: 'synthetic_enableFirewall', expected: 'synthetic_enableFirewall_1',
        operator: 'eq', displayName: 'Enable firewall', displayValue: 'Enabled' }],
      observed: [{ settingId: 'synthetic_enableFirewall', value: 'synthetic_enableFirewall_1',
        displayName: 'Enable firewall', displayValue: 'Enabled' }],
      policyResults: [{ policyKey: 'settingsCatalog:synthetic', status: 'aligned', reason: 'Matches' }] }]
  })`);
  for (const id of ['assessmentPolicies', 'assessmentResults']) {
    const html = d.element(id).innerHTML;
    assert.match(html, /<th scope="col">Setting<\/th>/);
    assert.match(html, /<td>Enable firewall<\/td><td>Enabled<\/td>/);
    assert.match(html, /&lt;Security&gt;/);
    assert.match(html, /&lt;script&gt;/);
    assert.doesNotMatch(html, /<script>/);
  }
  assert.match(d.element('assessmentPolicies').innerHTML, /<details><summary>Technical policy/);
  const primary = d.element('assessmentResults').innerHTML.replace(/<details>.*?<\/details>/gs, '');
  assert.match(primary, /<strong>Enable firewall<\/strong>: eq Enabled/);
  assert.doesNotMatch(primary, /synthetic_enableFirewall_1/);
  assert.match(d.element('assessmentResults').innerHTML, /Exact typed evidence/);
});

test('evidence shows every status, typed values, assignment limits, sources and filters without compliance claims', () => {
  const { element, run } = assessmentDashboard();
  const statuses = ['aligned', 'misaligned', 'missing', 'potentialConflict', 'notApplicable', 'notAssessed'];
  const result = {
    context: { platforms: ['windows11'], osVersions: { windows11: '10.0.22000' } },
    packs: [{ id: 'synthetic', version: '1.0.0', sha256: 'a'.repeat(64), coverage: { inventory: 'partial' } }],
    summaries: [{ packId: 'synthetic', platform: 'windows11', profile: 'Test',
      inventory: 'partial', counts: { aligned: 1, misaligned: 1, missing: 1, potentialConflict: 1,
        notApplicable: 1, notAssessed: 1 }, assessed: 4, coverageDenominator: 5,
      coveragePercent: 80, alignmentPercent: 25 }],
    controls: statuses.map((status, index) => ({
      controlId: `SYN-${index}`, title: `Rule ${index}`, status, reason: '<incomplete>',
      expected: [{ family: 'deviceConfiguration', policyTypes: ['testType'], property: 'test',
        valueType: 'boolean', operator: 'eq', expected: false }],
      observed: [{ policyKey: 'deviceConfiguration:test', value: 0, configured: true }],
      policyResults: [{ policyKey: 'deviceConfiguration:test', status: 'misaligned', reason: 'Mismatch',
        assigned: false, assignmentsComplete: true }],
      references: [{ url: 'javascript:bad()', reference: '<reference>', revision: 'fixed' }]
    })),
    policies: [{ key: 'deviceConfiguration:test', name: '<Policy>', family: 'deviceConfiguration',
      assignmentsComplete: false, assignments: [{ target: { '@odata.type': 'exclusionGroupAssignmentTarget',
        groupId: 'synthetic-group', deviceAndAppManagementAssignmentFilterId: 'filter-test',
        deviceAndAppManagementAssignmentFilterType: 'exclude' } }] }],
    sources: [{ family: 'settingsCatalog', platform: 'windows11', complete: false }],
    collectionIssues: [{ family: 'settingsCatalog', reason: '<denied>', stage: 'settings', statusCode: 403 }]
  };
  run(`renderAssessmentResult(${JSON.stringify(result)})`);
  const html = element('assessmentResults').innerHTML;
  for (const label of ['Aligned', 'Misaligned', 'Missing', 'Potential conflict', 'Not applicable', 'Not assessed']) {
    assert.match(html, new RegExp(label));
  }
  for (const text of ['false', '0', 'Unassigned', 'Assignment evidence incomplete', 'synthetic-group',
    'filter-test', 'exclusionGroupAssignmentTarget', '&lt;Policy&gt;', 'deviceConfiguration', '&lt;reference&gt;']) {
    assert.ok(html.includes(text), text);
  }
  assert.doesNotMatch(html, /href="javascript:/);
  assert.match(element('assessmentSummary').innerHTML, /Assessment coverage.*80%/s);
  assert.match(element('assessmentSummary').innerHTML, /Configuration alignment.*25%/s);
  assert.match(element('assessmentSummary').innerHTML, /Not assessed.*1/s);
  assert.match(element('assessmentLimitations').textContent, /mapped famil/i);
  assert.match(element('assessmentIssues').textContent, /denied/);
  element('assessmentStatusFilter').value = 'potentialConflict';
  element('assessmentStatusFilter').handlers.change();
  assert.match(element('assessmentResults').innerHTML, /SYN-3/);
  assert.doesNotMatch(element('assessmentResults').innerHTML, /SYN-0/);
  run('renderAssessmentResult({ summaries: [{ counts: {}, coveragePercent: null, alignmentPercent: null }], controls: [] })');
  assert.match(element('assessmentSummary').innerHTML, /not available/);
});

const syntheticPacks = () => ['windows11', 'macos', 'iosIpados', 'androidEnterprise'].map((platform, i) => ({
  schemaVersion: 1, id: `synthetic-${platform.toLowerCase()}`, version: '1.0.0', sha256: String(i).repeat(64),
  origin: i === 3 ? 'imported' : 'bundled',
  framework: i === 3 ? 'CIS' : 'Microsoft', classification: i === 0 ? 'baseline' : 'recommendations',
  platform, profile: i === 3 ? 'Imported test profile' : 'Test profile',
  frameworkVersion: 'Synthetic revision', sourceRevision: 'fixed synthetic revision',
  coverage: { inventory: 'partial', totalSourceControls: null },
  sources: [{ url: 'https://example.invalid/synthetic', revision: 'fixed' }]
}));
const boxes = (d, root) => d.element(root).children.map((label) => label.children[0]);
const renderCatalog = (d, packs = syntheticPacks()) =>
  d.run(`renderAssessmentPacks(${JSON.stringify({ packs, errors: [] })})`);

test('imported Microsoft authority is author-declared, never an official reviewed baseline', () => {
  const d = assessmentDashboard();
  renderCatalog(d, [{ ...syntheticPacks()[0], origin: 'imported' }]);
  const html = d.element('assessmentPacks').children[0].children[1].innerHTML;
  assert.match(html, /customer-imported/i);
  assert.match(html, /author-declared/i);
  assert.match(html, /Microsoft/);
  assert.match(html, /baseline/);
  assert.doesNotMatch(html, /Official Microsoft|reviewed bundled/i);
  renderCatalog(d, [{ ...syntheticPacks()[0], origin: null }]);
  assert.doesNotMatch(d.element('assessmentPacks').children[0].children[1].innerHTML, /Official Microsoft/);
});

test('iOS ownership starts unknown and is described as explicit user comparison context', async () => {
  const html = fs.readFileSync(path.join(__dirname, '..', 'web', 'index.html'), 'utf8');
  assert.match(html, /id="assessmentIosOwnership">\s*<option value="">Unknown<\/option>/);
  assert.doesNotMatch(html, /personal scope is determined from policy evidence/);
  const d = assessmentDashboard((url) => url === '/api/state' ? connectedState() : {});
  await selectAll(d);
  await d.element('btnAssessmentRun').handlers.click();
  const request = d.requests.find((r) => r.url === '/api/assessment' && r.method === 'POST');
  assert.equal(request.payload.context.enrollmentModes.iosIpados, undefined);
  d.element('assessmentIosOwnership').value = 'personallyOwned';
  d.run('clearAssessment()');
  assert.equal(d.element('assessmentIosOwnership').value, '');
});

test('catalog uses exact metadata, platform and profile selections and disables unavailable combinations', () => {
  const d = assessmentDashboard();
  renderCatalog(d);
  const platforms = boxes(d, 'assessmentPlatforms');
  platforms[0].checked = true;
  platforms[0].handlers.change();
  let packs = boxes(d, 'assessmentPacks');
  assert.equal(packs[0].disabled, false);
  assert.equal(packs[1].disabled, true);
  assert.equal(packs[0].value, 'synthetic-windows11@1.0.0#' + '0'.repeat(64));
  packs[0].checked = true;
  d.element('assessmentProfile').value = 'Imported test profile';
  d.element('assessmentProfile').handlers.change();
  assert.equal(packs[0].disabled, true);
  assert.equal(packs[0].checked, false);
  platforms[3].checked = true;
  platforms[3].handlers.change();
  assert.equal(packs[3].disabled, false);
  const text = d.element('assessmentPacks').children.map((label) => label.children[1].innerHTML).join('');
  assert.match(text, /Official Microsoft security baseline/);
  assert.match(text, /Microsoft recommendations/);
  assert.match(text, /CIS.*customer-imported/i);
  assert.match(text, /partial/);
  assert.match(text, /fixed synthetic revision/);
  renderCatalog(d, syntheticPacks().slice(0, 1));
  assert.equal(boxes(d, 'assessmentPlatforms')[1].disabled, true);
  assert.match(d.element('assessmentCatalogNote').textContent, /unavailable/i);
  assert.match(d.element('assessmentCatalogNote').textContent, /five bundled checks/i);
  for (const word of ['legacy', 'personal', 'beta', 'deprecated', 'modern']) {
    assert.match(d.element('assessmentCatalogNote').textContent, new RegExp(word, 'i'));
  }
});

test('import sends original JSON text and preserves selected pack and export options on validation failure', async () => {
  let reject = false;
  const d = assessmentDashboard((url, r) => {
    if (url === '/api/assessment/packs' && r.method === 'POST') {
      return reject ? { httpStatus: 400, body: { error: '<Invalid pack>' } }
        : { httpStatus: 201, body: { pack: syntheticPacks()[3] } };
    }
    return {};
  });
  renderCatalog(d);
  const platforms = boxes(d, 'assessmentPlatforms');
  platforms[0].checked = true;
  platforms[0].handlers.change();
  boxes(d, 'assessmentPacks')[0].checked = true;
  d.element('outputPath').value = 'C:\\SyntheticExport';
  d.element('optRaw').checked = true;
  d.element('gitBranch').value = 'docs';
  const original = ' {\r\n "schemaVersion": 1, "title": "\\u003csynthetic\\u003e" \r\n}\n';
  d.element('assessmentImportFile').files = [{ name: 'synthetic.json', size: original.length,
    text: async () => original }];
  await d.element('btnAssessmentImport').handlers.click();
  assert.equal(d.requests.find((r) => r.method === 'POST').payload.content, original);
  assert.equal(boxes(d, 'assessmentPacks')[0].checked, true);
  assert.match(d.element('assessmentImportSummary').textContent, /locally/);
  assert.equal(d.element('assessmentProgress').textContent, '');
  reject = true;
  await d.element('btnAssessmentImport').handlers.click();
  assert.match(d.element('assessmentError').textContent, /400.*<Invalid pack>/);
  assert.equal(boxes(d, 'assessmentPacks')[0].checked, true);
  assert.equal(d.element('outputPath').value, 'C:\\SyntheticExport');
  assert.equal(d.element('optRaw').checked, true);
  assert.equal(d.element('gitBranch').value, 'docs');
});

test('import bounds files before reading and checks decoded UTF-8 bytes before submission', async () => {
  const d = assessmentDashboard();
  let reads = 0;
  for (const file of [
    { name: 'pack.pdf', size: 2 },
    { name: 'pack.json', size: 10 * 1024 * 1024 + 1 },
    { name: 'empty.json', size: 0 }
  ]) {
    d.element('assessmentImportFile').files = [{ ...file, text: async () => { reads++; return '{}'; } }];
    await d.element('btnAssessmentImport').handlers.click();
  }
  assert.equal(reads, 0);
  d.element('assessmentImportFile').files = [{ name: 'pack.json', size: 1,
    text: async () => 'é'.repeat(6 * 1024 * 1024) }];
  await d.element('btnAssessmentImport').handlers.click();
  assert.match(d.element('assessmentError').textContent, /10 MiB/);
  assert.equal(d.requests.filter((r) => r.method === 'POST').length, 0);
});

const connectedState = (tenantId = 'synthetic-tenant') => ({
  auth: { connected: true, tenantId, account: 'synthetic@example.invalid', scopes: [] },
  policies: { status: 'ready', count: 0, families: [], issues: [] },
  export: { running: false }
});
async function selectAll(d) {
  await new Promise(setImmediate);
  await d.run('refreshState()');
  renderCatalog(d);
  for (const box of boxes(d, 'assessmentPlatforms')) box.checked = true;
  boxes(d, 'assessmentPlatforms')[0].handlers.change();
  for (const box of boxes(d, 'assessmentPacks')) box.checked = true;
  d.element('assessmentOutputPath').value = ' C:\\SyntheticReports ';
}

test('four-platform assessment submits snapshot identities and exact context, polls 202 and renders only server report paths', async () => {
  let done = false;
  let started = false;
  const d = assessmentDashboard((url, r) => {
    if (url === '/api/state') return connectedState();
    if (url === '/api/assessment' && r.method === 'POST') {
      started = true;
      return { httpStatus: 202, body: { started: true, runId: 'synthetic-run' } };
    }
    if (url === '/api/assessment') return { running: started && !done, done, percent: done ? 100 : 35,
      phase: 'Collecting synthetic policies', partial: done,
      reportPaths: done ? { markdownPath: 'C:\\SyntheticReports\\server-run\\assessment.md',
        jsonPath: 'C:\\SyntheticReports\\server-run\\assessment.json' } : null };
    if (url === '/api/assessment/results') return { summaries: [], controls: [
      { controlId: 'SYN-WIN', status: 'aligned', title: 'Synthetic Windows' },
      { controlId: 'SYN-MAC', status: 'notAssessed', title: 'Synthetic macOS' },
      { controlId: 'SYN-IOS', status: 'missing', title: 'Synthetic iOS' },
      { controlId: 'SYN-ANDROID', status: 'misaligned', title: 'Synthetic Android' }
    ] };
    return {};
  });
  await selectAll(d);
  d.element('assessmentOsWindows11').value = '10.0.22000';
  d.element('assessmentOsMacos').value = '14.0';
  d.element('assessmentEnrollment').value = 'workProfile';
  d.element('assessmentIosOwnership').value = 'personallyOwned';
  d.element('outputPath').value = 'C:\\SyntheticExport';
  d.element('gitBranch').value = 'docs';
  d.element('optRaw').checked = true;
  await d.element('btnAssessmentRun').handlers.click();
  const request = d.requests.find((r) => r.url === '/api/assessment' && r.method === 'POST');
  assert.deepEqual(request.payload, {
    packIds: syntheticPacks().map((p) => `${p.id}@1.0.0#${p.sha256}`),
    context: { platforms: ['windows11', 'macos', 'iosIpados', 'androidEnterprise'],
      osVersions: { windows11: '10.0.22000', macos: '14.0' },
      enrollmentModes: { androidEnterprise: 'workProfile', iosIpados: 'personallyOwned' } },
    outputPath: 'C:\\SyntheticReports'
  });
  assert.equal(d.element('btnExport').disabled, true);
  assert.equal(d.element('btnAssessmentRun').disabled, true);
  assert.match(d.element('assessmentProgress').textContent, /35%.*Collecting/);
  assert.equal(d.element('assessmentReportPaths').textContent, '');
  const before = d.requests.filter((r) => r.url === '/api/export').length;
  await d.element('btnExport').handlers.click();
  assert.equal(d.requests.filter((r) => r.url === '/api/export').length, before);
  assert.equal(d.timers.size, 1);
  done = true;
  await Array.from(d.timers.values())[0]();
  assert.match(d.element('assessmentReportPaths').textContent, /server-run\\assessment.md/);
  assert.match(d.element('assessmentProgress').textContent, /partial/i);
  for (const id of ['SYN-WIN', 'SYN-MAC', 'SYN-IOS', 'SYN-ANDROID']) {
    assert.match(d.element('assessmentResults').innerHTML, new RegExp(id));
  }
  assert.equal(d.element('btnExport').disabled, false);
  assert.equal(d.timers.size, 0);
  assert.equal(d.element('outputPath').value, 'C:\\SyntheticExport');
  assert.equal(d.element('gitBranch').value, 'docs');
  assert.equal(d.element('optRaw').checked, true);
});

test('admission validates missing packs/platforms, handles 409 and report errors without losing selection', async () => {
  let startStatus = 409;
  const d = assessmentDashboard((url, r) => {
    if (url === '/api/state') return connectedState();
    if (url === '/api/assessment' && r.method === 'POST') return { httpStatus: startStatus,
      body: startStatus === 409 ? { error: 'An export is already running.' } : { started: true } };
    if (url === '/api/assessment') return { done: true, running: false, error: 'Report write failed.',
      reportPaths: { markdownPath: 'must-not-show' } };
    return {};
  });
  await selectAll(d);
  boxes(d, 'assessmentPacks')[2].checked = false;
  await d.element('btnAssessmentRun').handlers.click();
  assert.match(d.element('assessmentError').textContent, /Every selected platform/);
  assert.equal(d.requests.filter((r) => r.method === 'POST').length, 0);
  boxes(d, 'assessmentPacks')[2].checked = true;
  await d.element('btnAssessmentRun').handlers.click();
  assert.match(d.element('assessmentError').textContent, /409.*already running/);
  assert.equal(boxes(d, 'assessmentPacks')[0].checked, true);
  assert.equal(d.element('assessmentOutputPath').value, ' C:\\SyntheticReports ');
  assert.equal(d.element('btnExport').disabled, false);
  startStatus = 202;
  await d.element('btnAssessmentRun').handlers.click();
  assert.match(d.element('assessmentError').textContent, /Report write failed/);
  assert.equal(d.element('assessmentReportPaths').textContent, '');
});

test('idle refresh preserves pending assessment admission and export settings until the POST resolves', async () => {
  for (const outcome of ['409', 'network']) {
    const previousEvidence = outcome === 'network';
    let finish;
    const d = assessmentDashboard((url, r) => {
      if (url === '/api/state') return connectedState();
      if (url === '/api/assessment' && r.method === 'POST') {
        return new Promise((resolve, reject) => {
          finish = () => outcome === 'network'
            ? reject(new Error('Synthetic admission connection failed.'))
            : resolve({ httpStatus: 409, body: { error: 'Synthetic admission rejected.' } });
        });
      }
      if (url === '/api/assessment') return { running: false, done: false };
      return {};
    });
    await selectAll(d);
    d.element('outputPath').value = 'C:\\SyntheticExport';
    d.element('optRaw').checked = true;
    d.element('gitBranch').value = 'docs';
    if (previousEvidence) {
      d.run('renderAssessmentResult({ summaries: [], controls: [{ controlId: "PREVIOUS" }] })');
      d.element('assessmentReportPaths').textContent = 'Previous server paths';
    }
    const pending = d.element('btnAssessmentRun').handlers.click();
    assert.equal(d.element('btnExport').disabled, true);
    assert.equal(d.element('btnAssessmentRun').disabled, true);
    await d.element('btnAssessmentRefresh').handlers.click();
    assert.equal(d.element('btnExport').disabled, true);
    assert.equal(d.element('btnAssessmentRun').disabled, true);
    assert.equal(d.element('btnAssessmentImport').disabled, true);
    assert.equal(d.element('assessmentOutputPath').value, ' C:\\SyntheticReports ');
    await d.element('btnExport').handlers.click();
    await d.element('btnAssessmentRun').handlers.click();
    await d.element('btnAssessmentImport').handlers.click();
    assert.equal(d.requests.filter((r) => r.method === 'POST').length, 1);
    finish();
    await pending;
    assert.match(d.element('assessmentError').textContent,
      outcome === 'network' ? /admission connection failed/ : /409.*admission rejected/);
    assert.equal(d.element('btnExport').disabled, false);
    assert.equal(d.element('btnAssessmentRun').disabled, false);
    assert.equal(d.element('btnAssessmentImport').disabled, false);
    assert.equal(d.element('outputPath').value, 'C:\\SyntheticExport');
    assert.equal(d.element('optRaw').checked, true);
    assert.equal(d.element('gitBranch').value, 'docs');
  }
});

test('tenant reset releases admission but a stale POST cannot release a newer assessment reservation', async () => {
  let tenant = 'synthetic-first';
  let running = false;
  const pendingPosts = [];
  const d = assessmentDashboard((url, r) => {
    if (url === '/api/state') return connectedState(tenant);
    if (url === '/api/assessment' && r.method === 'POST') {
      return new Promise((resolve) => { pendingPosts.push(resolve); });
    }
    if (url === '/api/assessment') return { running, done: false };
    return {};
  });
  await selectAll(d);
  const oldStart = d.element('btnAssessmentRun').handlers.click();
  tenant = 'synthetic-second';
  await d.run('refreshState()');
  assert.equal(d.element('btnExport').disabled, false);
  assert.equal(d.element('btnAssessmentRun').disabled, false);
  assert.equal(d.element('assessmentOutputPath').value, '');
  await selectAll(d);
  const newStart = d.element('btnAssessmentRun').handlers.click();
  pendingPosts[0]({ httpStatus: 401, body: { error: 'Old session expired.' } });
  await oldStart;
  await d.element('btnAssessmentRefresh').handlers.click();
  assert.equal(d.element('btnExport').disabled, true);
  assert.equal(d.element('btnAssessmentRun').disabled, true);
  assert.equal(d.element('assessmentOutputPath').value, ' C:\\SyntheticReports ');
  assert.equal(d.element('assessmentProgress').textContent.includes('admitted'), false);
  running = true;
  pendingPosts[1]({ httpStatus: 202, body: { started: true } });
  await newStart;
  assert.equal(d.element('btnExport').disabled, true);
  assert.equal(d.element('btnAssessmentRun').disabled, true);
  running = false;
  await d.element('btnAssessmentRefresh').handlers.click();
  assert.equal(d.element('btnExport').disabled, false);
  assert.equal(d.element('btnAssessmentRun').disabled, false);
});

test('an in-flight export disables assessment admission, including before export returns', async () => {
  let finish;
  const d = assessmentDashboard((url, r) => {
    if (url === '/api/state') return connectedState();
    if (url === '/api/export' && r.method === 'POST') return new Promise((resolve) => { finish = resolve; });
    return {};
  });
  await selectAll(d);
  const exporting = d.element('btnExport').handlers.click();
  assert.equal(d.element('btnAssessmentRun').disabled, true);
  await d.element('btnAssessmentRun').handlers.click();
  assert.equal(d.requests.some((r) => r.url === '/api/assessment' && r.method === 'POST'), false);
  finish({ error: 'Synthetic export failure' });
  await exporting;
  assert.equal(d.element('btnAssessmentRun').disabled, false);
});

test('clearWorkspace clears assessment evidence, context and report destination while stale progress cannot restore them', async () => {
  let release;
  let hold = false;
  const d = assessmentDashboard((url) => {
    if (url === '/api/state') return connectedState();
    if (url === '/api/assessment' && hold) return new Promise((resolve) => { release = resolve; });
    return {};
  });
  await selectAll(d);
  d.run('renderAssessmentResult({ controls: [{ controlId: "OLD", title: "Previous tenant" }], summaries: [] })');
  d.element('assessmentReportPaths').textContent = 'Old server paths';
  d.element('assessmentOsMacos').value = '14.0';
  hold = true;
  const polling = d.run('refreshAssessment()');
  await new Promise(setImmediate);
  d.run('clearWorkspace()');
  release({ running: false, done: true, percent: 100, reportPaths: { markdownPath: 'stale', jsonPath: 'stale' } });
  await polling;
  for (const id of ['assessmentResults', 'assessmentSummary']) assert.equal(d.element(id).innerHTML, '');
  for (const id of ['assessmentReportPaths', 'assessmentOutputPath', 'assessmentOsMacos']) {
    assert.equal(d.element(id).value || d.element(id).textContent, '');
  }
  assert.equal(d.requests.some((r) => r.url === '/api/assessment/results'), false);
});

test('tenant change clears evidence and rejects an in-flight results response', async () => {
  let tenant = 'synthetic-first';
  let hold = false;
  let release;
  const d = assessmentDashboard((url) => {
    if (url === '/api/state') return connectedState(tenant);
    if (url === '/api/assessment') return hold ? { done: true } : {};
    if (url === '/api/assessment/results') return new Promise((resolve) => { release = resolve; });
    return {};
  });
  await selectAll(d);
  hold = true;
  const polling = d.run('refreshAssessment()');
  await new Promise(setImmediate);
  tenant = 'synthetic-second';
  await d.run('refreshState()');
  release({ controls: [{ controlId: 'STALE', title: 'Old tenant evidence' }], summaries: [] });
  await polling;
  assert.equal(d.element('assessmentResults').innerHTML, '');
  assert.equal(d.element('assessmentOutputPath').value, '');
  assert.equal(d.element('assessmentReportPaths').textContent, '');
});

test('401 on progress or results clears sensitive evidence and 404 resets same-account auth epoch results', async () => {
  for (const stage of ['progress401', 'results401', 'epoch404', 'epochIdle']) {
    let active = false;
    const d = assessmentDashboard((url) => {
      if (url === '/api/state') return connectedState();
      if (url === '/api/assessment' && active) {
        if (stage === 'progress401') return { httpStatus: 401, body: { error: 'Not signed in.' } };
        if (stage === 'epoch404') return { httpStatus: 404, body: { error: 'No assessment in this session.' } };
        return stage === 'epochIdle' ? { running: false, done: false } : { done: true };
      }
      if (url === '/api/assessment/results') return { httpStatus: 401, body: { error: 'Not signed in.' } };
      return {};
    });
    await selectAll(d);
    d.run('renderAssessmentResult({ summaries: [], controls: [{ controlId: "OLD" }] })');
    d.element('assessmentReportPaths').textContent = 'Old paths';
    active = true;
    await d.run('refreshAssessment()');
    assert.equal(d.element('assessmentResults').innerHTML, '', stage);
    assert.equal(d.element('assessmentOutputPath').value, '', stage);
    assert.equal(d.element('assessmentReportPaths').textContent, '', stage);
    if (stage.includes('401')) assert.match(d.element('assessmentError').textContent, /401.*Sign in/);
  }
});

test('signout, saved-session forget, sign-in retry and tenant edits invalidate pending assessment responses immediately', async () => {
  for (const action of ['btnSignout', 'btnForget', 'btnAzureCli', 'tenant']) {
    let releaseProgress;
    let releaseAction;
    let hold = false;
    const d = assessmentDashboard((url, r) => {
      if (url === '/api/state') return connectedState();
      if (url === '/api/assessment' && hold) return new Promise((resolve) => { releaseProgress = resolve; });
      if (r.method === 'POST') return new Promise((resolve) => { releaseAction = resolve; });
      return {};
    });
    await selectAll(d);
    hold = true;
    const polling = d.run('refreshAssessment()');
    await new Promise(setImmediate);
    const acting = action === 'tenant'
      ? d.element('tenant').handlers.change()
      : d.element(action).handlers.click();
    assert.equal(d.element('assessmentOutputPath').value, '', action);
    releaseProgress({ done: true, reportPaths: { markdownPath: 'STALE', jsonPath: 'STALE' } });
    await polling;
    assert.equal(d.element('assessmentResults').innerHTML, '', action);
    assert.equal(d.requests.some((r) => r.url === '/api/assessment/results'), false, action);
    if (releaseAction) releaseAction({});
    await acting;
  }
});

test('stale import completion and assessment admission cannot repopulate a reset session', async () => {
  for (const operation of ['import', 'start']) {
    let release;
    const d = assessmentDashboard((url, r) => {
      if (url === '/api/state') return connectedState();
      if (r.method === 'POST') return new Promise((resolve) => { release = resolve; });
      return {};
    });
    await selectAll(d);
    if (operation === 'import') d.element('assessmentImportFile').files =
      [{ name: 'synthetic.json', size: 2, text: async () => '{}' }];
    const pending = d.element(operation === 'import' ? 'btnAssessmentImport' : 'btnAssessmentRun').handlers.click();
    await new Promise(setImmediate);
    d.run('clearWorkspace()');
    release(operation === 'import' ? { httpStatus: 201, body: { pack: { ...syntheticPacks()[0], id: 'stale-import' } } }
      : { httpStatus: 202, body: { started: true } });
    await pending;
    assert.equal(d.element('assessmentProgress').textContent, '', operation);
    assert.equal(d.element('assessmentImportSummary').textContent, '', operation);
    assert.equal(d.element('assessmentReportPaths').textContent, '', operation);
    assert.equal(d.element('assessmentOutputPath').value, '', operation);
    assert.equal(boxes(d, 'assessmentPacks').some((b) => b.value.startsWith('stale-import')), false);
  }
});

test('an externally running export releases assessment admission when server state becomes idle', async () => {
  let running = true;
  const d = assessmentDashboard((url) => {
    if (url === '/api/state') return { ...connectedState(), export: { running } };
    return {};
  });
  await new Promise(setImmediate);
  assert.equal(d.element('btnAssessmentRun').disabled, true);
  running = false;
  await d.run('refreshState()');
  assert.equal(d.element('btnAssessmentRun').disabled, false);
});

test('catalog responses issued before import cannot replace the newly imported catalog', async () => {
  let releaseCatalog;
  let delayed = false;
  const imported = { ...syntheticPacks()[0], id: 'synthetic-new' };
  const d = assessmentDashboard((url, r) => {
    if (url === '/api/assessment/packs' && r.method === 'POST') return { httpStatus: 201, body: { pack: imported } };
    if (url === '/api/assessment/packs' && delayed) return new Promise((resolve) => { releaseCatalog = resolve; });
    return {};
  });
  await new Promise(setImmediate);
  renderCatalog(d);
  delayed = true;
  const loading = d.run('loadAssessmentCatalog()');
  d.element('assessmentImportFile').files = [{ name: 'synthetic.json', size: 2, text: async () => '{}' }];
  await d.element('btnAssessmentImport').handlers.click();
  releaseCatalog({ packs: syntheticPacks(), errors: [] });
  await loading;
  assert.equal(boxes(d, 'assessmentPacks').some((b) => b.value.startsWith('synthetic-new@')), true);
});

test('all policy evidence flags unassigned and unknown assignments even outside matched controls', () => {
  const d = assessmentDashboard();
  d.run(`renderAssessmentResult({ summaries: [], controls: [], policies: [
    { key: 'synthetic:unassigned', name: '<Unassigned>', assignments: [], assignmentsComplete: true },
    { key: 'synthetic:unknown', assignments: [], assignmentsComplete: false }
  ] })`);
  assert.match(d.element('assessmentPolicies').innerHTML, /Unassigned/);
  assert.match(d.element('assessmentPolicies').innerHTML, /Assignment evidence incomplete/);
  assert.match(d.element('assessmentPolicies').innerHTML, /&lt;Unassigned&gt;/);
});

test('stale export folder and file reads cannot overwrite a reset workspace', async () => {
  let releaseFolder;
  let releaseFiles;
  const d = assessmentDashboard((url) => {
    if (url === '/api/state') return connectedState();
    if (url.startsWith('/api/checkfolder')) return new Promise((resolve) => { releaseFolder = resolve; });
    if (url === '/api/files') return new Promise((resolve) => { releaseFiles = resolve; });
    return {};
  });
  await selectAll(d);
  d.element('outputPath').value = 'C:\\SyntheticExport';
  const folder = d.run('checkFolder()');
  const files = d.run('loadFiles()');
  d.run('clearWorkspace()');
  releaseFolder({ conflict: 'Old tenant folder', suggestion: 'C:\\OldTenant' });
  releaseFiles({ files: [{ path: 'old-tenant.md' }] });
  await Promise.all([folder, files]);
  assert.equal(d.element('folderWarn').classList.contains('hidden'), true);
  assert.equal(d.element('fileList').children.length, 0);
  assert.equal(d.element('outputPath').value, 'C:\\SyntheticExport');
});

test('signout blocks new assessment admission until refreshed authentication is available', async () => {
  let release;
  const d = assessmentDashboard((url, r) => {
    if (url === '/api/state') return connectedState();
    if (r.method === 'POST') return new Promise((resolve) => { release = resolve; });
    return {};
  });
  await selectAll(d);
  const signingOut = d.element('btnSignout').handlers.click();
  assert.equal(d.element('btnAssessmentRun').disabled, true);
  release({});
  await signingOut;
});

test('network and 413 import errors preserve selection and expose actionable text', async () => {
  let network = false;
  const d = assessmentDashboard((url, r) => {
    if (url === '/api/assessment/packs' && r.method === 'POST') {
      if (network) throw new Error('Synthetic connection failed');
      return { httpStatus: 413, body: { error: 'Decoded pack byte limit exceeded.' } };
    }
    return {};
  });
  renderCatalog(d);
  boxes(d, 'assessmentPlatforms')[0].checked = true;
  boxes(d, 'assessmentPlatforms')[0].handlers.change();
  boxes(d, 'assessmentPacks')[0].checked = true;
  d.element('assessmentImportFile').files = [{ name: 'synthetic.json', size: 2, text: async () => '{}' }];
  await d.element('btnAssessmentImport').handlers.click();
  assert.match(d.element('assessmentError').textContent, /413.*byte limit/);
  network = true;
  await d.element('btnAssessmentImport').handlers.click();
  assert.match(d.element('assessmentError').textContent, /connection failed/);
  assert.equal(boxes(d, 'assessmentPacks')[0].checked, true);
  assert.equal(d.element('btnAssessmentImport').disabled, false);
});

test('401 on admission or import resets evidence and disables assessment until sign-in', async () => {
  for (const action of ['btnAssessmentRun', 'btnAssessmentImport']) {
    const d = assessmentDashboard((url, r) => {
      if (url === '/api/state') return connectedState();
      if (r.method === 'POST') return { httpStatus: 401, body: { error: 'Not signed in.' } };
      return {};
    });
    await selectAll(d);
    d.element('assessmentImportFile').files = [{ name: 'synthetic.json', size: 2, text: async () => '{}' }];
    await d.element(action).handlers.click();
    assert.match(d.element('assessmentError').textContent, /401.*Sign in/);
    assert.equal(d.element('assessmentOutputPath').value, '');
    assert.equal(d.element('btnAssessmentRun').disabled, true);
    assert.equal(d.element('connBadge').textContent, 'Not connected');
  }
});

test('discovering another running assessment removes old evidence and report paths without changing destination', async () => {
  let running = false;
  const d = assessmentDashboard((url) => {
    if (url === '/api/state') return connectedState();
    if (url === '/api/assessment') return { running, phase: 'Collecting', percent: 45 };
    return {};
  });
  await selectAll(d);
  d.run('renderAssessmentResult({ summaries: [], controls: [{ controlId: "OLD" }] })');
  d.element('assessmentReportPaths').textContent = 'Old run paths';
  running = true;
  await d.run('refreshAssessment()');
  assert.equal(d.element('assessmentResults').innerHTML, '');
  assert.equal(d.element('assessmentReportPaths').textContent, '');
  assert.equal(d.element('assessmentOutputPath').value, ' C:\\SyntheticReports ');
  assert.match(d.element('assessmentProgress').textContent, /45%/);
});

test('shutdown honors server 409 and permits stopping after a previously observed export finishes', async () => {
  let blocked = true;
  const d = assessmentDashboard((url) => {
    if (url === '/api/state') return { ...connectedState(), export: { running: true } };
    if (url.startsWith('/api/export/log')) return { done: true, running: false };
    if (url === '/api/quit') return blocked
      ? { httpStatus: 409, body: { error: 'An assessment is already running.' } } : { ok: true };
    return {};
  });
  await new Promise(setImmediate);
  await d.run('pollLog()');
  await d.element('btnQuit').handlers.click();
  assert.equal(d.requests.some((r) => r.url === '/api/quit'), true);
  assert.match(d.alerts.at(-1), /assessment.*running/);
  assert.doesNotMatch(d.element('body').innerHTML, /has stopped/);
  blocked = false;
  await d.element('btnQuit').handlers.click();
  assert.match(d.element('body').innerHTML, /has stopped/);
});

// --- Assessment wizard -------------------------------------------------------

const stepIds = ['assessStepPlatforms', 'assessStepBaselines', 'assessStepContext', 'assessStepReview',
  'assessStepResults'];
const panelIds = ['assessPanelPlatforms', 'assessPanelBaselines', 'assessPanelContext', 'assessPanelReview',
  'assessPanelResults'];
const isHidden = (d, id) => d.element(id).classList.contains('hidden');
const click = (d, id) => d.element(id).handlers.click();
const windowsWarning = 'Windows policies targeting Windows 10 and later, such as the Settings Catalog policies ' +
  'that CIS build-kit packs map to, are assessed only when a Windows 11 build is entered (for example 10.0.22631 ' +
  'or 10.0.26100); otherwise their controls are reported as not assessed.';

function expectStep(d, number, focusedHeading) {
  assert.deepEqual(panelIds.filter((id) => !isHidden(d, id)), [panelIds[number - 1]]);
  assert.deepEqual(stepIds.map((id) => d.element(id).className),
    stepIds.map((_, i) => (i + 1 < number ? 'done' : i + 1 === number ? 'active' : '')));
  assert.deepEqual(stepIds.map((id) => d.element(id).getAttribute('aria-current')),
    stepIds.map((_, i) => (i + 1 === number ? 'step' : null)));
  assert.equal(isHidden(d, 'assessImportPanel'), number > 2);
  if (focusedHeading !== undefined) assert.equal(d.focused(), focusedHeading);
}

test('wizard Next and Back validate the current step, mark the stepper and focus the new heading', async () => {
  const d = assessmentDashboard((url) => (url === '/api/state' ? connectedState() : {}));
  await new Promise(setImmediate);
  renderCatalog(d);
  expectStep(d, 1, null);
  click(d, 'btnAssessPlatformsNext');
  assert.equal(d.element('assessmentError').textContent, 'Choose at least one platform to assess.');
  assert.equal(isHidden(d, 'assessmentError'), false);
  expectStep(d, 1, null);
  const platforms = boxes(d, 'assessmentPlatforms');
  platforms[0].checked = true;
  platforms[1].checked = true;
  platforms[0].handlers.change();
  click(d, 'btnAssessPlatformsNext');
  assert.equal(isHidden(d, 'assessmentError'), true);
  expectStep(d, 2, 'baselinesTitle');
  boxes(d, 'assessmentPacks')[0].checked = true;
  click(d, 'btnAssessBaselinesNext');
  assert.equal(d.element('assessmentError').textContent,
    'Every selected platform requires a selected applicable pack; choose at least one platform.');
  expectStep(d, 2, 'baselinesTitle');
  boxes(d, 'assessmentPacks')[1].checked = true;
  click(d, 'btnAssessBaselinesNext');
  assert.equal(isHidden(d, 'assessmentError'), true);
  expectStep(d, 3, 'contextTitle');
  click(d, 'btnAssessContextNext');
  expectStep(d, 4, 'runAssessmentTitle');
  click(d, 'btnAssessReviewBack');
  expectStep(d, 3, 'contextTitle');
  click(d, 'btnAssessContextBack');
  expectStep(d, 2, 'baselinesTitle');
  click(d, 'btnAssessBaselinesBack');
  expectStep(d, 1, 'platformsTitle');
  assert.deepEqual(boxes(d, 'assessmentPacks').map((b) => b.checked), [true, true, false, false]);
  renderCatalog(d, Array.from({ length: 65 }, (_, i) => ({ ...syntheticPacks()[0], id: `synthetic-bulk-${i}` })));
  click(d, 'btnAssessPlatformsNext');
  click(d, 'btnAssessmentSelectAll');
  click(d, 'btnAssessBaselinesNext');
  assert.equal(d.element('assessmentError').textContent, 'Select 1–64 packs.');
  expectStep(d, 2);
});

test('background refresh shows a running or completed assessment without moving focus; errors keep the step', async () => {
  for (const progress of [{ running: true, percent: 20, phase: 'Collecting' }, { done: true, percent: 100 }]) {
    const d = assessmentDashboard((url) => {
      if (url === '/api/state') return connectedState();
      if (url === '/api/assessment') return progress;
      if (url === '/api/assessment/results') return { summaries: [], controls: [{ controlId: 'SYN-BOOT' }] };
      return {};
    });
    await new Promise(setImmediate);
    expectStep(d, 5, null);
  }
  let failing = false;
  const d = assessmentDashboard((url) => {
    if (url === '/api/state') return connectedState();
    if (url === '/api/assessment') return failing ? { done: true, error: 'Synthetic report failure.' } : {};
    return {};
  });
  await new Promise(setImmediate);
  expectStep(d, 1, null);
  d.run("setAssessmentStep('context')");
  failing = true;
  await d.run('refreshAssessment()');
  expectStep(d, 3, null);
  assert.match(d.element('assessmentError').textContent, /Synthetic report failure/);
});

test('admission moves to results with focus and New assessment waits for the run, then keeps every choice', async () => {
  let status = 409;
  let started = false;
  let running = false;
  const d = assessmentDashboard((url, r) => {
    if (url === '/api/state') return connectedState();
    if (url === '/api/assessment' && r.method === 'POST') {
      if (status === 409) return { httpStatus: 409, body: { error: 'An export is already running.' } };
      started = true;
      running = true;
      return { httpStatus: 202, body: { started: true } };
    }
    if (url === '/api/assessment') {
      return { running, done: started && !running, percent: running ? 30 : 100, phase: 'Synthetic' };
    }
    if (url === '/api/assessment/results') return { summaries: [], controls: [{ controlId: 'SYN-NEW' }] };
    return {};
  });
  await selectAll(d);
  d.element('assessmentOsMacos').value = '14.0';
  d.element('assessmentEnrollment').value = 'fullyManaged';
  click(d, 'btnAssessPlatformsNext');
  click(d, 'btnAssessBaselinesNext');
  click(d, 'btnAssessContextNext');
  expectStep(d, 4, 'runAssessmentTitle');
  await click(d, 'btnAssessmentRun');
  assert.match(d.element('assessmentError').textContent, /409.*already running/);
  expectStep(d, 4, 'runAssessmentTitle');
  status = 202;
  await click(d, 'btnAssessmentRun');
  expectStep(d, 5, 'resultsTitle');
  assert.equal(d.element('btnAssessNew').disabled, true);
  click(d, 'btnAssessNew');
  expectStep(d, 5, 'resultsTitle');
  running = false;
  await Array.from(d.timers.values())[0]();
  assert.match(d.element('assessmentResults').innerHTML, /SYN-NEW/);
  assert.equal(d.element('btnAssessNew').disabled, false);
  expectStep(d, 5, 'resultsTitle');
  click(d, 'btnAssessNew');
  expectStep(d, 1, 'platformsTitle');
  assert.equal(boxes(d, 'assessmentPlatforms').every((b) => b.checked), true);
  assert.equal(boxes(d, 'assessmentPacks').every((b) => b.checked), true);
  assert.equal(d.element('assessmentOsMacos').value, '14.0');
  assert.equal(d.element('assessmentEnrollment').value, 'fullyManaged');
  assert.equal(d.element('assessmentOutputPath').value, ' C:\\SyntheticReports ');
  assert.match(d.element('assessmentResults').innerHTML, /SYN-NEW/);
});

test('clearing the workspace returns to step 1 and clears the import summary, review and warning', async () => {
  const d = assessmentDashboard((url) => (url === '/api/state' ? connectedState() : {}));
  await selectAll(d);
  click(d, 'btnAssessPlatformsNext');
  click(d, 'btnAssessBaselinesNext');
  click(d, 'btnAssessContextNext');
  d.element('assessmentImportSummary').textContent = 'Synthetic import summary';
  assert.notEqual(d.element('assessmentReview').textContent, '');
  assert.equal(isHidden(d, 'assessmentContextWarning'), false);
  const focused = d.focused();
  d.run('clearWorkspace()');
  expectStep(d, 1, focused);
  for (const id of ['assessmentImportSummary', 'assessmentReview', 'assessmentContextWarning']) {
    assert.equal(d.element(id).textContent, '', id);
  }
  assert.equal(isHidden(d, 'assessmentContextWarning'), true);
});

test('pack rows outside the selected platforms or profile are hidden, with an empty state and scoped Select all/none', () => {
  const d = assessmentDashboard();
  renderCatalog(d);
  const rowsHidden = () => d.element('assessmentPacks').children.map((row) => row.classList.contains('hidden'));
  const checked = () => boxes(d, 'assessmentPacks').map((b) => b.checked);
  const empty = 'No rule pack matches the selected platforms and profile. ' +
    'Choose other platforms or a different profile, or import a pack below.';
  assert.deepEqual(rowsHidden(), [true, true, true, true]);
  assert.equal(d.element('assessmentPacksEmpty').textContent, empty);
  assert.equal(isHidden(d, 'assessmentPacksEmpty'), false);
  const platforms = boxes(d, 'assessmentPlatforms');
  platforms[0].checked = true;
  platforms[3].checked = true;
  platforms[0].handlers.change();
  assert.deepEqual(rowsHidden(), [false, true, true, false]);
  assert.equal(isHidden(d, 'assessmentPacksEmpty'), true);
  assert.equal(d.element('assessmentPacksEmpty').textContent, '');
  click(d, 'btnAssessmentSelectAll');
  assert.deepEqual(checked(), [true, false, false, true]);
  click(d, 'btnAssessmentSelectNone');
  assert.deepEqual(checked(), [false, false, false, false]);
  d.element('assessmentProfile').value = 'Imported test profile';
  d.element('assessmentProfile').handlers.change();
  assert.deepEqual(rowsHidden(), [true, true, true, false]);
  click(d, 'btnAssessmentSelectAll');
  assert.deepEqual(checked(), [false, false, false, true]);
  platforms[3].checked = false;
  platforms[3].handlers.change();
  assert.deepEqual(rowsHidden(), [true, true, true, true]);
  assert.deepEqual(checked(), [false, false, false, false]);
  assert.equal(d.element('assessmentPacksEmpty').textContent, empty);
  assert.equal(isHidden(d, 'assessmentPacksEmpty'), false);
  const html = fs.readFileSync(path.join(__dirname, '..', 'web', 'index.html'), 'utf8');
  assert.match(html, /<div id="assessmentPacks" class="assessment-packs"><\/div>\s*<p id="assessmentPacksEmpty"/);
});

test('context shows only the selected platforms\' fields and warns while the Windows 11 build is blank', () => {
  const d = assessmentDashboard();
  renderCatalog(d);
  const fields = {
    windows11: ['assessmentContextWindows11'],
    macos: ['assessmentContextMacos'],
    iosIpados: ['assessmentContextIosIpados', 'assessmentContextIosOwnership'],
    androidEnterprise: ['assessmentContextAndroidEnterprise', 'assessmentContextEnrollment']
  };
  const platforms = boxes(d, 'assessmentPlatforms');
  Object.keys(fields).forEach((key, i) => {
    platforms.forEach((box, j) => { box.checked = j === i; });
    platforms[0].handlers.change();
    click(d, 'btnAssessPlatformsNext');
    boxes(d, 'assessmentPacks')[i].checked = true;
    click(d, 'btnAssessBaselinesNext');
    expectStep(d, 3, 'contextTitle');
    for (const [platform, ids] of Object.entries(fields)) {
      for (const id of ids) assert.equal(isHidden(d, id), platform !== key, `${key}: ${id}`);
    }
    assert.equal(isHidden(d, 'assessmentContextWarning'), key !== 'windows11', key);
    click(d, 'btnAssessContextBack');
    click(d, 'btnAssessBaselinesBack');
  });
  platforms.forEach((box) => { box.checked = true; });
  platforms[0].handlers.change();
  click(d, 'btnAssessPlatformsNext');
  click(d, 'btnAssessmentSelectAll');
  click(d, 'btnAssessBaselinesNext');
  expectStep(d, 3, 'contextTitle');
  for (const id of Object.values(fields).flat()) assert.equal(isHidden(d, id), false, id);
  assert.equal(d.element('assessmentContextWarning').textContent, windowsWarning);
  d.element('assessmentOsWindows11').value = '10.0.26100';
  d.element('assessmentOsWindows11').handlers.input();
  assert.equal(isHidden(d, 'assessmentContextWarning'), true);
  assert.equal(d.element('assessmentContextWarning').textContent, '');
  d.element('assessmentOsWindows11').value = '   ';
  d.element('assessmentOsWindows11').handlers.input();
  assert.equal(isHidden(d, 'assessmentContextWarning'), false);
  click(d, 'btnAssessContextNext');
  expectStep(d, 4, 'runAssessmentTitle');
});

test('the review lists platforms, packs and every context value as plain text', async () => {
  const d = assessmentDashboard((url) => (url === '/api/state' ? connectedState() : {}));
  await selectAll(d);
  d.element('assessmentOsMacos').value = ' 14.0 ';
  d.element('assessmentEnrollment').value = 'corporateOwnedWorkProfile';
  click(d, 'btnAssessPlatformsNext');
  click(d, 'btnAssessBaselinesNext');
  click(d, 'btnAssessContextNext');
  expectStep(d, 4, 'runAssessmentTitle');
  assert.equal(d.element('assessmentReview').textContent, [
    'Platforms: Windows 11, macOS, iOS/iPadOS, Android Enterprise',
    '',
    'Rule packs:',
    'synthetic-windows11 @ 1.0.0 — Windows 11 · Test profile',
    'synthetic-macos @ 1.0.0 — macOS · Test profile',
    'synthetic-iosipados @ 1.0.0 — iOS/iPadOS · Test profile',
    'synthetic-androidenterprise @ 1.0.0 — Android Enterprise · Imported test profile',
    '',
    'Context (user-selected, not discovered device inventory):',
    'Windows 11 — OS version: Unknown',
    'macOS — OS version: 14.0',
    'iOS/iPadOS — OS version: Unknown; ownership scope: Unknown',
    'Android Enterprise — OS version: Unknown; enrollment mode: Corporate-owned work profile',
    '',
    windowsWarning
  ].join('\n'));
  assert.equal(d.element('assessmentReview').innerHTML, '');
  d.element('assessmentOsWindows11').value = '10.0.22631';
  click(d, 'btnAssessReviewBack');
  click(d, 'btnAssessContextNext');
  assert.match(d.element('assessmentReview').textContent, /Windows 11 — OS version: 10\.0\.22631/);
  assert.equal(d.element('assessmentReview').textContent.includes('Windows policies targeting'), false);
  const html = fs.readFileSync(path.join(__dirname, '..', 'web', 'index.html'), 'utf8');
  for (const select of ['assessmentEnrollment', 'assessmentIosOwnership']) {
    const options = html.match(new RegExp(`id="${select}">([\\s\\S]*?)</select>`))[1];
    const labelled = [...options.matchAll(/<option value="(\w+)">([^<]+)<\/option>/g)];
    assert.ok(labelled.length >= 2, select);
    for (const [, value, label] of labelled) {
      d.element(select).value = value;
      d.run('renderAssessmentReview()');
      assert.ok(d.element('assessmentReview').textContent.includes(label), `${select}: ${value}`);
    }
  }
});

// --- ZIP rule-pack import ----------------------------------------------------

const importTypeMessage = 'Choose a JSON rule pack (at most 10 MiB) or a ZIP archive (at most 32 MiB).';
const importedNotice = 'Select the platforms and packs to assess; imports are never selected automatically.';

test('the import card accepts JSON and ZIP files and the catalog note names the supported formats', () => {
  const html = fs.readFileSync(path.join(__dirname, '..', 'web', 'index.html'), 'utf8');
  assert.match(html,
    /id="assessmentImportFile" accept="\.json,\.zip,application\/json,application\/zip,application\/x-zip-compressed"/);
  const d = assessmentDashboard();
  renderCatalog(d);
  const note = d.element('assessmentCatalogNote').textContent;
  for (const phrase of ['never bundled', 'licensed CIS Intune build-kit ZIP', 'schema-1 JSON rule pack',
    'PDF and Excel benchmarks are not supported']) {
    assert.ok(note.includes(phrase), phrase);
  }
});

test('ZIP import posts base64, lists the result and merges packs without selecting them or dropping catalog errors', async () => {
  const bytes = Array.from({ length: 0x8000 * 2 + 5 }, (_, i) => (i * 7) & 0xff);
  const present = { ...syntheticPacks()[0], origin: 'imported', controlCount: 2, added: false };
  const created = { ...syntheticPacks()[0], id: 'synthetic-kit-level-1', version: '1.0.0+abc123',
    sha256: 'c'.repeat(64), origin: 'imported', framework: 'CIS', profile: 'Level 1', controlCount: 1, added: true };
  const skipped = Array.from({ length: 12 }, (_, i) => ({
    entry: `kit/<extra-${i}>.json`, reason: 'Not a Settings Catalog policy or rule pack.' }));
  const d = assessmentDashboard((url, r) => (url === '/api/assessment/packs' && r.method === 'POST'
    ? { httpStatus: 201, body: { packs: [present, created], added: 1, skipped, skippedCount: 14, ignored: 3,
      archive: { sha256: 'd'.repeat(64) } } }
    : {}));
  d.run(`renderAssessmentPacks(${JSON.stringify({ packs: syntheticPacks(),
    errors: [{ origin: 'imported', reason: 'Synthetic invalid pack.' }] })})`);
  boxes(d, 'assessmentPlatforms')[0].checked = true;
  boxes(d, 'assessmentPlatforms')[0].handlers.change();
  boxes(d, 'assessmentPacks')[0].checked = true;
  let reads = 0;
  d.element('assessmentImportFile').files = [{ name: 'Synthetic-Kit.ZIP', size: bytes.length,
    arrayBuffer: async () => { reads++; return Uint8Array.from(bytes).buffer; },
    text: async () => { throw new Error('A ZIP archive must not be read as text.'); } }];
  await click(d, 'btnAssessmentImport');
  assert.equal(d.element('assessmentError').textContent, '');
  assert.equal(reads, 1);
  assert.deepEqual(d.requests.find((r) => r.method === 'POST').payload,
    { archive: Buffer.from(bytes).toString('base64') });
  assert.equal(d.element('assessmentImportSummary').textContent, [
    `Imported 2 rule packs locally. ${importedNotice}`,
    '1 new, 1 already present.',
    'synthetic-windows11 @ 1.0.0 — Windows 11 · Test profile · 2 controls · already present',
    'synthetic-kit-level-1 @ 1.0.0+abc123 — Windows 11 · Level 1 · 1 control · new',
    'Skipped 14 archive entries:',
    ...skipped.slice(0, 10).map((s) => `${s.entry}: ${s.reason}`),
    '…and 4 more.',
    '3 other files were ignored (not JSON).'
  ].join('\n'));
  assert.equal(d.element('assessmentImportSummary').innerHTML, '');
  assert.equal(d.element('assessmentProgress').textContent, '');
  const rows = Object.fromEntries(boxes(d, 'assessmentPacks').map((b) => [b.value, b]));
  assert.equal(Object.keys(rows).length, 5);
  assert.equal(rows[`synthetic-windows11@1.0.0#${'0'.repeat(64)}`].checked, true);
  const added = rows[`synthetic-kit-level-1@1.0.0+abc123#${'c'.repeat(64)}`];
  assert.equal(added.disabled, false);
  assert.equal(added.checked, false);
  assert.equal(d.element('assessmentCatalogErrors').textContent, 'imported: Synthetic invalid pack.');
});

test('import checks the file type and size before reading, and a reset during a ZIP read sends nothing', async () => {
  const d = assessmentDashboard();
  let reads = 0;
  const read = async () => { reads++; return new ArrayBuffer(1); };
  const zipMessage = 'Choose a nonempty ZIP archive, at most 32 MiB.';
  for (const [file, message] of [
    [undefined, importTypeMessage],
    [{ name: 'benchmark.pdf', size: 2 }, importTypeMessage],
    [{ name: 'benchmark.xlsx', size: 2 }, importTypeMessage],
    [{ name: 'kit.zip.txt', size: 2 }, importTypeMessage],
    [{ name: 'kit.zip', size: 0 }, zipMessage],
    [{ name: 'kit.ZIP', size: 32 * 1024 * 1024 + 1 }, zipMessage],
    [{ name: 'pack.JSON', size: 10 * 1024 * 1024 + 1 }, 'Choose a nonempty JSON rule pack, at most 10 MiB.']
  ]) {
    d.element('assessmentImportFile').files = file ? [{ ...file, arrayBuffer: read, text: read }] : [];
    await click(d, 'btnAssessmentImport');
    assert.equal(d.element('assessmentError').textContent, message, file?.name || 'no file');
  }
  assert.equal(reads, 0);
  assert.equal(d.requests.filter((r) => r.method === 'POST').length, 0);
  d.element('assessmentImportFile').files = [{ name: 'kit.Zip', size: 32 * 1024 * 1024,
    arrayBuffer: async () => Uint8Array.from([0, 127, 128, 255]).buffer }];
  await click(d, 'btnAssessmentImport');
  assert.deepEqual(d.requests.find((r) => r.method === 'POST').payload,
    { archive: Buffer.from([0, 127, 128, 255]).toString('base64') });
  let release;
  d.element('assessmentImportFile').files = [{ name: 'kit.zip', size: 1,
    arrayBuffer: () => new Promise((resolve) => { release = resolve; }) }];
  const pending = click(d, 'btnAssessmentImport');
  d.run('clearAssessment()');
  release(Uint8Array.from([1]).buffer);
  await pending;
  assert.equal(d.requests.filter((r) => r.method === 'POST').length, 1);
  assert.equal(d.element('btnAssessmentImport').disabled, false);
});

test('an archive with nothing importable shows the error and the skipped and ignored files, and imports nothing', async () => {
  let response;
  const d = assessmentDashboard((url, r) => (url === '/api/assessment/packs' && r.method === 'POST' ? response : {}));
  renderCatalog(d);
  response = { httpStatus: 400, body: {
    error: 'The archive contains no importable rule packs or Settings Catalog policies. ' +
      'PDF, Excel, XCCDF/OVAL, Group Policy and OMA-URI content is not supported.',
    skipped: [{ entry: 'kit/<notes>.json', reason: 'Not a Settings Catalog policy or rule pack.' }],
    skippedCount: 1, ignored: 1 } };
  d.element('assessmentImportFile').files = [{ name: 'kit.zip', size: 3,
    arrayBuffer: async () => Uint8Array.from([1, 2, 3]).buffer }];
  await click(d, 'btnAssessmentImport');
  assert.match(d.element('assessmentError').textContent, /^400: The archive contains no importable rule packs/);
  assert.equal(d.element('assessmentImportSummary').textContent, [
    'Nothing was imported.',
    'Skipped 1 archive entry:',
    'kit/<notes>.json: Not a Settings Catalog policy or rule pack.',
    '1 other file was ignored (not JSON).'
  ].join('\n'));
  assert.equal(boxes(d, 'assessmentPacks').length, 4);
  response = { httpStatus: 413, body: { error: 'Synthetic archive limit exceeded.' } };
  await click(d, 'btnAssessmentImport');
  assert.equal(d.element('assessmentError').textContent, '413: Synthetic archive limit exceeded.');
  assert.equal(d.element('assessmentImportSummary').textContent, '');
  response = { httpStatus: 201, body: { pack: { ...syntheticPacks()[1], id: 'synthetic-json',
    sha256: 'e'.repeat(64), origin: 'imported' } } };
  d.element('assessmentImportFile').files = [{ name: 'pack.json', size: 2, text: async () => '{}' }];
  await click(d, 'btnAssessmentImport');
  assert.deepEqual(d.requests.filter((r) => r.method === 'POST').at(-1).payload, { content: '{}' });
  assert.equal(d.element('assessmentError').textContent, '');
  assert.equal(d.element('assessmentImportSummary').textContent,
    `Imported 1 rule pack locally. ${importedNotice}\nsynthetic-json @ 1.0.0 — macOS · Test profile`);
  assert.equal(boxes(d, 'assessmentPacks').length, 5);
});
