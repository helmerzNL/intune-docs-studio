'use strict';

// Required by app-shell-ui.test.js so the repository's explicit CI command runs these guards.
const { test } = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');
const { installI18n } = require('./i18n-test-helpers');
const root = path.join(__dirname, '..');
const ids = ['da-DK', 'de-DE', 'en-GB', 'es-ES', 'fr-FR', 'it-IT', 'nl-NL', 'nb-NO', 'pt-PT', 'sv-SE'];
const catalog = id => JSON.parse(fs.readFileSync(path.join(root, 'locales', `${id}.json`), 'utf8')).ui;
const english = catalog('en-GB');
const app = fs.readFileSync(path.join(root, 'web', 'app.js'), 'utf8');
const html = fs.readFileSync(path.join(root, 'web', 'index.html'), 'utf8');

// Exact exceptions only: shared technical terminology and a product name, not untranslated prose.
const sameAsEnglish = {
  'nl-NL': { 'text.tenant': 'Tenant is the established Dutch Microsoft technical term.' },
  'fr-FR': { 'section.apps': 'Applications is the French and English technical noun.',
    'section.scripts': 'Scripts is the shared programming term.' },
  'pt-PT': { 'section.scripts': 'Scripts is the shared programming term.' },
  'it-IT': { 'text.file': 'File is the standard Italian computing term.' },
  'nb-NO': { 'count.policy_one': 'Policy is the established Norwegian Microsoft technical noun.' },
  'da-DK': { 'text.output': 'Output is the standard Danish computing term.',
    'section.scripts': 'Scripts is the shared programming term.' }
};
for (const id of ids.filter(id => id !== 'en-GB')) {
  sameAsEnglish[id] = { 'text.azure_devops': 'Azure DevOps is a product name.', ...sameAsEnglish[id] };
}
const placeholders = value => [...value.matchAll(/\{([A-Za-z]\w*)\}/g)].map(match => match[1]).sort();

test('all ten UI catalogs have exact nonempty key and placeholder parity with no untranslated prose', () => {
  assert.ok(Object.keys(english).length >= 440, 'full app catalog, not a small label-only subset');
  for (const id of ids) {
    const translated = catalog(id);
    assert.deepEqual(Object.keys(translated).sort(), Object.keys(english).sort(), id);
    for (const [key, value] of Object.entries(translated)) {
      assert.equal(typeof value, 'string', `${id}:${key}`);
      assert.ok(value.trim(), `${id}:${key} is empty`);
      assert.deepEqual(placeholders(value), placeholders(english[key]), `${id}:${key} placeholders`);
      if (id !== 'en-GB' && value === english[key]) assert.ok(sameAsEnglish[id][key], `${id}:${key} untranslated`);
      assert.doesNotMatch(value, /&(?:mdash|hellip|amp);/, `${id}:${key} is plain text, not HTML`);
    }
    if (id !== 'en-GB') {
      for (const key of Object.keys(sameAsEnglish[id])) assert.equal(translated[key], english[key], `${id}:${key} stale exception`);
    }
  }
});

