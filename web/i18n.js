'use strict';

(() => {
  const locales = Object.freeze([
    ['en-GB', 'United Kingdom', 'English'],
    ['nl-NL', 'Nederland', 'Nederlands'],
    ['fr-FR', 'France', 'Français'],
    ['de-DE', 'Deutschland', 'Deutsch'],
    ['sv-SE', 'Sverige', 'Svenska'],
    ['es-ES', 'España', 'Español'],
    ['nb-NO', 'Norge', 'Norsk bokmål'],
    ['pt-PT', 'Portugal', 'Português'],
    ['it-IT', 'Italia', 'Italiano'],
    ['da-DK', 'Danmark', 'Dansk']
  ].map(([id, country, language]) => Object.freeze({ id, country, language })));
  const storageKey = 'ids.locale';
  const catalogs = new Map();
  const subscribers = new Set();
  let locale = 'en-GB';
  let revision = 0;
  let diagnostic = false;
  let pickerOpen = false;
  let activeOption = 0;
  let typeAhead = '';
  let typedAt = 0;
  const supported = (value) => locales.some(item => item.id === value);
  const matchBrowser = (values) => {
    for (const value of values || []) {
      const prefix = String(value).toLowerCase().split('-')[0];
      const found = locales.find(item => item.id.toLowerCase().split('-')[0] === (prefix === 'no' ? 'nb' : prefix));
      if (found) return found.id;
    }
    return 'en-GB';
  };
  function initialLocale() {
    try {
      const saved = window.localStorage.getItem(storageKey);
      if (supported(saved)) return saved;
      if (saved) report(`Unsupported persisted locale: ${saved}`);
    } catch (error) { /* Private browsing can disable storage; the in-memory choice still works. */ }
    return matchBrowser(window.navigator?.languages || [window.navigator?.language || 'en-GB']);
  }
  const formatNumber = (value, options) => new Intl.NumberFormat(locale, options).format(value);
  const formatDate = (value, options = { dateStyle: 'medium', timeStyle: 'short' }) => {
    if (!value) return t('text.unknown');
    const date = new Date(value);
    return Number.isNaN(date.getTime()) ? String(value) : new Intl.DateTimeFormat(locale, options).format(date);
  };
  function report(message) {
    diagnostic = true;
    console.warn(`[IdsI18n] ${message}`);
    renderWarning();
  }
  function renderWarning() {
    const warning = document.getElementById('localeWarning');
    if (warning) {
      warning.hidden = false;
      warning.textContent = catalogs.get(locale)?.['locale.warning'] ||
        catalogs.get('en-GB')?.['locale.warning'] || 'Translation unavailable. English is used where necessary.';
    }
  }
  function t(key, args = {}) {
    let message = catalogs.get(locale)?.[key];
    if (typeof message !== 'string') {
      report(`Missing UI key ${key} for ${locale}`);
      message = catalogs.get('en-GB')?.[key];
    }
    if (typeof message !== 'string') return `[${key}]`;
    // Interpolate once, as literal data. Braces and "$&" supplied by callers are never reinterpreted.
    return message.replace(/\{([A-Za-z]\w*)\}/g, (placeholder, name) => {
      if (!Object.hasOwn(args, name)) { report(`Missing argument ${name} for ${key}`); return placeholder; }
      const value = args[name];
      return typeof value === 'number' ? formatNumber(value) : String(value ?? '');
    });
  }
  async function load(id) {
    if (catalogs.has(id)) return;
    const response = await fetch(`/locales/${id}.json`);
    if (!response.ok) throw new Error(`Catalog HTTP ${response.status}: ${id}`);
    const data = (await response.json()).ui;
    if (!data || typeof data !== 'object' || Object.values(data).some(value => typeof value !== 'string')) {
      throw new Error(`Invalid UI catalog: ${id}`);
    }
    catalogs.set(id, Object.freeze(data));
  }
  function applyStatic(root = document) {
    for (const element of root.querySelectorAll('[data-i18n]')) {
      element.textContent = t(element.getAttribute('data-i18n'));
    }
    for (const attribute of ['title', 'placeholder', 'aria-label']) {
      for (const element of root.querySelectorAll(`[data-i18n-${attribute}]`)) {
        element.setAttribute(attribute, t(element.getAttribute(`data-i18n-${attribute}`)));
      }
    }
  }
  function renderPicker() {
    const select = document.getElementById('localeSelect');
    if (!select) return;
    select.value = locale;
    const current = document.getElementById('localeCurrent');
    const selected = locales.find(item => item.id === locale);
    current.textContent = `${selected.country} / ${selected.language}`;
    current.setAttribute('lang', locale);
    const flag = document.getElementById('localeFlag');
    flag.src = `/flags/${locale}.svg`;
    flag.alt = ''; // The adjacent native label already names the country and language.
    for (const [index, item] of locales.entries()) {
      const option = document.getElementById(`localeOption-${item.id}`);
      if (option) {
        option.setAttribute('aria-selected', String(item.id === locale));
        option.setAttribute('data-active', String(index === activeOption));
      }
    }
    if (diagnostic) renderWarning();
  }
  async function setLocale(id, persist = true) {
    const request = ++revision;
    let loaded = true;
    if (!supported(id)) { report(`Unsupported locale: ${id}`); renderPicker(); return false; }
    try {
      await load('en-GB');
      await load(id);
    } catch (error) {
      loaded = false;
      report(error.message);
      if (!catalogs.has('en-GB')) return false;
      id = 'en-GB';
    }
    if (request !== revision) return false;
    locale = id;
    document.documentElement.setAttribute('lang', id);
    if (persist && loaded) {
      try { window.localStorage.setItem(storageKey, id); } catch (error) { /* Storage is optional. */ }
    }
    applyStatic();
    renderPicker();
    for (const subscriber of subscribers) subscriber();
    return loaded;
  }
  function mountPicker() {
    const select = document.getElementById('localeSelect');
    if (!select) return;
    const list = document.getElementById('localeOptions');
    for (const { id, country, language } of locales) {
      const option = document.createElement('li');
      option.id = `localeOption-${id}`;
      option.setAttribute('role', 'option');
      option.value = id;
      const flag = document.createElement('img');
      flag.src = `/flags/${id}.svg`;
      flag.alt = '';
      flag.width = 24;
      flag.height = 16;
      const label = document.createElement('span');
      label.textContent = `${country} / ${language}`;
      label.setAttribute('lang', id);
      option.appendChild(flag);
      option.appendChild(label);
      option.addEventListener('click', () => { closePicker(); void setLocale(id); });
      list.appendChild(option);
    }
    const activate = (index) => {
      activeOption = (index + locales.length) % locales.length;
      select.setAttribute('aria-activedescendant', `localeOption-${locales[activeOption].id}`);
      renderPicker();
      document.getElementById(`localeOption-${locales[activeOption].id}`)?.scrollIntoView({ block: 'nearest' });
    };
    const open = () => {
      pickerOpen = true;
      list.hidden = false;
      select.setAttribute('aria-expanded', 'true');
      activate(locales.findIndex(item => item.id === locale));
    };
    select.addEventListener('click', () => { if (pickerOpen) closePicker(); else open(); });
    select.addEventListener('keydown', (event) => {
      const wasOpen = pickerOpen;
      if (event.key === 'Tab') { closePicker(); return; }
      if (event.key === 'Escape') { closePicker(); event.preventDefault(); return; }
      if (['ArrowDown', 'ArrowUp', 'Home', 'End', 'Enter', ' '].includes(event.key)) {
        event.preventDefault();
        if (!wasOpen) open();
        if (event.key === 'Home') activate(0);
        else if (event.key === 'End') activate(locales.length - 1);
        else if (wasOpen && event.key === 'ArrowDown') activate(activeOption + 1);
        else if (wasOpen && event.key === 'ArrowUp') activate(activeOption - 1);
        else if (wasOpen && ['Enter', ' '].includes(event.key)) {
          const id = locales[activeOption].id;
          closePicker();
          void setLocale(id);
        }
      } else if (event.key.length === 1 && !event.ctrlKey && !event.altKey && !event.metaKey) {
        event.preventDefault();
        if (!wasOpen) open();
        typeAhead = Date.now() - typedAt > 700 ? event.key : typeAhead + event.key;
        typedAt = Date.now();
        const index = locales.findIndex(item => [item.country, item.language].some(name =>
          name.toLocaleLowerCase(locale).startsWith(typeAhead.toLocaleLowerCase(locale))));
        if (index >= 0) activate(index);
      }
    });
    select.addEventListener('blur', () => { closePicker(); });
    // Pointer selection is handled before blur can close the list.
    list.addEventListener('mousedown', event => event.preventDefault());
    activeOption = locales.findIndex(item => item.id === locale);
    renderPicker();
  }
  function closePicker() {
    pickerOpen = false;
    document.getElementById('localeOptions').hidden = true;
    const control = document.getElementById('localeSelect');
    control.setAttribute('aria-expanded', 'false');
    control.removeAttribute('aria-activedescendant');
  }
  // App boot awaits ready. No state request is sent before language selection and static translation.
  const desired = initialLocale();
  const ready = setLocale(desired, false).then(() => { mountPicker(); });
  window.IdsI18n = Object.freeze({
    get locale() { return locale; }, locales, t, setLocale, ready, applyStatic,
    formatNumber, formatDate, matchBrowser,
    plural: (count) => new Intl.PluralRules(locale).select(count),
    subscribe(callback) { subscribers.add(callback); return () => subscribers.delete(callback); }
  });
})();
