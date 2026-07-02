#!/usr/bin/env node
// =============================================================================
// Hotline Switchboard: live read-only dashboard of hotline conversations
// By Justin Sternberg <me@jtsternberg.com>
//
// Zero-dependency Node server. Reads the hotline call registry at
// ~/.agents-hotline/sessions/*.json, resolves each session ID to its Claude
// Code transcript (~/.claude/projects/*/<session-id>.jsonl), and serves a
// dashboard that renders conversations and streams new entries via SSE as
// the transcripts grow. View-only: never writes to registry or transcripts.
//
// Usage:
//   node server.js [--port=4160] [--stale-hours=24]
// =============================================================================
'use strict';

const http = require('http');
const fs = require('fs');
const path = require('path');
const os = require('os');

const HOME = os.homedir();
const SESSIONS_DIR = process.env.HOTLINE_SESSIONS_DIR || path.join(HOME, '.agents-hotline', 'sessions');
const PROJECTS_ROOT = process.env.HOTLINE_PROJECTS_ROOT || path.join(HOME, '.claude', 'projects');

const args = {};
for (const a of process.argv.slice(2)) {
  const m = a.match(/^--([^=]+)(?:=(.*))?$/);
  if (m) args[m[1]] = m[2] === undefined ? true : m[2];
}
const PORT = parseInt(args.port || process.env.HOTLINE_SWITCHBOARD_PORT || '4160', 10);
const STALE_HOURS = parseFloat(args['stale-hours'] || '24');
const POLL_MS = 1000;

// ---- transcript resolution --------------------------------------------------

const transcriptCache = new Map(); // sessionId -> path|null

function slugifyCwd(cwd) {
  return String(cwd).replace(/[^a-zA-Z0-9]/g, '-');
}

function findTranscript(sessionId, hintCwd) {
  if (!sessionId) return null;
  if (transcriptCache.has(sessionId)) {
    const cached = transcriptCache.get(sessionId);
    if (cached && fs.existsSync(cached)) return cached;
    transcriptCache.delete(sessionId);
  }
  const fname = `${sessionId}.jsonl`;
  // Fast path: derive project dir from the workspace cwd hint
  if (hintCwd) {
    const p = path.join(PROJECTS_ROOT, slugifyCwd(hintCwd), fname);
    if (fs.existsSync(p)) { transcriptCache.set(sessionId, p); return p; }
  }
  // Slow path: scan all project dirs
  let dirs = [];
  try { dirs = fs.readdirSync(PROJECTS_ROOT); } catch { return null; }
  for (const d of dirs) {
    const p = path.join(PROJECTS_ROOT, d, fname);
    if (fs.existsSync(p)) { transcriptCache.set(sessionId, p); return p; }
  }
  transcriptCache.set(sessionId, null);
  return null;
}

// ---- registry reader ---------------------------------------------------------

function fileMtime(p) {
  try { return fs.statSync(p).mtimeMs / 1000; } catch { return 0; }
}

function classify(lastActivity) {
  const ageH = (Date.now() / 1000 - lastActivity) / 3600;
  if (ageH <= 0.25) return 'live';
  if (ageH <= STALE_HOURS) return 'recent';
  return 'stale';
}

function shortName(p) {
  return p ? path.basename(p) : '?';
}

function readCalls() {
  let files = [];
  try { files = fs.readdirSync(SESSIONS_DIR).filter(f => f.endsWith('.json')); } catch { /* no registry */ }
  const calls = [];
  for (const f of files) {
    let reg;
    try { reg = JSON.parse(fs.readFileSync(path.join(SESSIONS_DIR, f), 'utf8')); } catch { continue; }
    const callerPath = reg.caller || '';
    const callerSid = reg.caller_session_id || path.basename(f, '.json');
    const callerTranscript = findTranscript(callerSid, callerPath);
    const connections = reg.connections || {};
    for (const [calleePath, conn] of Object.entries(connections)) {
      const calleeSid = conn.session_id || '';
      const calleeTranscript = findTranscript(calleeSid, calleePath);
      const lastActivity = Math.max(
        conn.last_contact || 0,
        callerTranscript ? fileMtime(callerTranscript) : 0,
        calleeTranscript ? fileMtime(calleeTranscript) : 0
      );
      calls.push({
        id: `${callerSid}:${calleeSid}`,
        caller: { path: callerPath, name: shortName(callerPath), session_id: callerSid, has_transcript: !!callerTranscript },
        callee: { path: calleePath, name: shortName(calleePath), session_id: calleeSid, has_transcript: !!calleeTranscript },
        mode: conn.mode || 'unknown',
        started: conn.started || 0,
        last_activity: lastActivity,
        exchange_count: conn.exchange_count || 0,
        status: classify(lastActivity),
      });
    }
  }
  calls.sort((a, b) => b.last_activity - a.last_activity);
  return calls;
}

