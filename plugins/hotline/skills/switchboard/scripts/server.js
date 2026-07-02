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
// Aesthetic: a 1930s telephone operator's console — bakelite panel, brass
// jacks, sagging patch cords, glowing exchange lamps, typewritten log sheets.

const DASHBOARD_HTML = /* html */ `<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<title>Hotline Switchboard</title>
<meta name="viewport" content="width=device-width, initial-scale=1">
<link rel="preconnect" href="https://fonts.googleapis.com">
<link href="https://fonts.googleapis.com/css2?family=Limelight&family=Special+Elite&family=Spectral:ital,wght@0,400;0,600;1,400&display=swap" rel="stylesheet">
<style>
  :root {
    --bakelite: #191210;
    --bakelite-hi: #2b1f1a;
    --panel: #221813;
    --panel2: #2c211a;
    --line: #47362a;
    --brass: #c9973f;
    --brass-hi: #eec877;
    --brass-dim: #8a6a34;
    --cord: #a0522d;
    --lamp-live: #ffd977;
    --lamp-recent: #d98e3a;
    --lamp-stale: #4d4238;
    --paper: #e9ddc3;
    --ink: #ded2b8;
    --dim: #9d8b70;
    --caller-tag: #7fb4c9;
    --operator-tag: #d9a253;
    --serif: 'Spectral', Georgia, serif;
    --type: 'Special Elite', 'Courier New', monospace;
    --display: 'Limelight', serif;
  }
  * { box-sizing: border-box; }
  html, body { height: 100%; }
  body {
    margin: 0; color: var(--ink);
    font: 15px/1.55 var(--serif);
    background:
      radial-gradient(1200px 500px at 50% -10%, #33241c 0%, transparent 60%),
      linear-gradient(180deg, #1d1512 0%, var(--bakelite) 40%);
    background-color: var(--bakelite);
  }
  /* film grain over everything */
  body::after {
    content: ""; position: fixed; inset: 0; pointer-events: none; z-index: 999;
    opacity: .05; mix-blend-mode: overlay;
    background-image: url("data:image/svg+xml,%3Csvg xmlns='http://www.w3.org/2000/svg' width='140' height='140'%3E%3Cfilter id='n'%3E%3CfeTurbulence type='fractalNoise' baseFrequency='0.9' numOctaves='2'/%3E%3C/filter%3E%3Crect width='140' height='140' filter='url(%23n)'/%3E%3C/svg%3E");
  }

  /* ---- header: engraved brass plate ---- */
  header {
    display: flex; align-items: center; gap: 18px;
    padding: 14px 24px 12px;
    background: linear-gradient(180deg, #2e2119, #1c1410);
    border-bottom: 3px solid #0c0806;
    box-shadow: 0 1px 0 #3d2d20 inset, 0 -6px 18px rgba(0,0,0,.6) inset;
  }
  .plate {
    display: inline-flex; align-items: center; gap: 14px;
    padding: 6px 22px 7px;
    background: linear-gradient(175deg, var(--brass-hi) 0%, var(--brass) 30%, #96702c 70%, var(--brass-hi) 100%);
    border-radius: 6px;
    box-shadow: 0 2px 6px rgba(0,0,0,.7), 0 1px 0 rgba(255,240,200,.5) inset, 0 -2px 4px rgba(60,35,0,.5) inset;
    position: relative;
  }
  .plate .screw {
    width: 9px; height: 9px; border-radius: 50%;
    background: radial-gradient(circle at 35% 30%, #f4e0ac, #7a5a24 70%);
    box-shadow: 0 1px 2px rgba(0,0,0,.6) inset;
    position: relative;
  }
  .plate .screw::after {
    content: ""; position: absolute; left: 1px; right: 1px; top: 50%;
    height: 1px; background: #4a3612; transform: rotate(38deg);
  }
  .plate h1 {
    margin: 0; font-family: var(--display); font-size: 21px; font-weight: 400;
    letter-spacing: 3.5px; text-transform: uppercase;
    color: #33220c;
    text-shadow: 0 1px 0 rgba(255,240,200,.55), 0 -1px 0 rgba(40,20,0,.6);
  }
  header .motto {
    font-family: var(--type); font-size: 13px; color: var(--dim);
    letter-spacing: .5px;
  }
  header .onair {
    margin-left: auto; display: flex; align-items: center; gap: 8px;
    font-family: var(--type); font-size: 11px; letter-spacing: 2px; color: var(--dim);
    text-transform: uppercase;
  }
  header .onair .bulb {
    width: 11px; height: 11px; border-radius: 50%;
    background: radial-gradient(circle at 35% 30%, #fff2c0, var(--lamp-live) 55%, #7a4b00);
    box-shadow: 0 0 10px 2px rgba(255,205,90,.55);
    animation: lampglow 2.4s ease-in-out infinite;
  }
  @keyframes lampglow {
    0%,100% { box-shadow: 0 0 10px 2px rgba(255,205,90,.55); }
    50%     { box-shadow: 0 0 16px 4px rgba(255,205,90,.85); }
  }

  main { display: grid; grid-template-columns: 372px 1fr; height: calc(100vh - 62px); }

  /* ---- the patch bay (call board) ---- */
  #board {
    overflow-y: auto; padding: 14px 12px 24px;
    background:
      linear-gradient(90deg, rgba(0,0,0,.35), transparent 12px),
      linear-gradient(180deg, #241a14, #1a120e);
    border-right: 3px solid #0d0906;
    box-shadow: 2px 0 0 #38291e inset;
  }
  .section-label {
    display: flex; align-items: center; gap: 10px;
    font-family: var(--type); font-size: 11px; letter-spacing: 2.5px;
    text-transform: uppercase; color: var(--brass);
    margin: 18px 6px 10px;
  }
  .section-label::before, .section-label::after {
    content: ""; height: 1px; flex: 1;
    background: linear-gradient(90deg, transparent, var(--brass-dim));
  }
  .section-label::after { background: linear-gradient(90deg, var(--brass-dim), transparent); }

  /* one call = two jacks + a sagging patch cord */
  .call {
    position: relative;
    background: linear-gradient(180deg, var(--panel2), var(--panel));
    border: 1px solid var(--line); border-radius: 10px;
    padding: 12px 14px 10px; margin-bottom: 10px; cursor: pointer;
    box-shadow: 0 3px 8px rgba(0,0,0,.45), 0 1px 0 rgba(255,220,160,.06) inset;
    transition: transform .15s ease, border-color .15s ease;
  }
  .call:hover { transform: translateY(-1px); border-color: var(--brass-dim); }
  .call.active {
    border-color: var(--brass);
    box-shadow: 0 3px 12px rgba(0,0,0,.55), 0 0 0 1px var(--brass-dim), 0 1px 0 rgba(255,220,160,.1) inset;
  }
  .patchrow { display: flex; align-items: flex-start; gap: 8px; }
  .jackpost { width: 86px; flex: 0 0 86px; text-align: center; }
  .jack {
    width: 22px; height: 22px; margin: 0 auto 5px; border-radius: 50%;
    background:
      radial-gradient(circle at 50% 50%, #0a0705 0 30%, transparent 31%),
      radial-gradient(circle at 35% 30%, var(--brass-hi), var(--brass) 45%, #6d5122 90%);
    box-shadow: 0 1px 3px rgba(0,0,0,.8), 0 0 0 3px #171008, 0 0 0 4px #3a2c1c;
  }
  .call.active .jack {
    box-shadow: 0 1px 3px rgba(0,0,0,.8), 0 0 0 3px #171008, 0 0 0 4px var(--brass-dim), 0 0 8px 2px rgba(255,205,90,.25);
  }
  .jackpost .name {
    font-family: var(--type); font-size: 12px; line-height: 1.25;
    color: var(--ink); word-break: break-word;
  }
  .cordspan { flex: 1; position: relative; margin-top: 6px; }
  .cordspan svg { display: block; width: 100%; height: 34px; }
  .cordspan .cord {
    fill: none; stroke: var(--cord); stroke-width: 3; stroke-linecap: round;
    filter: drop-shadow(0 2px 1px rgba(0,0,0,.6));
  }
  .cordspan .cord-hi { fill: none; stroke: rgba(255,190,120,.35); stroke-width: 1; }
  .call.active .cord { stroke: #c96f35; }
  .lamp {
    position: absolute; top: -9px; left: 50%; transform: translateX(-50%);
    width: 10px; height: 10px; border-radius: 50%;
    box-shadow: 0 0 0 2px #100a06, 0 0 0 3px #3a2c1c;
  }
  .lamp.live {
    background: radial-gradient(circle at 35% 30%, #fff2c0, var(--lamp-live) 55%, #8a5a00);
    animation: lampglow 1.6s ease-in-out infinite;
  }
  .lamp.recent { background: radial-gradient(circle at 35% 30%, #f0c084, var(--lamp-recent) 60%, #5e3a12); box-shadow: 0 0 0 2px #100a06, 0 0 0 3px #3a2c1c, 0 0 6px 1px rgba(217,142,58,.35); }
  .lamp.stale  { background: radial-gradient(circle at 35% 30%, #6a5c4e, var(--lamp-stale) 60%, #241d16); }
  .call .meta {
    display: flex; gap: 12px; justify-content: center; margin-top: 7px;
    font-family: var(--type); font-size: 10.5px; letter-spacing: 1px;
    text-transform: uppercase; color: var(--dim);
  }
  .call .meta .mode { color: var(--brass); }

  /* ---- the operator's log (transcript view) ---- */
  #view { display: grid; grid-template-columns: 1fr 1fr; overflow: hidden; }
  #view.empty { display: flex; flex-direction: column; align-items: center; justify-content: center; gap: 22px; }
  .dialart { position: relative; width: 150px; height: 150px; border-radius: 50%;
    background: radial-gradient(circle at 35% 30%, #3b2c22, #17100c 75%);
    box-shadow: 0 6px 18px rgba(0,0,0,.6), 0 1px 0 rgba(255,220,160,.08) inset;
    animation: dialsettle 3.2s ease-in-out infinite;
  }
  @keyframes dialsettle { 0%,100% { transform: rotate(0deg);} 50% { transform: rotate(-14deg);} }
  .dialart .hole {
    position: absolute; width: 24px; height: 24px; border-radius: 50%;
    background: radial-gradient(circle at 40% 35%, #241a12, #060403 70%);
    box-shadow: 0 0 0 2px #4a3826, 0 1px 2px rgba(0,0,0,.9) inset;
    left: 50%; top: 50%;
  }
  .dialart .hub { position: absolute; inset: 52px; border-radius: 50%;
    background: radial-gradient(circle at 40% 32%, var(--brass-hi), var(--brass) 50%, #6d5122);
    box-shadow: 0 2px 5px rgba(0,0,0,.7); }
  #view.empty .prompt { font-family: var(--type); font-size: 17px; color: var(--dim); letter-spacing: 1px; }
  #view.empty .prompt em { color: var(--brass); font-style: normal; }

  .lane { display: flex; flex-direction: column; overflow: hidden; border-right: 2px solid #0d0906; }
  .lane:last-child { border-right: none; }
  .lane h2 {
    margin: 0; padding: 9px 16px; display: flex; align-items: baseline; gap: 10px;
    font-family: var(--type); font-weight: 400; font-size: 13px; letter-spacing: 1px;
    color: #2e1f0a; text-transform: uppercase;
    background: linear-gradient(175deg, var(--brass-hi), var(--brass) 40%, #96702c);
    border-bottom: 2px solid #0d0906;
    text-shadow: 0 1px 0 rgba(255,240,200,.4);
  }
  .lane h2 .sid { margin-left: auto; font-size: 10px; color: #57400f; letter-spacing: 2px; }
  .entries { overflow-y: auto; padding: 18px 18px 26px; flex: 1; }

  .entry { margin-bottom: 14px; animation: slidein .25s ease; }
  @keyframes slidein { from { opacity: 0; transform: translateY(5px);} to { opacity: 1; transform: none;} }
  .entry .who {
    display: inline-block; font-family: var(--type); font-size: 10px;
    letter-spacing: 2px; text-transform: uppercase; margin-bottom: 4px;
    padding: 1px 8px 0; border: 1px solid; border-radius: 3px;
  }
  .entry.user .who { color: var(--caller-tag); border-color: rgba(127,180,201,.4); }
  .entry.assistant .who { color: var(--operator-tag); border-color: rgba(217,162,83,.45); }
  .entry.tool .who, .entry.system .who { color: var(--dim); border-color: rgba(157,139,112,.3); }
  .entry .body {
    background: linear-gradient(180deg, rgba(255,235,200,.045), rgba(255,235,200,.02));
    border: 1px solid var(--line); border-left: 3px solid var(--line);
    border-radius: 4px; padding: 9px 14px; overflow-wrap: break-word;
  }
  .entry.user .body { border-left-color: rgba(127,180,201,.55); }
  .entry.assistant .body { border-left-color: rgba(217,162,83,.6); }
  .entry.tool .body, .entry.system .body {
    color: var(--dim); font-size: 12.5px; background: transparent;
    border-style: dashed; border-left-style: dashed;
    font-family: var(--type);
  }
  .entry.system .body { text-align: center; letter-spacing: 1px; }
  .entry .tools { color: var(--dim); font-size: 12px; font-family: var(--type); margin-top: 5px; }
  .entry .tools div { padding-left: 4px; }
  .entry .tools div::before { content: "⚙ "; color: var(--brass-dim); }
  .body p { margin: 0 0 9px; } .body p:last-child { margin-bottom: 0; }
  .body pre {
    background: #0e0a07; border: 1px solid var(--line); border-radius: 5px;
    padding: 9px 12px; overflow-x: auto; font-size: 12.5px; line-height: 1.5;
  }
  .body code {
    background: #0e0a07; padding: 1px 6px; border-radius: 4px; font-size: 13px;
    font-family: ui-monospace, Menlo, monospace; color: #d8b98a;
  }
  .body pre code { background: none; padding: 0; }
  .body a { color: var(--brass-hi); }
  .body strong { color: var(--paper); }
  .missing { color: var(--dim); font-style: italic; padding: 26px; font-family: var(--type); font-size: 13px; text-align: center; }

  ::-webkit-scrollbar { width: 11px; }
  ::-webkit-scrollbar-track { background: #140e0a; }
  ::-webkit-scrollbar-thumb { background: #3d2d20; border-radius: 6px; border: 2px solid #140e0a; }
  ::-webkit-scrollbar-thumb:hover { background: var(--brass-dim); }
</style>
</head>
<body>
<header>
  <div class="plate"><span class="screw"></span><h1>Hotline Switchboard</h1><span class="screw"></span></div>
  <span class="motto">"Number, please?" — read-only operator console</span>
  <div class="onair"><span class="bulb"></span> Exchange live</div>
</header>
<main>
  <div id="board"></div>
  <div id="view" class="empty">
    <div class="dialart" id="dialart"><div class="hub"></div></div>
    <div class="prompt">Number, please? <em>Pick a line to listen in.</em></div>
  </div>
</main>
<script>
let activeCallId = null;
let eventSource = null;

// rotary dial finger holes
(function () {
  const dial = document.getElementById('dialart');
  for (let i = 0; i < 10; i++) {
    const a = (i * 30 - 125) * Math.PI / 180;
    const h = document.createElement('div');
    h.className = 'hole';
    h.style.transform = 'translate(' + (Math.cos(a) * 52 - 12) + 'px,' + (Math.sin(a) * 52 - 12) + 'px)';
    dial.appendChild(h);
  }
})();

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
    t = t.replace(/(https?:\\/\\/[^\\s<)]+)/g, '<a href="$1" target="_blank">$1</a>');
    t = t.split(/\\n{2,}/).map(p => '<p>' + p.replace(/\\n/g, '<br>') + '</p>').join('');
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

const SECTION_NAMES = { live: 'Active lines', recent: 'Recent calls', stale: 'Cold lines' };

// A patch cord: sagging catenary-ish curve between the two jacks, lamp at apex.
function cordSvg() {
  return '<svg viewBox="0 0 100 34" preserveAspectRatio="none">' +
    '<path class="cord" d="M3,5 C30,32 70,32 97,5"/>' +
    '<path class="cord-hi" d="M3,4 C30,30 70,30 97,4"/>' +
    '</svg>';
}

function callCard(c) {
  const rings = c.exchange_count === 1 ? '1 ring' : c.exchange_count + ' rings';
  return '<div class="call' + (c.id === activeCallId ? ' active' : '') + '"' +
    ' data-id="' + esc(c.id) + '"' +
    ' data-caller="' + esc(c.caller.session_id) + '" data-callee="' + esc(c.callee.session_id) + '"' +
    ' data-caller-name="' + esc(c.caller.name) + '" data-callee-name="' + esc(c.callee.name) + '">' +
    '<div class="patchrow">' +
      '<div class="jackpost"><div class="jack"></div><div class="name">' + esc(c.caller.name) + '</div></div>' +
      '<div class="cordspan"><span class="lamp ' + c.status + '"></span>' + cordSvg() + '</div>' +
      '<div class="jackpost"><div class="jack"></div><div class="name">' + esc(c.callee.name) + '</div></div>' +
    '</div>' +
    '<div class="meta"><span class="mode">' + esc(c.mode) + '</span><span>' + fmtAge(c.last_activity) + '</span><span>' + rings + '</span></div>' +
    '</div>';
}

async function loadBoard() {
  const { calls } = await (await fetch('/api/calls')).json();
  const board = document.getElementById('board');
  const groups = { live: [], recent: [], stale: [] };
  calls.forEach(c => groups[c.status].push(c));
  board.innerHTML = ['live','recent','stale'].map(g => {
    if (!groups[g].length) return '';
    return '<div class="section-label">' + SECTION_NAMES[g] + ' · ' + groups[g].length + '</div>' +
      groups[g].map(callCard).join('');
  }).join('');
  board.querySelectorAll('.call').forEach(el => el.addEventListener('click', () => openCall(el.dataset)));
}

function entryHtml(e) {
  const who = e.role === 'assistant' ? 'operator' : (e.role === 'user' ? 'caller' : (e.role === 'tool' ? 'wire' : 'exchange'));
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
    { sid: d.caller, name: d.callerName, label: 'Line A · ' },
    { sid: d.callee, name: d.calleeName, label: 'Line B · ' },
  ];
  view.innerHTML = lanes.map(l =>
    '<div class="lane">' +
      '<h2>' + esc(l.label + l.name) + '<span class="sid">' + esc(l.sid.slice(0,8)) + '</span></h2>' +
      '<div class="entries" data-session="' + esc(l.sid) + '"><div class="missing">Connecting…</div></div>' +
    '</div>').join('');
  document.querySelectorAll('.call').forEach(el => el.classList.toggle('active', el.dataset.id === d.id));

  const sids = [];
  for (const l of lanes) {
    const lane = document.querySelector('.entries[data-session="' + l.sid + '"]');
    const r = await fetch('/api/transcript?session=' + l.sid);
    if (!r.ok) { lane.innerHTML = '<div class="missing">— line disconnected — no transcript on file for this session —</div>'; continue; }
    const { entries } = await r.json();
    lane.innerHTML = entries.map(entryHtml).join('') || '<div class="missing">— silence on the line —</div>';
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
