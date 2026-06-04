#!/usr/bin/env node
'use strict';
/*
 * gen-diff.js — generate a rich, self-contained HTML code-diff view (2-way or
 * 3-way) and optionally screenshot it with a headless browser.
 *
 * By Justin Sternberg <me@jtsternberg.com>
 *
 * The diff itself is computed client-side by a small vanilla-JS pass embedded in
 * the output HTML (line-level LCS for 2-way, 3D LCS for 3-way, whitespace-
 * insensitive matching, word-level intra-line highlighting, light single-pass
 * syntax tokenizer). This script's job is to template that HTML: inject the
 * sources, title, column labels, and keyword set, pick the 2-way vs 3-way
 * layout, write the file, and (optionally) drive a headless browser to capture
 * a full-page PNG.
 *
 * Zero dependencies — Node built-ins only (node:fs, node:path, node:child_process).
 * Run with any modern Node; no `npm install`.
 *
 * Usage:
 *   gen-diff.js A.php B.php                         # 2-way (auto-detected)
 *   gen-diff.js A.php B.php C.php                    # 3-way
 *   gen-diff.js --git HEAD~1:path.php --git HEAD:path.php
 *   gen-diff.js A.php B.php --lang js --title "..." --label Before --label After
 *   gen-diff.js A.php B.php --screenshot             # also emit PNG next to the HTML
 *
 * Run with -h for the full option list.
 */

const fs = require('node:fs');
const path = require('node:path');
const { execFileSync, spawnSync } = require('node:child_process');

// --------------------------------------------------------------------------- //
// Keyword sets for the light syntax highlighter. The tokenizer is language-
// agnostic; only the keyword list changes what gets the keyword color.
// --------------------------------------------------------------------------- //
const KEYWORDS = {
  php: ['abstract', 'and', 'array', 'as', 'break', 'callable', 'case', 'catch',
    'class', 'clone', 'const', 'continue', 'declare', 'default', 'do', 'echo',
    'else', 'elseif', 'empty', 'enddeclare', 'endfor', 'endforeach', 'endif',
    'endswitch', 'endwhile', 'enum', 'extends', 'final', 'finally', 'fn', 'for',
    'foreach', 'function', 'global', 'goto', 'if', 'implements', 'include',
    'include_once', 'instanceof', 'insteadof', 'interface', 'isset', 'list',
    'match', 'namespace', 'new', 'or', 'print', 'private', 'protected', 'public',
    'readonly', 'require', 'require_once', 'return', 'self', 'static', 'switch',
    'throw', 'trait', 'try', 'unset', 'use', 'var', 'while', 'xor', 'yield',
    'true', 'false', 'null', 'parent', 'void', 'int', 'string', 'bool', 'float'],
  js: ['async', 'await', 'break', 'case', 'catch', 'class', 'const', 'continue',
    'debugger', 'default', 'delete', 'do', 'else', 'export', 'extends', 'finally',
    'for', 'function', 'if', 'import', 'in', 'instanceof', 'let', 'new', 'of',
    'return', 'static', 'super', 'switch', 'this', 'throw', 'try', 'typeof', 'var',
    'void', 'while', 'with', 'yield', 'true', 'false', 'null', 'undefined', 'get', 'set'],
  ts: ['abstract', 'any', 'as', 'async', 'await', 'boolean', 'break', 'case', 'catch',
    'class', 'const', 'continue', 'declare', 'default', 'delete', 'do', 'else',
    'enum', 'export', 'extends', 'finally', 'for', 'function', 'if', 'implements',
    'import', 'in', 'instanceof', 'interface', 'is', 'keyof', 'let', 'namespace',
    'never', 'new', 'number', 'of', 'private', 'protected', 'public', 'readonly',
    'return', 'static', 'string', 'super', 'switch', 'this', 'throw', 'try', 'type',
    'typeof', 'undefined', 'unknown', 'var', 'void', 'while', 'yield', 'true', 'false', 'null'],
  python: ['and', 'as', 'assert', 'async', 'await', 'break', 'class', 'continue', 'def',
    'del', 'elif', 'else', 'except', 'finally', 'for', 'from', 'global', 'if',
    'import', 'in', 'is', 'lambda', 'nonlocal', 'not', 'or', 'pass', 'raise',
    'return', 'try', 'while', 'with', 'yield', 'True', 'False', 'None', 'self', 'cls'],
  go: ['break', 'case', 'chan', 'const', 'continue', 'default', 'defer', 'else',
    'fallthrough', 'for', 'func', 'go', 'goto', 'if', 'import', 'interface', 'map',
    'package', 'range', 'return', 'select', 'struct', 'switch', 'type', 'var',
    'nil', 'true', 'false', 'string', 'int', 'error', 'bool', 'byte', 'rune'],
  ruby: ['alias', 'and', 'begin', 'break', 'case', 'class', 'def', 'defined?', 'do',
    'else', 'elsif', 'end', 'ensure', 'false', 'for', 'if', 'in', 'module', 'next',
    'nil', 'not', 'or', 'redo', 'rescue', 'retry', 'return', 'self', 'super',
    'then', 'true', 'unless', 'until', 'when', 'while', 'yield', 'require',
    'attr_accessor', 'attr_reader', 'attr_writer'],
  rust: ['as', 'async', 'await', 'break', 'const', 'continue', 'crate', 'dyn', 'else',
    'enum', 'extern', 'false', 'fn', 'for', 'if', 'impl', 'in', 'let', 'loop',
    'match', 'mod', 'move', 'mut', 'pub', 'ref', 'return', 'self', 'static',
    'struct', 'super', 'trait', 'true', 'type', 'unsafe', 'use', 'where', 'while'],
  sql: ['select', 'insert', 'update', 'delete', 'from', 'where', 'join', 'inner',
    'left', 'right', 'outer', 'cross', 'on', 'and', 'or', 'not', 'in', 'as', 'set',
    'values', 'into', 'ignore', 'union', 'all', 'order', 'by', 'group', 'having',
    'limit', 'create', 'table', 'drop', 'alter', 'distinct', 'null', 'is'],
  generic: ['if', 'else', 'for', 'while', 'return', 'function', 'class', 'const', 'let',
    'var', 'import', 'export', 'true', 'false', 'null', 'new', 'public', 'private',
    'static', 'void', 'int', 'string', 'bool'],
};