test('flags are exactly the ten packaged, local SVG files and both scripts load in the correct order', () => {
  assert.deepEqual(fs.readdirSync(path.join(root, 'web', 'flags')).sort(), ids.map(id => `${id}.svg`).sort());
  for (const id of ids) {
    const svg = fs.readFileSync(path.join(root, 'web', 'flags', `${id}.svg`), 'utf8');
    assert.match(svg, /<svg[^>]+viewBox=/);
    assert.doesNotMatch(svg, /<script|(?:href|src)="https?:/i);
  }
  assert.ok(html.indexOf('src="/i18n.js"') < html.indexOf('src="/app.js"'));
  assert.match(html, /id="localeSelect"[\s\S]*?role="combobox"/);
  assert.match(html, /aria-labelledby="localeLabel localeCurrent"/);
  assert.match(html, /id="localeLabel" class="sr-only"/);
  assert.match(html, /id="localeOptions"[^>]+role="listbox"/);
  assert.ok(html.indexOf('id="localePicker"') < html.indexOf('<main'));
  assert.doesNotMatch(app, /MutationObserver|location\.reload/);
});

test('every static app-owned text node, placeholder, title and accessible label is explicitly tagged', () => {
  const stack = [];
  const voidTags = new Set(['meta', 'link', 'input', 'img', 'br', 'hr', 'path', 'rect']);
  const technicalText = new Set(['Intune Docs Studio', 'English', 'Microsoft Edge', 'Google Chrome']);
  const codeText = new Set(['_raw', 'organizations', '.order']);
  for (const token of html.split(/(<!--[\s\S]*?-->|<[^>]*>)/g)) {
    if (token.startsWith('<!--') || token.startsWith('<!')) continue;
    if (token.startsWith('</')) { stack.pop(); continue; }
    if (token.startsWith('<')) {
      const tag = token.match(/^<([\w-]+)/)?.[1];
      if (!tag) continue;
      const attributes = Object.fromEntries([...token.matchAll(/([\w-]+)="([^"]*)"/g)].map(m => [m[1], m[2]]));
      for (const attribute of ['aria-label', 'title', 'placeholder']) {
        if (attributes[attribute] && !/^https:/.test(attributes[attribute])) {
          assert.ok(attributes[`data-i18n-${attribute}`], token);
        }
      }
      for (const [attribute, key] of Object.entries(attributes)) {
        if (attribute === 'data-i18n' || /^data-i18n-(?:aria-label|title|placeholder)$/.test(attribute)) {
          assert.ok(Object.hasOwn(english, key), `${token}: missing catalog key`);
        }
      }
      if (!voidTags.has(tag) && !token.endsWith('/>')) stack.push({ tag, attributes });
      continue;
    }
    const text = token.trim();
    if (!/[A-Za-z]/.test(text.replace(/&(?:mdash|middot|hellip|larr|nbsp|amp|lt|gt|quot);/g, ''))) continue;
    if (stack.some(item => ['script', 'svg'].includes(item.tag) || item.attributes['data-i18n'])) continue;
    if (stack.some(item => item.tag === 'code')) { assert.ok(codeText.has(text), `Unreviewed technical text: ${text}`); continue; }
    assert.ok(technicalText.has(text), `Untagged app text: ${text}`);
  }
});

// Small lexical source scanner: comments/regexes are skipped, quoted strings and full template
// skeletons are examined, and expressions inside templates are recursively scanned. No dependency.
function sourceStrings(source) {
  let index = 0;
  const strings = [];
  function code(untilBrace = false) {
    let braces = 0;
    while (index < source.length) {
      const char = source[index];
      if (char === '/' && source[index + 1] === '/') { index = source.indexOf('\n', index); if (index < 0) index = source.length; continue; }
      if (char === '/' && source[index + 1] === '*') { index = source.indexOf('*/', index + 2) + 2; continue; }
      if (char === '"' || char === "'") {
        const quote = char;
        let value = '';
        index++;
        while (index < source.length && source[index] !== quote) {
          if (source[index] === '\\') { value += source.slice(index, index + 2); index += 2; }
          else value += source[index++];
        }
        index++;
        strings.push({ value, template: false });
        continue;
      }
      if (char === '`') {
        let value = '';
        index++;
        while (index < source.length && source[index] !== '`') {
          if (source[index] === '\\') { value += source.slice(index, index + 2); index += 2; }
          else if (source[index] === '$' && source[index + 1] === '{') {
            index += 2; code(true); value += '§';
          } else value += source[index++];
        }
        index++;
        strings.push({ value, template: true });
        continue;
      }
      // Regex literals occur after operators/delimiters in this application.
      if (char === '/' && /[=(,:!&|?;{[]\s*$/.test(source.slice(0, index))) {
        index++;
        let bracket = false;
        while (index < source.length) {
          if (source[index] === '\\') { index += 2; continue; }
          if (source[index] === '[') bracket = true;
          if (source[index] === ']') bracket = false;
          if (source[index++] === '/' && !bracket) break;
        }
        while (/[a-z]/i.test(source[index] || '') && index < source.length) index++;
        continue;
      }
      index++;
      if (char === '{') braces++;
      if (char === '}') {
        if (untilBrace && braces === 0) return;
        braces--;
      }
    }
  }
  code();
  return strings;
}

test('dynamic UI source contains no unlocalized prose or unreviewed technical literals', () => {
  assert.doesNotThrow(() => new vm.Script(app));
  const technical = new Set([
    'use strict', 'Intune Docs Studio', 'Windows 11', 'Android Enterprise', 'Microsoft',
    'badge badge-on', 'badge badge-off', 'check assessment-pack', 'btn ghost small pack-remove', 'btn ghost small',
    '#sections input', '#assessmentPacks input', '#assessmentPlatforms input', '#assessmentPacks details',
    'SHA-256: §', 'Start-IntuneDocs.cmd'
  ]);
  const unlocalized = [];
  for (const { value, template } of sourceStrings(app)) {
    const text = value.replace(/<[^>]*>/g, '').replace(/\\[nrt]/g, ' ').trim();
    if (technical.has(text) || !/[A-Za-z]/.test(text)) continue;
    if (/[A-Za-z][A-Za-z-]*\s+[A-Za-z]/.test(text) || /^[A-Z][a-z]+$/.test(text) ||
      ((template || /<[a-z]/i.test(value)) && /^[a-z]+$/i.test(text))) unlocalized.push(text);
  }
  assert.deepEqual(unlocalized, []);
  for (const match of app.matchAll(/\b(?:t|h)\(["']([^"']+)["']/g)) {
    assert.ok(Object.hasOwn(english, match[1]), `Unknown explicit key ${match[1]}`);
  }
});

test('the dynamic source guard sees nested template text and literals while ignoring comments and regex syntax', () => {
  const found = sourceStrings("// 'not a literal'\nconst label = 'Untranslated prose';\n" +
    'const html = `<p>created ${"Nested prose"}</p>`;\nconst pattern = /["\']/g;');
  assert.ok(found.some(item => item.value === 'Untranslated prose'));
  assert.ok(found.some(item => item.value === 'Nested prose'));
  assert.ok(found.some(item => item.template && item.value === '<p>created §</p>'));
  assert.equal(found.some(item => item.value === 'not a literal'), false);
});

function languageHarness(options) {
  const elements = new Map();
  function element(id) {
    if (!elements.has(id)) {
      const attributes = new Map();
      elements.set(id, {
        id, children: [], handlers: {}, textContent: '', hidden: false,
        setAttribute: (name, value) => attributes.set(name, String(value)),
        getAttribute: name => attributes.get(name) ?? null,
        removeAttribute: name => attributes.delete(name),
        appendChild(child) { this.children.push(child); },
        addEventListener(name, callback) { this.handlers[name] = callback; },
        scrollIntoView() {}
      });
    }
    return elements.get(id);
  }
  const context = vm.createContext({
    document: { getElementById: element, createElement: () => element(Symbol()), querySelectorAll: () => [] },
    window: {}, fetch: async () => ({ ok: false, status: 500 }), console
  });
  const heading = element('syntheticHeading');
  heading.setAttribute('data-i18n', 'text.home');
  const input = element('syntheticInput');
  input.value = 'Customer-entered path {v0}';
  input.setAttribute('data-i18n-placeholder', 'text.absolute_path_on_the_application_host');
  input.setAttribute('data-i18n-title', 'text.choose_host_folder');
  input.setAttribute('data-i18n-aria-label', 'text.choose_host_folder');
  const fixture = installI18n(context, {
    ...options,
    staticElements: {
      '[data-i18n]': [heading], '[data-i18n-placeholder]': [input],
      '[data-i18n-title]': [input], '[data-i18n-aria-label]': [input]
    }
  });
  return { ...fixture, context, element, i18n: context.window.IdsI18n };
}

test('persisted valid locale wins; browser prefix matching covers every language with English fallback', async () => {
  for (const id of ids) {
    const h = languageHarness({ saved: id, languages: ['fr-CA'] });
    await h.ready;
    assert.equal(h.i18n.locale, id);
    assert.equal(h.attributes.get('lang'), id);
    assert.equal(h.storage.get('ids.locale'), id);
  }
  for (const [browser, expected] of [['nl-BE', 'nl-NL'], ['fr-CA', 'fr-FR'], ['de-AT', 'de-DE'],
    ['sv-FI', 'sv-SE'], ['es-MX', 'es-ES'], ['no-NO', 'nb-NO'], ['nb-SJ', 'nb-NO'],
    ['pt-BR', 'pt-PT'], ['it-CH', 'it-IT'], ['da-GL', 'da-DK'], ['en-US', 'en-GB'], ['ja-JP', 'en-GB']]) {
    const h = languageHarness({ languages: [browser] });
    await h.ready;
    assert.equal(h.i18n.locale, expected, browser);
    assert.equal(h.storage.has('ids.locale'), false, 'browser choice does not override an explicit later preference');
  }
});

test('keyboard dropdown shows all local flags/native names, commits language and supports cancel/typeahead', async () => {
  const h = languageHarness();
  await h.ready;
  const control = h.element('localeSelect');
  const rows = h.element('localeOptions').children;
  assert.equal(rows.length, 10);
  for (const [index, row] of rows.entries()) {
    assert.equal(row.children[0].src, `/flags/${ids[index]}.svg`);
    assert.equal(row.children[0].alt, '');
    assert.equal(row.children[1].getAttribute('lang'), ids[index]);
    assert.equal(row.getAttribute('role'), 'option');
  }
  const nativeNames = ['Dansk', 'Deutsch', 'English', 'Español', 'Français', 'Italiano',
    'Nederlands', 'Norsk bokmål', 'Português', 'Svenska'];
  assert.deepEqual(rows.map(row => row.children[1].textContent), nativeNames);
  assert.equal(h.element('localeCurrent').textContent, 'English');
  const key = value => control.handlers.keydown({ key: value, preventDefault() {} });
  key('ArrowDown');
  assert.equal(control.getAttribute('aria-expanded'), 'true');
  for (let step = 0; step < 4; step++) key('ArrowDown'); // English -> Español -> Français -> Italiano -> Nederlands
  key('Enter');
  await new Promise(setImmediate);
  assert.equal(h.i18n.locale, 'nl-NL');
  assert.equal(h.attributes.get('lang'), 'nl-NL');
  assert.equal(h.storage.get('ids.locale'), 'nl-NL');
  assert.equal(h.element('localeFlag').src, '/flags/nl-NL.svg');
  assert.equal(h.element('localeCurrent').textContent, 'Nederlands');
  assert.equal(h.element('syntheticHeading').textContent, catalog('nl-NL')['text.home']);
  assert.equal(h.element('syntheticInput').getAttribute('placeholder'), catalog('nl-NL')['text.absolute_path_on_the_application_host']);
  assert.equal(h.element('syntheticInput').getAttribute('title'), catalog('nl-NL')['text.choose_host_folder']);
  assert.equal(h.element('syntheticInput').getAttribute('aria-label'), catalog('nl-NL')['text.choose_host_folder']);
  assert.equal(h.element('syntheticInput').value, 'Customer-entered path {v0}');
  assert.equal(control.getAttribute('aria-expanded'), 'false');
  key('ArrowUp'); key('End'); key('Escape');
  assert.equal(h.i18n.locale, 'nl-NL', 'cancel does not commit highlighted option');
  key('f'); key('Enter');
  await new Promise(setImmediate);
  assert.equal(h.i18n.locale, 'fr-FR');
  key('Home'); key('Tab');
  assert.equal(control.getAttribute('aria-expanded'), 'false');
});

test('interpolation is literal, formatting uses Intl and unexpected failures are diagnosed visibly', async () => {
  const translated = { ...catalog('nl-NL') };
  delete translated['text.use'];
  const h = languageHarness({ saved: 'nl-NL', catalogs: { 'nl-NL': { ui: translated } } });
  await h.ready;
  const hostile = '<img src=x onerror=alert(1)> {v0} $& ${evil}';
  assert.equal(h.i18n.t('text.use', { v0: hostile }), `use ${hostile}`);
  assert.ok(h.warnings.some(message => message.includes('Missing UI key text.use')));
  assert.equal(h.element('localeWarning').hidden, false);
  assert.equal(h.element('localeWarning').textContent, translated['locale.warning']);
  assert.equal(h.i18n.formatNumber(1234.5), new Intl.NumberFormat('nl-NL').format(1234.5));
  assert.equal(h.i18n.formatDate('2026-10-29T12:00:00Z', { dateStyle: 'short', timeZone: 'UTC' }),
    new Intl.DateTimeFormat('nl-NL', { dateStyle: 'short', timeZone: 'UTC' }).format(new Date('2026-10-29T12:00:00Z')));
  assert.equal(await h.i18n.setLocale('unsupported'), false);
  assert.equal(h.i18n.locale, 'nl-NL');
  assert.ok(h.warnings.some(message => message.includes('Unsupported locale')));
  assert.equal(h.i18n.plural(1), 'one');
  assert.equal(h.i18n.plural(2), 'other');
});

test('invalid saved preferences and unavailable catalogs are visible errors, not silent translation coverage', async () => {
  const h = languageHarness({
    saved: 'xx-XX', languages: ['nl-BE'],
    beforeCatalog(id) { if (id === 'fr-FR') throw new Error('Synthetic catalog unavailable'); }
  });
  await h.ready;
  assert.equal(h.i18n.locale, 'nl-NL');
  assert.ok(h.warnings.some(message => message.includes('Unsupported persisted locale')));
  assert.equal(h.element('localeWarning').textContent, catalog('nl-NL')['locale.warning']);
  await h.i18n.setLocale('nl-NL');
  assert.equal(await h.i18n.setLocale('fr-FR'), false);
  assert.equal(h.i18n.locale, 'en-GB');
  assert.equal(h.storage.get('ids.locale'), 'nl-NL', 'a network fallback does not overwrite the valid user preference');
  assert.equal(h.element('localeWarning').textContent, english['locale.warning']);
  assert.ok(h.warnings.some(message => message.includes('Synthetic catalog unavailable')));
});

test('a slower catalog response cannot overwrite a more recent language choice', async () => {
  let release;
  const gate = new Promise(resolve => { release = resolve; });
  const h = languageHarness({ beforeCatalog: id => id === 'fr-FR' ? gate : undefined });
  await h.ready;
  const first = h.i18n.setLocale('fr-FR');
  const second = h.i18n.setLocale('de-DE');
  assert.equal(await second, true);
  release();
  assert.equal(await first, false);
  assert.equal(h.i18n.locale, 'de-DE');
  assert.equal(h.storage.get('ids.locale'), 'de-DE');
  assert.equal(h.attributes.get('lang'), 'de-DE');
});
