'use strict';

const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');

const root = path.join(__dirname, '..');
const i18nSource = fs.readFileSync(path.join(root, 'web', 'i18n.js'), 'utf8');

function installI18n(context, {
  saved, languages = ['en-GB'], catalogs = {}, warnings = [], staticElements = {}, beforeCatalog
} = {}) {
  const storage = new Map(saved == null ? [] : [['ids.locale', saved]]);
  const attributes = new Map();
  const dynamicIds = new Map();
  const getElement = context.document.getElementById.bind(context.document);
  context.document.getElementById = id => dynamicIds.get(id) || (id.startsWith('localeOption-') ? null : getElement(id));
  const createElement = context.document.createElement.bind(context.document);
  context.document.createElement = tag => {
    const element = createElement(tag);
    let id = element.id;
    Object.defineProperty(element, 'id', {
      configurable: true, get: () => id,
      set(value) { id = value; dynamicIds.set(value, element); }
    });
    element.tagName = tag.toUpperCase();
    return element;
  };
  context.window.navigator = { languages };
  context.window.localStorage = {
    getItem: key => storage.get(key) ?? null,
    setItem: (key, value) => storage.set(key, value)
  };
  context.document.documentElement = {
    setAttribute: (key, value) => attributes.set(key, value),
    getAttribute: key => attributes.get(key)
  };
  const selectAll = context.document.querySelectorAll.bind(context.document);
  context.document.querySelectorAll = selector => selector.startsWith('[data-i18n') ? staticElements[selector] || [] : selectAll(selector);
  const fetch = context.fetch;
  context.fetch = async (url, options) => {
    const locale = /^\/locales\/([a-z]{2}-[A-Z]{2})\.json$/.exec(url)?.[1];
    if (!locale) return fetch(url, options);
    if (beforeCatalog) await beforeCatalog(locale);
    // Synthetic UI fixtures use the checked-in catalogs, never tenant or session data.
    const body = catalogs[locale] || JSON.parse(fs.readFileSync(path.join(root, 'locales', `${locale}.json`), 'utf8'));
    return { ok: true, status: 200, json: async () => ({ ui: body.ui }) };
  };
  context.console = { warn: message => warnings.push(message) };
  vm.runInContext(i18nSource, context);
  return { ready: context.window.IdsI18n.ready, storage, attributes, warnings };
}

function withoutTranslationSpans(html) {
  return html.replace(/<span data-i18n="[^"]+">([\s\S]*?)<\/span>/g, '$1')
    .replace(/ data-i18n(?:-(?:title|placeholder|aria-label))?="[^"]+"/g, '');
}

module.exports = { installI18n, withoutTranslationSpans };