// ---- transcript JSONL parser -------------------------------------------------

function textFromContent(content) {
  if (typeof content === 'string') return content;
  if (!Array.isArray(content)) return '';
  return content
    .filter(b => b && b.type === 'text' && typeof b.text === 'string')
    .map(b => b.text)
    .join('\n');
}

function stripSystemNoise(text) {
  // Drop injected harness blocks; keep the human/agent-authored part.
  return text
    .replace(/<system-reminder>[\s\S]*?<\/system-reminder>/g, '')
    .replace(/<command-name>[\s\S]*?<\/command-name>/g, '')
    .replace(/<command-message>[\s\S]*?<\/command-message>/g, '')
    .replace(/<local-command-stdout>[\s\S]*?<\/local-command-stdout>/g, '')
    .replace(/<\/?command-args>/g, '')
    .trim();
}

// Parse one transcript JSONL line into a display entry, or null to skip.
function parseLine(line) {
  let obj;
  try { obj = JSON.parse(line); } catch { return null; }
  if (!obj || typeof obj !== 'object') return null;
  if (obj.isSidechain) return null; // subagent chatter
  const ts = obj.timestamp || null;

  if (obj.type === 'summary') {
    return { role: 'system', kind: 'summary', ts, text: obj.summary || 'Conversation compacted' };
  }

  const msg = obj.message;
  if (!msg) return null;

  if (obj.type === 'user') {
    if (obj.isMeta) return null;
    const content = msg.content;
    // Tool results come back as user-role entries — show compactly.
    if (Array.isArray(content)) {
      const toolResults = content.filter(b => b && b.type === 'tool_result');
      if (toolResults.length && toolResults.length === content.length) {
        return { role: 'tool', kind: 'tool_result', ts, text: summarizeToolResult(toolResults) };
      }
    }
    const text = stripSystemNoise(textFromContent(content));
    if (!text) return null;
    return { role: 'user', kind: 'text', ts, text };
  }

  if (obj.type === 'assistant') {
    const content = Array.isArray(msg.content) ? msg.content : [];
    const parts = [];
    let toolUses = [];
    for (const b of content) {
      if (!b) continue;
      if (b.type === 'text' && b.text && b.text.trim()) parts.push(b.text);
      if (b.type === 'tool_use') toolUses.push(toolUseLabel(b));
    }
    if (!parts.length && !toolUses.length) return null;
    return {
      role: 'assistant',
      kind: 'text',
      ts,
      text: parts.join('\n\n'),
      tools: toolUses,
    };
  }

  return null;
}

function toolUseLabel(b) {
  const name = b.name || 'tool';
  let hint = '';
  const inp = b.input || {};
  if (typeof inp.command === 'string') hint = inp.command;
  else if (typeof inp.file_path === 'string') hint = inp.file_path;
  else if (typeof inp.pattern === 'string') hint = inp.pattern;
  else if (typeof inp.prompt === 'string') hint = inp.prompt;
  else if (typeof inp.skill === 'string') hint = inp.skill;
  hint = String(hint).replace(/\s+/g, ' ').slice(0, 120);
  return hint ? `${name}: ${hint}` : name;
}

function summarizeToolResult(results) {
  const out = [];
  for (const r of results) {
    let text = '';
    if (typeof r.content === 'string') text = r.content;
    else if (Array.isArray(r.content)) text = textFromContent(r.content);
    text = text.replace(/\s+/g, ' ').trim();
    if (text.length > 200) text = text.slice(0, 200) + '…';
    out.push((r.is_error ? '⚠ ' : '') + (text || '(no output)'));
  }
  return out.join('\n');
}