const EXT_LANG = {
  '.php': 'php', '.js': 'js', '.jsx': 'js', '.mjs': 'js', '.cjs': 'js',
  '.ts': 'ts', '.tsx': 'ts', '.py': 'python', '.go': 'go', '.rb': 'ruby',
  '.rs': 'rust', '.sql': 'sql',
};

function die(msg) { process.stderr.write('error: ' + msg + '\n'); process.exit(1); }

// --------------------------------------------------------------------------- //
// Escaping
// --------------------------------------------------------------------------- //

// Escape a string for an HTML text/attribute context (title, labels, etc.).
// & < > become entities; any non-ASCII codepoint becomes a numeric entity so the
// output file stays pure ASCII. These live in normal elements, where the parser
// decodes character references at parse time, so they render correctly.
function escText(s) {
  let out = '';
  for (const ch of s) {
    const o = ch.codePointAt(0);
    if (ch === '&') out += '&amp;';
    else if (ch === '<') out += '&lt;';
    else if (ch === '>') out += '&gt;';
    else if (o < 32 || o > 126) out += '&#x' + o.toString(16) + ';';
    else out += ch;
  }
  return out;
}

// Render source text as an ASCII-safe JS string literal.
//
// A `<script type="text/plain">` block is a *raw text* element: the HTML parser
// does NOT decode character references inside it, and the block ends at the first
// `</script`. So entity-escaping the source there does not round trip, and
// embedded `</script>` would terminate the block early. Instead we embed each
// source as a JS string literal (read directly by the engine, no DOM). We start
// from JSON.stringify (escapes quotes, backslashes, control chars), then escape
// every remaining non-ASCII codepoint to \uXXXX (keeping the file pure ASCII;
// JSON.stringify alone leaves non-ASCII raw), and finally `<` -> < so any
// literal `</script>` can't close the surrounding real <script>. JS decodes all
// of these back to the exact original characters at runtime.
function jsSourceLiteral(s) {
  return JSON.stringify(s)
    .replace(/[\u007f-\uffff]/g, (ch) => '\\u' + ch.charCodeAt(0).toString(16).padStart(4, '0'))
    .replace(/</g, '\\u003c');
}

