import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { test } from 'node:test';
import { runInNewContext } from 'node:vm';

const script = readFileSync(new URL('../assets/js/site.js', import.meta.url), 'utf8');

function setup({ dark = false, theme, storageFails = false, clipboard = true, copyFails = false } = {}) {
  const listeners = {};
  const toggle = { hidden: true, setAttribute(key, value) { this[key] = value; }, addEventListener(name, fn) { listeners[name] = fn; } };
  const preference = { matches: dark, addEventListener(name, fn) { listeners.media = fn; } };
  const root = { dataset: theme ? { theme } : {} };
  const writes = [];
  const copied = [];
  const buttons = [];
  const code = { textContent: 'echo "hello"\necho "world"' };
  const block = { querySelector: () => code, closest: () => null, append(button) { buttons.push(button); } };
  const context = {
    document: {
      documentElement: root,
      querySelector: () => toggle,
      querySelectorAll: () => [block],
      createElement: () => ({ dataset: {}, setAttribute(key, value) { this[key] = value; }, addEventListener(name, fn) { this[name] = fn; }, querySelector() { return this.status ??= {}; } }),
    },
    window: { matchMedia: () => preference, addEventListener(name, fn) { listeners[name] = fn; } },
    localStorage: { setItem(...args) { if (storageFails) throw new Error('Blocked'); writes.push(args); } },
    navigator: { clipboard: clipboard ? { async writeText(text) { if (copyFails) throw new Error('Denied'); copied.push(text); } } : undefined },
    setTimeout: (fn) => { listeners.resetCopy = fn; },
  };
  runInNewContext(script, context);
  return { toggle, root, listeners, preference, writes, copied, buttons, code };
}

test('follows system preference until a choice is made, then persists the override', () => {
  const app = setup({ dark: true });
  assert.equal(app.toggle.hidden, false);
  assert.equal(app.toggle['aria-label'], 'Switch to light mode');
  app.listeners.click();
  assert.equal(app.root.dataset.theme, 'light');
  assert.deepEqual(app.writes, [['claude-plugins-theme', 'light']]);
  assert.equal(app.toggle['aria-label'], 'Switch to dark mode');
  app.preference.matches = false;
  app.listeners.media();
  assert.equal(app.root.dataset.theme, 'light');
});

test('a saved theme wins over the system, and storage denial does not break toggling', () => {
  const app = setup({ dark: true, theme: 'light', storageFails: true });
  app.listeners.click();
  assert.equal(app.root.dataset.theme, 'dark');
  assert.equal(app.toggle['aria-label'], 'Switch to light mode');
});

test('reacts to system changes when no explicit theme is saved', () => {
  const app = setup();
  assert.equal(app.toggle['aria-label'], 'Switch to dark mode');
  app.preference.matches = true;
  app.listeners.media();
  assert.equal(app.toggle['aria-label'], 'Switch to light mode');
});

test('syncs changes from another tab and restores system behavior when storage is cleared', () => {
  const app = setup();
  app.listeners.storage({ key: 'another-key', newValue: 'dark' });
  assert.equal(app.root.dataset.theme, undefined);
  app.listeners.storage({ key: 'claude-plugins-theme', newValue: 'dark' });
  assert.equal(app.root.dataset.theme, 'dark');
  app.listeners.storage({ key: null, newValue: null });
  assert.equal(app.root.dataset.theme, undefined);
  assert.equal(app.toggle['aria-label'], 'Switch to dark mode');
});

test('copies code exactly and resets its accessible success feedback', async () => {
  const app = setup();
  const button = app.buttons[0];
  await button.click();
  assert.deepEqual(app.copied, [app.code.textContent]);
  assert.equal(button['aria-label'], 'Copied');
  app.listeners.resetCopy();
  assert.equal(button['aria-label'], 'Copy code');
});

test('a denied clipboard reports recovery, and unavailable clipboard adds no unusable button', async () => {
  const app = setup({ copyFails: true });
  await app.buttons[0].click();
  assert.match(app.buttons[0]['aria-label'], /Select and copy/);
  assert.equal(setup({ clipboard: false }).buttons.length, 0);
});