// Read a transcript from a byte offset; return {entries, offset}.
// Only parses complete lines — a partial trailing line stays unconsumed.
function readTranscript(file, fromOffset) {
  let stat;
  try { stat = fs.statSync(file); } catch { return { entries: [], offset: fromOffset }; }
  if (stat.size <= fromOffset) return { entries: [], offset: Math.min(fromOffset, stat.size) };

  const len = stat.size - fromOffset;
  const buf = Buffer.alloc(len);
  const fd = fs.openSync(file, 'r');
  try { fs.readSync(fd, buf, 0, len, fromOffset); } finally { fs.closeSync(fd); }

  const chunk = buf.toString('utf8');
  const lastNewline = chunk.lastIndexOf('\n');
  if (lastNewline === -1) return { entries: [], offset: fromOffset };

  const complete = chunk.slice(0, lastNewline);
  const consumed = Buffer.byteLength(chunk.slice(0, lastNewline + 1), 'utf8');
  const entries = [];
  for (const line of complete.split('\n')) {
    if (!line.trim()) continue;
    const e = parseLine(line);
    if (e) entries.push(e);
  }
  return { entries, offset: fromOffset + consumed };
}

// ---- HTTP server --------------------------------------------------------------

function json(res, code, data) {
  res.writeHead(code, { 'Content-Type': 'application/json' });
  res.end(JSON.stringify(data));
}

const server = http.createServer((req, res) => {
  const url = new URL(req.url, `http://localhost:${PORT}`);

  if (url.pathname === '/') {
    res.writeHead(200, { 'Content-Type': 'text/html; charset=utf-8' });
    res.end(DASHBOARD_HTML);
    return;
  }

  if (url.pathname === '/api/calls') {
    json(res, 200, { calls: readCalls() });
    return;
  }

  if (url.pathname === '/api/transcript') {
    const sid = url.searchParams.get('session') || '';
    if (!/^[A-Za-z0-9-]+$/.test(sid)) return json(res, 400, { error: 'bad session id' });
    const file = findTranscript(sid);
    if (!file) return json(res, 404, { error: 'transcript not found', session: sid });
    const offset = parseInt(url.searchParams.get('offset') || '0', 10) || 0;
    const result = readTranscript(file, offset);
    return json(res, 200, { session: sid, ...result });
  }

  if (url.pathname === '/api/watch') {
    // SSE: ?sessions=sid1,sid2 — streams new entries as transcripts grow.
    const sids = (url.searchParams.get('sessions') || '').split(',').filter(s => /^[A-Za-z0-9-]+$/.test(s));
    if (!sids.length) return json(res, 400, { error: 'no sessions' });
    res.writeHead(200, {
      'Content-Type': 'text/event-stream',
      'Cache-Control': 'no-cache',
      Connection: 'keep-alive',
    });
    const offsets = {};
    for (const sid of sids) {
      const file = findTranscript(sid);
      offsets[sid] = { file, offset: file ? fs.statSync(file).size : 0 };
    }
    const timer = setInterval(() => {
      for (const sid of sids) {
        const st = offsets[sid];
        if (!st.file) {
          st.file = findTranscript(sid); // may appear later
          if (!st.file) continue;
        }
        const { entries, offset } = readTranscript(st.file, st.offset);
        st.offset = offset;
        if (entries.length) {
          res.write(`data: ${JSON.stringify({ session: sid, entries })}\n\n`);
        }
      }
    }, POLL_MS);
    const ping = setInterval(() => res.write(': ping\n\n'), 25000);
    req.on('close', () => { clearInterval(timer); clearInterval(ping); });
    return;
  }

  json(res, 404, { error: 'not found' });
});

// ---- dashboard UI (inline, no build step) -------------------------------------