// Render an array of strings as a JS array literal (single-quoted).
function jsStringArray(items) {
  return '[' + items.map((it) => "'" + it.replace(/\\/g, '\\\\').replace(/'/g, "\\'") + "'").join(', ') + ']';
}

// A label dropped into a single-quoted JS string inside the engine's innerHTML.
function labelJs(l) {
  return escText(l).replace(/\\/g, '\\\\').replace(/'/g, "\\'");
}

// --------------------------------------------------------------------------- //
// Inputs
// --------------------------------------------------------------------------- //
function readSource(p) {
  try {
    return fs.readFileSync(p, 'utf8');
  } catch (e) {
    die('cannot read ' + p + ': ' + e.message);
  }
}

// Resolve a 'REF:PATH' spec to file content via `git show`.
function readGit(spec) {
  if (!spec.includes(':')) {
    die('--git expects REF:PATH (e.g. HEAD~1:src/foo.php), got: ' + spec);
  }
  try {
    return execFileSync('git', ['show', spec], { encoding: 'utf8', maxBuffer: 64 * 1024 * 1024 });
  } catch (e) {
    if (e.code === 'ENOENT') die('git not found on PATH; cannot resolve --git ' + spec);
    die('`git show ' + spec + '` failed: ' + ((e.stderr || '').toString().trim() || e.message));
  }
}

function defaultLabelFor(kind, value, index) {
  if (kind === 'git') {
    const [ref, ...rest] = value.split(':');
    const p = rest.join(':');
    return (path.basename(p) || p) + ' @ ' + ref;
  }
  if (kind === 'file') return path.basename(value);
  return index < 3 ? ['A', 'B', 'C'][index] : 'col' + (index + 1);
}

function slugify(text, fallback) {
  const s = (text || '').toLowerCase().replace(/[^a-z0-9]+/g, '-').replace(/^-+|-+$/g, '');
  return s.slice(0, 48).replace(/-+$/, '') || (fallback || 'diff');
}

// --------------------------------------------------------------------------- //
// Screenshot capture
// --------------------------------------------------------------------------- //
function whichSync(name) {
  const dirs = (process.env.PATH || '').split(path.delimiter);
  for (const d of dirs) {
    if (!d) continue;
    const full = path.join(d, name);
    try {
      fs.accessSync(full, fs.constants.X_OK);
      return full;
    } catch (_) { /* keep looking */ }
  }
  return null;
}

function findChrome() {
  const candidates = [
    '/Applications/Google Chrome.app/Contents/MacOS/Google Chrome',
    '/Applications/Chromium.app/Contents/MacOS/Chromium',
    '/Applications/Microsoft Edge.app/Contents/MacOS/Microsoft Edge',
    '/Applications/Brave Browser.app/Contents/MacOS/Brave Browser',
  ];
  for (const c of candidates) {
    try { fs.accessSync(c, fs.constants.X_OK); return c; } catch (_) { /* next */ }
  }
  for (const name of ['google-chrome-stable', 'google-chrome', 'chromium', 'chromium-browser', 'chrome']) {
    const p = whichSync(name);
    if (p) return p;
  }
  return null;
}

function fileHasBytes(p) {
  try { return fs.statSync(p).size > 0; } catch (_) { return false; }
}

// Render htmlPath to pngPath. Returns { ok, tool, message }. Best-effort —
// the caller treats failure as non-fatal.
function captureScreenshot(htmlPath, pngPath, width, estHeight) {
  const fileUrl = 'file://' + path.resolve(htmlPath);
  let pwNote;

  // 1) Playwright CLI — true full-page, no height guessing.
  const pw = whichSync('playwright');
  if (pw) {
    try {
      const r = spawnSync(pw, ['screenshot', '--full-page',
        '--viewport-size', width + ',900', fileUrl, pngPath],
        { encoding: 'utf8', timeout: 120000 });
      if (r.status === 0 && fileHasBytes(pngPath)) {
        return { ok: true, tool: 'playwright', message: 'full-page capture via Playwright' };
      }
      const lines = ((r.stderr || r.stdout || '') + '').trim().split('\n');
      pwNote = lines[lines.length - 1] || (r.error ? r.error.message : 'unknown playwright error');
    } catch (e) {
      pwNote = 'playwright invocation failed: ' + e.message;
    }
  } else {
    pwNote = 'playwright not on PATH';
  }

  // 2) Chrome headless fallback — fixed window sized from a row-count estimate.
  const chrome = findChrome();
  if (chrome) {
    let chNote;
    try {
      const r = spawnSync(chrome, ['--headless=new', '--disable-gpu', '--hide-scrollbars',
        '--default-background-color=0', '--screenshot=' + path.resolve(pngPath),
        '--window-size=' + width + ',' + estHeight, fileUrl],
        { encoding: 'utf8', timeout: 120000 });
      if (fileHasBytes(pngPath)) {
        return {
          ok: true, tool: 'chrome',
          message: 'headless Chrome fallback (Playwright unavailable: ' + pwNote + '); window height '
            + 'estimated at ' + estHeight + 'px from line count, so the page may show trailing '
            + 'whitespace or clip if the estimate is off',
        };
      }
      const lines = ((r.stderr || r.stdout || '') + '').trim().split('\n');
      chNote = lines[lines.length - 1] || (r.error ? r.error.message : 'no output file produced');
    } catch (e) {
      chNote = 'chrome invocation failed: ' + e.message;
    }
    return { ok: false, tool: null, message: 'screenshot failed -- playwright: ' + pwNote + '; chrome: ' + chNote };
  }

  return {
    ok: false, tool: null,
    message: 'no headless browser found (playwright: ' + pwNote + '; no Chrome/Chromium/Edge/Brave). '
      + 'HTML was still written; install Playwright (`brew install playwright` or '
      + '`npx playwright install chromium`) or Google Chrome to enable screenshots.',
  };
}

// --------------------------------------------------------------------------- //
// HTML templates. Placeholders use @@NAME@@ tokens. They are String.raw literals
// so the regex backslashes in the embedded engine survive verbatim; the embedded
// JS is the proven diff engine ported from the reference implementations,
// parameterized only by the keyword set and column labels.
// --------------------------------------------------------------------------- //

const TEMPLATE_2WAY = String.raw`<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>@@TITLE@@</title>
<style>
  :root {
    --bg: #0d1117; --panel: #11161d; --border: #232b36; --fg: #c9d1d9;
    --muted: #6e7681; --gutter: #161b22; --empty-bg: #0b0f14;
    --chg-l: rgba(248, 81, 73, 0.12); --chg-r: rgba(63, 185, 80, 0.13);
    --ins-bg: rgba(63, 185, 80, 0.13); --del-bg: rgba(248, 81, 73, 0.12);
    --mark-l: #f85149; --mark-r: #3fb950;
    --kw: #ff7b72; --str: #a5d6ff; --com: #8b949e; --var: #ffa657; --fn: #d2a8ff; --num: #79c0ff;
  }
  * { box-sizing: border-box; }
  body { margin: 0; background: var(--bg); color: var(--fg);
    font: 14px/1.5 -apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, Helvetica, Arial, sans-serif; }
  header { padding: 28px 32px 20px; border-bottom: 1px solid var(--border);
    background: linear-gradient(180deg, #131922, #0d1117); }
  h1 { margin: 0 0 6px; font-size: 19px; font-weight: 650; letter-spacing: -0.01em; }
  .sub { color: var(--muted); font-size: 13px; max-width: 1100px; }
  .stats { display: flex; gap: 10px; flex-wrap: wrap; margin-top: 16px; }
  .chip { font-size: 12px; padding: 5px 11px; border-radius: 999px; border: 1px solid var(--border);
    background: var(--panel); color: var(--fg); display: inline-flex; align-items: center; gap: 6px; }
  .chip b { font-weight: 650; }
  .dot { width: 8px; height: 8px; border-radius: 50%; display: inline-block; }
  .dot.same { background: var(--muted); }
  .dot.chg  { background: #d29922; }
  .dot.ins  { background: var(--mark-r); }
  .dot.del  { background: var(--mark-l); }

  .colheads { display: grid; grid-template-columns: 1fr 1fr; border-bottom: 1px solid var(--border);
    position: sticky; top: 0; z-index: 5; background: var(--gutter); }
  .colheads div { padding: 10px 16px 10px 56px; font-weight: 600; font-size: 13px; }
  .colheads div + div { border-left: 1px solid var(--border); }
  .colheads .hl { color: #f0a3a0; }
  .colheads .hr { color: #9bdfab; }
  .colheads small { display: block; font-weight: 400; color: var(--muted); font-size: 11px; }

  table { border-collapse: collapse; width: 100%; table-layout: fixed;
    font-family: ui-monospace, SFMono-Regular, "SF Mono", Menlo, Consolas, monospace; font-size: 12.5px; }
  td { vertical-align: top; padding: 0; }
  .gut { text-align: right; padding: 1px 8px 1px 0; color: var(--muted); background: var(--gutter);
    border-right: 1px solid var(--border); user-select: none; white-space: nowrap; }
  .code { padding: 1px 12px; white-space: pre-wrap; word-break: break-word; border-right: 1px solid var(--border); }
  td.code:last-child { border-right: none; }

  tr.eq .code.fill { background: transparent; }
  tr.chg .code.left.fill  { background: var(--chg-l); }
  tr.chg .code.right.fill { background: var(--chg-r); }
  tr.del .code.left.fill  { background: var(--del-bg); }
  tr.ins .code.right.fill { background: var(--ins-bg); }
  .code.empty, .gut.empty { background: var(--empty-bg); }
  .gut.empty { color: #2b313a; }
  .code.blank { background: transparent; }

  tr.chg .gut.left.fill  { box-shadow: inset 3px 0 0 var(--mark-l); }
  tr.chg .gut.right.fill { box-shadow: inset 3px 0 0 var(--mark-r); }
  tr.del .gut.left.fill  { box-shadow: inset 3px 0 0 var(--mark-l); }
  tr.ins .gut.right.fill { box-shadow: inset 3px 0 0 var(--mark-r); }

  /* word-level: when a changed row's cells are compared token-by-token, drop the
     solid tint so per-token marks carry the signal (the gutter bar still shows role) */
  tr.chg .code.fill.wd { background: transparent !important; }
  mark.df { border-radius: 2px; padding: 0 1px; color: inherit; }
  .code.left mark.df  { background: rgba(248, 81, 73, 0.38); }
  .code.right mark.df { background: rgba(63, 185, 80, 0.40); }

  .t-kw { color: var(--kw); } .t-str { color: var(--str); } .t-com { color: var(--com); font-style: italic; }
  .t-var { color: var(--var); } .t-fn { color: var(--fn); } .t-num { color: var(--num); }

  footer { padding: 18px 32px 40px; color: var(--muted); font-size: 12.5px; border-top: 1px solid var(--border); }
  footer code { background: var(--panel); border: 1px solid var(--border); padding: 1px 6px; border-radius: 5px;
    font-family: ui-monospace, monospace; color: #e6edf3; }
  .legend { display: flex; gap: 18px; flex-wrap: wrap; margin-bottom: 10px; }
  .legend span { display: inline-flex; align-items: center; gap: 6px; }
</style>
</head>
<body>
<header>
  <h1>@@TITLE@@</h1>
  <div class="sub">@@SUBTITLE@@</div>
  <div class="stats" id="stats"></div>
</header>

<div class="colheads">@@COLHEADS@@</div>

<table id="diff"><colgroup><col style="width:44px"><col><col style="width:44px"><col></colgroup><tbody></tbody></table>

<footer>
  <div class="legend">@@LEGEND@@</div>
  @@FOOTER@@
</footer>

@@SRCBLOCKS@@

<script>
(function () {
  const SRC = window.__DIFF_SRC__;
  const left = SRC[0].replace(/\n$/, '').split('\n');
  const right = SRC[1].replace(/\n$/, '').split('\n');
  const KW = new Set(@@KEYWORDS@@);
  const SIM = 0.34;
  const norm = s => s.replace(/\s+/g, ' ').trim();
  const nL = left.map(norm), nR = right.map(norm);

  // ---- line-level LCS on normalized lines; blank lines never anchor ----
  const n = left.length, m = right.length;
  const dp = Array.from({ length: n + 1 }, () => new Int32Array(m + 1));
  const eqLine = (i, j) => nL[i] === nR[j] && nL[i] !== '';
  for (let i = n - 1; i >= 0; i--)
    for (let j = m - 1; j >= 0; j--)
      dp[i][j] = eqLine(i, j) ? dp[i + 1][j + 1] + 1 : Math.max(dp[i + 1][j], dp[i][j + 1]);

  const ops = []; let i = 0, j = 0;
  while (i < n && j < m) {
    if (eqLine(i, j)) { ops.push(['eq', left[i], right[j]]); i++; j++; }
    else if (dp[i + 1][j] >= dp[i][j + 1]) { ops.push(['del', left[i], null]); i++; }
    else { ops.push(['ins', null, right[j]]); j++; }
  }
  while (i < n) { ops.push(['del', left[i++], null]); }
  while (j < m) { ops.push(['ins', null, right[j++]]); }

  // ---- pair adjacent del/ins runs into "changed" rows ----
  const rows = []; let bufDel = [], bufIns = [];
  function flush() {
    const k = Math.min(bufDel.length, bufIns.length);
    for (let x = 0; x < k; x++) rows.push(['chg', bufDel[x], bufIns[x]]);
    for (let x = k; x < bufDel.length; x++) rows.push(['del', bufDel[x], null]);
    for (let x = k; x < bufIns.length; x++) rows.push(['ins', null, bufIns[x]]);
    bufDel = []; bufIns = [];
  }
  for (const [t, l, r] of ops) {
    if (t === 'del') bufDel.push(l);
    else if (t === 'ins') bufIns.push(r);
    else { flush(); rows.push(['eq', l, r]); }
  }
  flush();

  // ---- shared tokenizer + word-diff helpers ----
  function esc(s) { return s.replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;'); }
  const TOK = /('(?:[^'\\]|\\.)*'|"(?:[^"\\]|\\.)*")|([A-Za-z0-9_$]+)|([^A-Za-z0-9_$]+)/g;
  function tokenize(line) {
    const out = []; let mt; TOK.lastIndex = 0;
    while ((mt = TOK.exec(line)) !== null) {
      if (mt[1] !== undefined) out.push({ t: 'str', v: mt[1] });
      else if (mt[2] !== undefined) out.push({ t: 'word', v: mt[2] });
      else out.push({ t: 'sep', v: mt[3] });
    }
    return out;
  }
  const keyOf = tk => tk.t === 'str' ? 's:' + tk.v : 'w:' + tk.v.toLowerCase();
  function tokenSet(toks) { const s = new Set(); for (const tk of toks) if (tk.t !== 'sep') s.add(keyOf(tk)); return s; }
  function jac(a, b) { let i = 0; a.forEach(w => { if (b.has(w)) i++; }); const u = a.size + b.size - i; return u ? i / u : 0; }
  function intersect(a, b) { const c = new Set(a); for (const w of [...c]) if (!b.has(w)) c.delete(w); return c; }
  function renderCell(line, common, doMarks) {
    if (line == null) return '';
    const isCom = line.replace(/^\s+/, '').startsWith('//');
    const toks = tokenize(line); let out = '';
    for (let idx = 0; idx < toks.length; idx++) {
      const tk = toks[idx];
      if (tk.t === 'sep') { out += isCom ? '<span class="t-com">' + esc(tk.v) + '</span>' : esc(tk.v); continue; }
      let cls;
      if (isCom) cls = 't-com';
      else if (tk.t === 'str') cls = 't-str';
      else if (/^\d+$/.test(tk.v)) cls = 't-num';
      else if (tk.v[0] === '$') cls = 't-var';
      else if (KW.has(tk.v)) cls = 't-kw';
      else { const nx = toks[idx + 1]; cls = (nx && nx.t === 'sep' && nx.v[0] === '(') ? 't-fn' : ''; }
      const piece = cls ? '<span class="' + cls + '">' + esc(tk.v) + '</span>' : esc(tk.v);
      out += (doMarks && common && !common.has(keyOf(tk))) ? '<mark class="df">' + piece + '</mark>' : piece;
    }
    return out;
  }

  // ---- render ----
  const tbody = document.querySelector('#diff tbody');
  let ln = 0, rn = 0;
  const counts = { eq: 0, chg: 0, del: 0, ins: 0 };
  let html = '';
  function cell(role, line, no, common, doMarks) {
    let state = 'empty';
    if (line != null) state = line.trim() === '' ? 'blank' : 'fill';
    const wd = (state === 'fill' && doMarks) ? ' wd' : '';
    const body = state === 'fill' ? renderCell(line, common, doMarks) : '';
    return '<td class="gut ' + role + ' ' + state + '">' + (line != null ? no : '') + '</td>' +
           '<td class="code ' + role + ' ' + state + wd + '">' + body + '</td>';
  }
  for (const [type, l, r] of rows) {
    const lFill = l != null && l.trim() !== '';
    const rFill = r != null && r.trim() !== '';
    let common = null, doMarks = false;
    if (type === 'chg' && lFill && rFill) {
      const sa = tokenSet(tokenize(l)), sb = tokenSet(tokenize(r));
      if (jac(sa, sb) >= SIM) { common = intersect(sa, sb); doMarks = true; }
      counts.chg++;
    } else if (type === 'eq') { if (lFill || rFill) counts.eq++; }
    else if (type === 'del') { if (lFill) counts.del++; }
    else if (type === 'ins') { if (rFill) counts.ins++; }
    const lNo = l != null ? ++ln : '';
    const rNo = r != null ? ++rn : '';
    html += '<tr class="' + type + '">' +
      cell('left', l, lNo, common, doMarks) + cell('right', r, rNo, common, doMarks) + '</tr>';
  }
  tbody.innerHTML = html;

  const counted = counts.eq + counts.chg + counts.del + counts.ins;
  const pct = counted ? Math.round((counts.eq / counted) * 100) : 0;
  document.getElementById('stats').innerHTML =
    '<span class="chip"><i class="dot same"></i><b>' + counts.eq + '</b> identical</span>' +
    '<span class="chip"><i class="dot chg"></i><b>' + counts.chg + '</b> changed</span>' +
    '<span class="chip"><i class="dot del"></i><b>' + counts.del + '</b> only in @@LABELA@@</span>' +
    '<span class="chip"><i class="dot ins"></i><b>' + counts.ins + '</b> only in @@LABELB@@</span>' +
    '<span class="chip" style="border-color:#2a6">~ <b>' + pct + '%</b> identical lines</span>';
})();
</script>
</body>
</html>
`;

const TEMPLATE_3WAY = String.raw`<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>@@TITLE@@</title>
<style>
  :root {
    --bg: #0d1117; --panel: #11161d; --border: #232b36; --fg: #c9d1d9;
    --muted: #6e7681; --gutter: #161b22;
    --old-bg: rgba(210, 153, 34, 0.13); --new-bg: rgba(63, 185, 80, 0.14); --empty-bg: #0b0f14;
    --kw: #ff7b72; --str: #a5d6ff; --com: #8b949e; --var: #ffa657; --fn: #d2a8ff; --num: #79c0ff;
  }
  * { box-sizing: border-box; }
  body { margin: 0; background: var(--bg); color: var(--fg);
    font: 14px/1.5 -apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, Helvetica, Arial, sans-serif; }
  header { padding: 28px 32px 20px; border-bottom: 1px solid var(--border);
    background: linear-gradient(180deg, #131922, #0d1117); }
  h1 { margin: 0 0 6px; font-size: 19px; font-weight: 650; letter-spacing: -0.01em; }
  .sub { color: var(--muted); font-size: 13px; max-width: 1100px; }
  .stats { display: flex; gap: 10px; flex-wrap: wrap; margin-top: 16px; }
  .chip { font-size: 12px; padding: 5px 11px; border-radius: 999px; border: 1px solid var(--border);
    background: var(--panel); color: var(--fg); display: inline-flex; align-items: center; gap: 6px; }
  .chip b { font-weight: 650; }
  .dot { width: 8px; height: 8px; border-radius: 50%; display: inline-block; }
  .dot.same { background: var(--muted); }
  .dot.old  { background: #d29922; }
  .dot.new  { background: #3fb950; }

  .colheads { display: grid; grid-template-columns: 1fr 1fr 1fr; border-bottom: 1px solid var(--border);
    position: sticky; top: 0; z-index: 5; background: var(--gutter); }
  .colheads div { padding: 10px 16px 10px 56px; font-weight: 600; font-size: 12.5px; }
  .colheads div + div { border-left: 1px solid var(--border); }
  .colheads .ha { color: #f0a3a0; } .colheads .hb { color: #f0c987; } .colheads .hc { color: #9bdfab; }
  .colheads small { display: block; font-weight: 400; color: var(--muted); font-size: 11px; }

  table { border-collapse: collapse; width: 100%; table-layout: fixed;
    font-family: ui-monospace, SFMono-Regular, "SF Mono", Menlo, Consolas, monospace; font-size: 12px; }
  td { vertical-align: top; padding: 0; }
  .gut { text-align: right; padding: 1px 8px 1px 0; color: var(--muted); background: var(--gutter);
    border-right: 1px solid var(--border); user-select: none; white-space: nowrap; }
  .code { padding: 1px 10px; white-space: pre-wrap; word-break: break-word; border-right: 1px solid var(--border); }
  td.code:last-child { border-right: none; }

  tr.eq3 .code { background: transparent; }
  tr.gap .code.fill.a, tr.gap .code.fill.b { background: var(--old-bg); }
  tr.gap .code.fill.c { background: var(--new-bg); }
  tr.gap .code.fill.a, tr.gap .gut.fill.a { box-shadow: inset 3px 0 0 #d29922; }
  tr.gap .code.fill.b, tr.gap .gut.fill.b { box-shadow: inset 3px 0 0 #d29922; }
  tr.gap .code.fill.c, tr.gap .gut.fill.c { box-shadow: inset 3px 0 0 #3fb950; }
  .code.empty, .gut.empty { background: var(--empty-bg); }
  .gut.empty { color: #2b313a; }
  .code.blank { background: transparent; }

  .t-kw { color: var(--kw); } .t-str { color: var(--str); } .t-com { color: var(--com); font-style: italic; }
  .t-var { color: var(--var); } .t-fn { color: var(--fn); } .t-num { color: var(--num); }

  tr.gap .code.fill.wd { background: transparent !important; }
  mark.df { border-radius: 2px; padding: 0 1px; color: inherit; }
  .code.a mark.df, .code.b mark.df { background: rgba(240, 173, 78, 0.40); }
  .code.c mark.df { background: rgba(63, 185, 80, 0.42); }

  footer { padding: 18px 32px 40px; color: var(--muted); font-size: 12.5px; border-top: 1px solid var(--border); }
  footer code { background: var(--panel); border: 1px solid var(--border); padding: 1px 6px; border-radius: 5px;
    font-family: ui-monospace, monospace; color: #e6edf3; }
  .legend { display: flex; gap: 18px; flex-wrap: wrap; margin-bottom: 10px; }
  .legend span { display: inline-flex; align-items: center; gap: 6px; }
</style>
</head>
<body>
<header>
  <h1>@@TITLE@@</h1>
  <div class="sub">@@SUBTITLE@@</div>
  <div class="stats" id="stats"></div>
</header>

<div class="colheads">@@COLHEADS@@</div>

<table id="diff">
  <colgroup><col style="width:40px"><col><col style="width:40px"><col><col style="width:40px"><col></colgroup>
  <tbody></tbody>
</table>

<footer>
  <div class="legend">@@LEGEND@@</div>
  @@FOOTER@@
</footer>

@@SRCBLOCKS@@

<script>
(function () {
  const SRC = window.__DIFF_SRC__;
  const A = SRC[0].replace(/\n$/, '').split('\n');
  const B = SRC[1].replace(/\n$/, '').split('\n');
  const C = SRC[2].replace(/\n$/, '').split('\n');
  const n = A.length, m = B.length, p = C.length;
  const KW = new Set(@@KEYWORDS@@);

  // ---- 3D LCS over (A, B, C); whitespace-insensitive, blank lines never anchor ----
  const norm = (s) => s.replace(/\s+/g, ' ').trim();
  const nA = A.map(norm), nB = B.map(norm), nC = C.map(norm);
  const stride2 = p + 1, stride1 = (m + 1) * stride2;
  const dp = new Int32Array((n + 1) * stride1);
  const at = (i, j, k) => dp[i * stride1 + j * stride2 + k];
  const tri = (i, j, k) => nA[i] === nB[j] && nB[j] === nC[k] && nA[i] !== '';
  for (let i = n - 1; i >= 0; i--)
    for (let j = m - 1; j >= 0; j--)
      for (let k = p - 1; k >= 0; k--) {
        const idx = i * stride1 + j * stride2 + k;
        dp[idx] = tri(i, j, k)
          ? at(i + 1, j + 1, k + 1) + 1
          : Math.max(at(i + 1, j, k), at(i, j + 1, k), at(i, j, k + 1));
      }

  const anchors = [];
  let i = 0, j = 0, k = 0;
  while (i < n && j < m && k < p) {
    if (tri(i, j, k)) { anchors.push([i, j, k]); i++; j++; k++; }
    else {
      const d1 = at(i + 1, j, k), d2 = at(i, j + 1, k), d3 = at(i, j, k + 1);
      const mx = Math.max(d1, d2, d3);
      if (d1 === mx) i++; else if (d2 === mx) j++; else k++;
    }
  }

  const rows = [];
  let ia = 0, jb = 0, kc = 0;
  function gap(toI, toJ, toK) {
    const ga = A.slice(ia, toI), gb = B.slice(jb, toJ), gc = C.slice(kc, toK);
    const h = Math.max(ga.length, gb.length, gc.length);
    for (let g = 0; g < h; g++) {
      rows.push(['gap', g < ga.length ? ga[g] : null, g < gb.length ? gb[g] : null, g < gc.length ? gc[g] : null]);
    }
    ia = toI; jb = toJ; kc = toK;
  }
  for (const [ai, bj, ck] of anchors) {
    gap(ai, bj, ck);
    rows.push(['eq3', A[ai], B[bj], C[ck]]);
    ia = ai + 1; jb = bj + 1; kc = ck + 1;
  }
  gap(n, m, p);

  // ---- tokenizer + word-diff (shared by syntax highlight + intra-line marks) ----
  function esc(s) { return s.replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;'); }
  const TOK = /('(?:[^'\\]|\\.)*'|"(?:[^"\\]|\\.)*")|([A-Za-z0-9_$]+)|([^A-Za-z0-9_$]+)/g;
  function tokenize(line) {
    const out = []; let mt; TOK.lastIndex = 0;
    while ((mt = TOK.exec(line)) !== null) {
      if (mt[1] !== undefined) out.push({ t: 'str', v: mt[1] });
      else if (mt[2] !== undefined) out.push({ t: 'word', v: mt[2] });
      else out.push({ t: 'sep', v: mt[3] });
    }
    return out;
  }
  const keyOf = (tk) => tk.t === 'str' ? 's:' + tk.v : 'w:' + tk.v.toLowerCase();
  function tokenSet(toks) { const s = new Set(); for (const tk of toks) if (tk.t !== 'sep') s.add(keyOf(tk)); return s; }
  function jac(a, b) { let i = 0; a.forEach(w => { if (b.has(w)) i++; }); const u = a.size + b.size - i; return u ? i / u : 0; }
  function avgPair(sets) { let s = 0, c = 0; for (let x = 0; x < sets.length; x++) for (let y = x + 1; y < sets.length; y++) { s += jac(sets[x], sets[y]); c++; } return c ? s / c : 0; }
  function intersect(sets) { const c = new Set(sets[0]); for (let x = 1; x < sets.length; x++) for (const w of [...c]) if (!sets[x].has(w)) c.delete(w); return c; }
  const SIM = 0.34;

  function renderCell(line, common, doMarks) {
    if (line == null) return '';
    const isCom = line.replace(/^\s+/, '').startsWith('//');
    const toks = tokenize(line); let out = '';
    for (let idx = 0; idx < toks.length; idx++) {
      const tk = toks[idx];
      if (tk.t === 'sep') { out += isCom ? '<span class="t-com">' + esc(tk.v) + '</span>' : esc(tk.v); continue; }
      let cls;
      if (isCom) cls = 't-com';
      else if (tk.t === 'str') cls = 't-str';
      else if (/^\d+$/.test(tk.v)) cls = 't-num';
      else if (tk.v[0] === '$') cls = 't-var';
      else if (KW.has(tk.v)) cls = 't-kw';
      else { const nx = toks[idx + 1]; cls = (nx && nx.t === 'sep' && nx.v[0] === '(') ? 't-fn' : ''; }
      const piece = cls ? '<span class="' + cls + '">' + esc(tk.v) + '</span>' : esc(tk.v);
      out += (doMarks && common && !common.has(keyOf(tk))) ? '<mark class="df">' + piece + '</mark>' : piece;
    }
    return out;
  }

  const tbody = document.querySelector('#diff tbody');
  let na = 0, nb = 0, nc = 0;
  let same = 0, aOnly = 0, bOnly = 0, cOnly = 0;
  let html = '';
  function cell(role, line, no, common, doMarks) {
    let state = 'empty';
    if (line != null) state = line.trim() === '' ? 'blank' : 'fill';
    const wd = (state === 'fill' && doMarks) ? ' wd' : '';
    const body = state === 'fill' ? renderCell(line, common, doMarks) : '';
    return '<td class="gut ' + role + ' ' + state + '">' + (line != null ? no : '') + '</td>' +
           '<td class="code ' + role + ' ' + state + wd + '">' + body + '</td>';
  }
  for (const [type, a, b, c] of rows) {
    let common = null, doMarks = false;
    if (type === 'eq3') { same++; }
    else {
      if (a != null && a.trim()) aOnly++;
      if (b != null && b.trim()) bOnly++;
      if (c != null && c.trim()) cOnly++;
      const present = [a, b, c].filter(l => l != null && l.trim() !== '');
      if (present.length >= 2) {
        const sets = present.map(l => tokenSet(tokenize(l)));
        if (avgPair(sets) >= SIM) { common = intersect(sets); doMarks = true; }
      }
    }
    const noA = a != null ? ++na : '';
    const noB = b != null ? ++nb : '';
    const noC = c != null ? ++nc : '';
    html += '<tr class="' + type + '">' +
      cell('a', a, noA, common, doMarks) + cell('b', b, noB, common, doMarks) + cell('c', c, noC, common, doMarks) +
      '</tr>';
  }
  tbody.innerHTML = html;

  document.getElementById('stats').innerHTML =
    '<span class="chip"><i class="dot same"></i><b>' + same + '</b> shared by all three</span>' +
    '<span class="chip"><i class="dot old"></i><b>' + aOnly + '</b> only in @@LABELA@@</span>' +
    '<span class="chip"><i class="dot old"></i><b>' + bOnly + '</b> only in @@LABELB@@</span>' +
    '<span class="chip"><i class="dot new"></i><b>' + cOnly + '</b> only in @@LABELC@@</span>';
})();
</script>
</body>
</html>
`;

function buildColheads2way(labels, sublabels) {
  const cls = ['hl', 'hr'];
  let out = '';
  for (let idx = 0; idx < 2; idx++) {
    const sub = sublabels[idx] ? '<small>' + escText(sublabels[idx]) + '</small>' : '';
    out += '<div class="' + cls[idx] + '">' + escText(labels[idx]) + sub + '</div>';
  }
  return out;
}

function buildColheads3way(labels, sublabels) {
  const cls = ['ha', 'hb', 'hc'];
  let out = '';
  for (let idx = 0; idx < 3; idx++) {
    const sub = sublabels[idx] ? '<small>' + escText(sublabels[idx]) + '</small>' : '';
    out += '<div class="' + cls[idx] + '">' + escText(labels[idx]) + sub + '</div>';
  }
  return out;
}

function buildLegend(labels, threeWay) {
  if (threeWay) {
    return '<span><i class="dot same"></i> identical in all three</span>'
      + '<span><i class="dot old"></i> only in ' + escText(labels[0]) + '</span>'
      + '<span><i class="dot old"></i> only in ' + escText(labels[1]) + '</span>'
      + '<span><i class="dot new"></i> only in ' + escText(labels[2]) + '</span>';
  }
  return '<span><i class="dot same"></i> identical line</span>'
    + '<span><i class="dot chg"></i> changed (paired)</span>'
    + '<span><i class="dot del"></i> only in ' + escText(labels[0]) + '</span>'
    + '<span><i class="dot ins"></i> only in ' + escText(labels[1]) + '</span>';
}

// Embed the sources as an ASCII-safe JS array the engine reads directly.
function buildSrcBlocks(sources) {
  const lits = sources.map(jsSourceLiteral).join(',\n');
  return '<script>\nwindow.__DIFF_SRC__ = [\n' + lits + '\n];\n</' + 'script>';
}

// --------------------------------------------------------------------------- //
// Arg parsing (small hand-rolled parser — keeps the script dependency-free)
// --------------------------------------------------------------------------- //
const HELP = `gen-diff.js — generate a self-contained HTML code-diff view (2-way or 3-way) and optionally screenshot it.

Usage:
  gen-diff.js <fileA> <fileB> [fileC] [options]
  gen-diff.js --git REF:PATH --git REF:PATH [options]

Sources: 2 or 3, as positional file paths and/or --git refs (column order = order given; --git before files).

Options:
  --title "..."          Page title / H1 (default: derived from labels)
  --subtitle "..."       Muted subtitle line under the title
  --label "..."          Column label (repeatable, in column order; default: file basename)
  --sublabel "..."       Small text under a column label (repeatable)
  --lang <name>          Keyword set: php (default), js, ts, python, go, ruby, rust, sql, generic
                         (inferred from the first file extension when omitted)
  --keywords "a,b,c"     Explicit keyword list, overrides --lang
  --note "..."           Footer note (plain text)
  --git REF:PATH         Add a source from a git ref (repeatable; precedes positional files)
  --out PATH             Output HTML path (default: /tmp/collab-tools/<slug>-<YYYY-MM-DD>.html)
  --screenshot           Also render a full-page PNG (best-effort)
  --screenshot-out PATH  PNG output path (default: HTML path with .png)
  --width N              Screenshot width in px (default 1400)
  -h, --help             Show this help
`;

function parseArgs(argv) {
  const o = {
    files: [], git: [], label: [], sublabel: [],
    title: null, subtitle: '', lang: null, keywords: null, note: '',
    out: null, width: 1400, screenshot: false, screenshotOut: null,
  };
  const repeatable = { '--git': 'git', '--label': 'label', '--sublabel': 'sublabel' };
  const single = {
    '--title': 'title', '--subtitle': 'subtitle', '--lang': 'lang',
    '--keywords': 'keywords', '--note': 'note', '--out': 'out', '--screenshot-out': 'screenshotOut',
  };
  for (let i = 0; i < argv.length; i++) {
    let a = argv[i];
    if (a === '-h' || a === '--help') { process.stdout.write(HELP); process.exit(0); }
    if (a === '--screenshot') { o.screenshot = true; continue; }
    let val = null;
    if (a.startsWith('--') && a.includes('=')) { const eq = a.indexOf('='); val = a.slice(eq + 1); a = a.slice(0, eq); }
    const need = () => { if (val === null) { val = argv[++i]; } if (val === undefined) die('missing value for ' + a); return val; };
    if (a === '--width') { o.width = parseInt(need(), 10) || 1400; continue; }
    if (repeatable[a]) { o[repeatable[a]].push(need()); continue; }
    if (single[a]) { o[single[a]] = need(); continue; }
    if (a.startsWith('--')) die('unknown option: ' + a);
    o.files.push(a);
  }
  return o;
}

// --------------------------------------------------------------------------- //
function main() {
  const o = parseArgs(process.argv.slice(2));

  // collect sources (git first, then files), preserving order within each
  const sources = [], kinds = [], rawValues = [];
  for (const g of o.git) { sources.push(readGit(g)); kinds.push('git'); rawValues.push(g); }
  for (const f of o.files) { sources.push(readSource(f)); kinds.push('file'); rawValues.push(f); }

  if (sources.length !== 2 && sources.length !== 3) {
    die('need exactly 2 or 3 sources (got ' + sources.length + '); pass 2-3 files and/or --git refs. Use -h for help.');
  }
  const threeWay = sources.length === 3;

  // labels / sublabels
  const labels = [];
  for (let idx = 0; idx < sources.length; idx++) {
    labels.push(idx < o.label.length ? o.label[idx] : defaultLabelFor(kinds[idx], rawValues[idx], idx));
  }
  const sublabels = [];
  for (let idx = 0; idx < sources.length; idx++) sublabels.push(idx < o.sublabel.length ? o.sublabel[idx] : '');

  // keyword set
  let kw;
  if (o.keywords !== null) {
    kw = o.keywords.split(',').map((w) => w.trim()).filter(Boolean);
  } else {
    let lang = o.lang;
    if (!lang) {
      let ext = '';
      for (let idx = 0; idx < kinds.length; idx++) {
        if (kinds[idx] === 'file') { ext = path.extname(rawValues[idx]).toLowerCase(); break; }
        if (kinds[idx] === 'git') { ext = path.extname(rawValues[idx].split(':').slice(1).join(':')).toLowerCase(); break; }
      }
      lang = EXT_LANG[ext] || 'php';
    }
    kw = KEYWORDS[lang.toLowerCase()] || KEYWORDS.php;
  }

  // title / out path
  const title = o.title || (threeWay
    ? labels[0] + ' / ' + labels[1] + ' / ' + labels[2]
    : labels[0] + ' vs ' + labels[1]);
  let outPath = o.out;
  if (!outPath) {
    fs.mkdirSync('/tmp/collab-tools', { recursive: true });
    const today = new Date().toISOString().slice(0, 10);
    outPath = '/tmp/collab-tools/' + slugify(o.title || 'code-diff') + '-' + today + '.html';
  }

  // render — function replacements so '$' in sources/labels is never treated as
  // a replaceAll special pattern ($&, $1, ...). PHP $vars would otherwise mangle.
  const template = threeWay ? TEMPLATE_3WAY : TEMPLATE_2WAY;
  const colheads = threeWay ? buildColheads3way(labels, sublabels) : buildColheads2way(labels, sublabels);
  let html = template;
  html = html.replaceAll('@@TITLE@@', () => escText(title));
  html = html.replaceAll('@@SUBTITLE@@', () => escText(o.subtitle));
  html = html.replaceAll('@@COLHEADS@@', () => colheads);
  html = html.replaceAll('@@LEGEND@@', () => buildLegend(labels, threeWay));
  html = html.replaceAll('@@FOOTER@@', () => escText(o.note));
  html = html.replaceAll('@@SRCBLOCKS@@', () => buildSrcBlocks(sources));
  html = html.replaceAll('@@KEYWORDS@@', () => jsStringArray(kw));
  html = html.replaceAll('@@LABELA@@', () => labelJs(labels[0]));
  html = html.replaceAll('@@LABELB@@', () => labelJs(labels[1]));
  if (threeWay) html = html.replaceAll('@@LABELC@@', () => labelJs(labels[2]));

  const outDir = path.dirname(path.resolve(outPath));
  fs.mkdirSync(outDir, { recursive: true });
  fs.writeFileSync(outPath, html, 'utf8');
  process.stdout.write('HTML: ' + path.resolve(outPath) + '\n');

  // optional screenshot
  if (o.screenshot) {
    const pngPath = o.screenshotOut || (outPath.replace(/\.[^./]*$/, '') + '.png');
    const totalLines = sources.reduce((acc, s) => acc + s.split('\n').length, 0);
    const estHeight = Math.max(600, Math.min(50000, 260 + totalLines * 20 + 200));
    const res = captureScreenshot(outPath, pngPath, o.width, estHeight);
    if (res.ok) {
      process.stdout.write('PNG:  ' + path.resolve(pngPath) + ' (' + res.message + ')\n');
    } else {
      process.stderr.write('PNG:  not created -- ' + res.message + '\n');
      // Non-fatal: the HTML is the primary deliverable.
    }
  }
}

main();