const DASHBOARD_HTML = /* html */ `<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<title>Hotline Switchboard</title>
<meta name="viewport" content="width=device-width, initial-scale=1">
<style>
  :root {
    --bg: #12100e; --panel: #1c1917; --panel2: #242019; --line: #3a332a;
    --text: #e8e0d2; --dim: #9a8f7d; --accent: #e0a458; --live: #7bc47f;
    --recent: #e0a458; --stale: #6b6154; --user: #58a6e0; --assistant: #e0a458;
  }
  * { box-sizing: border-box; }
  body { margin: 0; background: var(--bg); color: var(--text); font: 14px/1.5 -apple-system, "Segoe UI", sans-serif; }
  header { padding: 14px 20px; border-bottom: 1px solid var(--line); display: flex; align-items: baseline; gap: 12px; }
  header h1 { margin: 0; font-size: 17px; letter-spacing: 1px; }
  header h1::before { content: "☎ "; color: var(--accent); }
  header .sub { color: var(--dim); font-size: 12px; }
  main { display: grid; grid-template-columns: 340px 1fr; height: calc(100vh - 49px); }
  #board { border-right: 1px solid var(--line); overflow-y: auto; padding: 10px; }
  .section-label { color: var(--dim); font-size: 11px; text-transform: uppercase; letter-spacing: 1.5px; margin: 12px 6px 6px; }
  .call { background: var(--panel); border: 1px solid var(--line); border-radius: 8px; padding: 10px 12px; margin-bottom: 8px; cursor: pointer; }
  .call:hover, .call.active { border-color: var(--accent); }
  .call .pair { font-weight: 600; display: flex; align-items: center; gap: 6px; }
  .call .pair .arrow { color: var(--accent); }
  .call .meta { color: var(--dim); font-size: 12px; margin-top: 3px; display: flex; gap: 10px; }
  .dot { display: inline-block; width: 8px; height: 8px; border-radius: 50%; }
  .dot.live { background: var(--live); box-shadow: 0 0 6px var(--live); }
  .dot.recent { background: var(--recent); }
  .dot.stale { background: var(--stale); }
  #view { display: grid; grid-template-columns: 1fr 1fr; overflow: hidden; }
  #view.empty { display: flex; align-items: center; justify-content: center; color: var(--dim); }
  .lane { display: flex; flex-direction: column; overflow: hidden; border-right: 1px solid var(--line); }
  .lane:last-child { border-right: none; }
  .lane h2 { margin: 0; padding: 10px 14px; font-size: 13px; background: var(--panel2); border-bottom: 1px solid var(--line); color: var(--accent); font-weight: 600; }
  .lane h2 .sid { color: var(--dim); font-weight: 400; font-size: 11px; margin-left: 8px; }
  .entries { overflow-y: auto; padding: 12px; flex: 1; }
  .entry { margin-bottom: 12px; }
  .entry .who { font-size: 11px; text-transform: uppercase; letter-spacing: 1px; margin-bottom: 2px; }
  .entry.user .who { color: var(--user); }
  .entry.assistant .who { color: var(--assistant); }
  .entry.tool .who, .entry.system .who { color: var(--dim); }
  .entry .body { background: var(--panel); border: 1px solid var(--line); border-radius: 8px; padding: 8px 12px; overflow-wrap: break-word; }
  .entry.tool .body, .entry.system .body { color: var(--dim); font-size: 12px; background: transparent; border-style: dashed; }
  .entry .tools { color: var(--dim); font-size: 12px; font-family: ui-monospace, monospace; margin-top: 4px; }
  .entry .tools div::before { content: "⚙ "; }
  .body pre { background: #0c0a08; border: 1px solid var(--line); border-radius: 6px; padding: 8px 10px; overflow-x: auto; font-size: 12px; }
  .body code { background: #0c0a08; padding: 1px 5px; border-radius: 4px; font-size: 12.5px; }
  .body pre code { background: none; padding: 0; }
  .missing { color: var(--dim); font-style: italic; padding: 20px; }
</style>
</head>
<body>
<header><h1>Hotline Switchboard</h1><span class="sub">read-only · live</span></header>
<main>
  <div id="board"></div>
  <div id="view" class="empty">Pick up a line…</div>
</main>
<script>
let activeCallId = null;
let eventSource = null;

function esc(s) { return s.replace(/&/g,'&amp;').replace(/</g,'&lt;').replace(/>/g,'&gt;'); }

// Minimal markdown: fenced code, inline code, bold, links, paragraphs.
function md(text) {
  const parts = text.split(/\\n?\`\`\`(?:[a-zA-Z0-9_-]*)\\n?/);
  let html = '';
  for (let i = 0; i < parts.length; i++) {
    if (i % 2 === 1) { html += '<pre><code>' + esc(parts[i]) + '</code></pre>'; continue; }
    let t = esc(parts[i]);
    t = t.replace(/\`([^\`\\n]+)\`/g, '<code>$1</code>');
    t = t.replace(/\\*\\*([^*\\n]+)\\*\\*/g, '<strong>$1</strong>');
    t = t.replace(/(https?:\\/\\/[^\\s<)]+)/g, '<a href="$1" target="_blank" style="color:var(--accent)">$1</a>');
    t = t.split(/\\n{2,}/).map(p => '<p style="margin:0 0 8px">' + p.replace(/\\n/g, '<br>') + '</p>').join('');
    html += t;
  }
  return html;
}

function fmtAge(ts) {
  if (!ts) return '';
  const s = Math.max(0, Date.now()/1000 - ts);
  if (s < 90) return Math.round(s) + 's ago';
  if (s < 5400) return Math.round(s/60) + 'm ago';
  if (s < 129600) return Math.round(s/3600) + 'h ago';
  return Math.round(s/86400) + 'd ago';
}

async function loadBoard() {
  const { calls } = await (await fetch('/api/calls')).json();
  const board = document.getElementById('board');
  const groups = { live: [], recent: [], stale: [] };
  calls.forEach(c => groups[c.status].push(c));
  board.innerHTML = ['live','recent','stale'].map(g => {
    if (!groups[g].length) return '';
    return '<div class="section-label">' + g + ' (' + groups[g].length + ')</div>' +
      groups[g].map(c => \`
        <div class="call\${c.id === activeCallId ? ' active' : ''}" data-id="\${esc(c.id)}"
             data-caller="\${esc(c.caller.session_id)}" data-callee="\${esc(c.callee.session_id)}"
             data-caller-name="\${esc(c.caller.name)}" data-callee-name="\${esc(c.callee.name)}">
          <div class="pair"><span class="dot \${c.status}"></span> \${esc(c.caller.name)} <span class="arrow">→</span> \${esc(c.callee.name)}</div>
          <div class="meta"><span>\${esc(c.mode)}</span><span>\${fmtAge(c.last_activity)}</span><span>\${c.exchange_count}✕</span></div>
        </div>\`).join('');
  }).join('');
  board.querySelectorAll('.call').forEach(el => el.addEventListener('click', () => openCall(el.dataset)));
}

function entryHtml(e) {
  const who = e.role === 'assistant' ? 'claude' : e.role;
  const tools = (e.tools || []).map(t => '<div>' + esc(t) + '</div>').join('');
  const body = e.text ? '<div class="body">' + md(e.text) + '</div>' : '';
  return '<div class="entry ' + e.role + '"><div class="who">' + esc(who) + '</div>' + body +
    (tools ? '<div class="tools">' + tools + '</div>' : '') + '</div>';
}

function appendEntries(sid, entries) {
  const lane = document.querySelector('.entries[data-session="' + sid + '"]');
  if (!lane) return;
  const nearBottom = lane.scrollHeight - lane.scrollTop - lane.clientHeight < 80;
  lane.insertAdjacentHTML('beforeend', entries.map(entryHtml).join(''));
  if (nearBottom) lane.scrollTop = lane.scrollHeight;
}

async function openCall(d) {
  activeCallId = d.id;
  if (eventSource) { eventSource.close(); eventSource = null; }
  const view = document.getElementById('view');
  view.classList.remove('empty');
  const lanes = [
    { sid: d.caller, name: d.callerName, label: 'caller' },
    { sid: d.callee, name: d.calleeName, label: 'callee' },
  ];
  view.innerHTML = lanes.map(l => \`
    <div class="lane">
      <h2>\${esc(l.label)}: \${esc(l.name)}<span class="sid">\${esc(l.sid.slice(0,8))}</span></h2>
      <div class="entries" data-session="\${esc(l.sid)}"><div class="missing">Loading…</div></div>
    </div>\`).join('');
  document.querySelectorAll('.call').forEach(el => el.classList.toggle('active', el.dataset.id === d.id));

  const sids = [];
  for (const l of lanes) {
    const lane = document.querySelector('.entries[data-session="' + l.sid + '"]');
    const r = await fetch('/api/transcript?session=' + l.sid);
    if (!r.ok) { lane.innerHTML = '<div class="missing">No transcript found for this session.</div>'; continue; }
    const { entries } = await r.json();
    lane.innerHTML = entries.map(entryHtml).join('') || '<div class="missing">Empty transcript.</div>';
    lane.scrollTop = lane.scrollHeight;
    sids.push(l.sid);
  }
  if (sids.length) {
    eventSource = new EventSource('/api/watch?sessions=' + sids.join(','));
    eventSource.onmessage = ev => {
      const { session, entries } = JSON.parse(ev.data);
      appendEntries(session, entries);
    };
  }
}

loadBoard();
setInterval(loadBoard, 5000);
</script>
</body>
</html>`;

server.listen(PORT, '127.0.0.1', () => {
  console.log(`Hotline Switchboard listening on http://127.0.0.1:${PORT}`);
  console.log(`Registry: ${SESSIONS_DIR}`);
  console.log(`Transcripts: ${PROJECTS_ROOT}`);
});
