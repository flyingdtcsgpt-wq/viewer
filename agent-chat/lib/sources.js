'use strict';
// VS Code 의 Claude Code 확장 · Codex 확장이 남기는 대화 기록(jsonl)을 읽어
// 휴대폰 채팅 화면에 보여 줄 메시지 목록으로 바꾼다.
//   Claude : ~/.claude/projects/<폴더>/<세션 id>.jsonl
//   Codex  : ~/.codex/sessions/YYYY/MM/DD/rollout-...-<세션 id>.jsonl
const fs = require('fs');
const path = require('path');
const os = require('os');

const TOOL_OUT_MAX = 3000;
const TOOL_IN_MAX = 1500;
const UUID_RE = /([0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12})\.jsonl$/i;

function claudeHome() { return process.env.CLAUDE_CONFIG_DIR || path.join(os.homedir(), '.claude'); }
function codexHome() { return process.env.CODEX_HOME || path.join(os.homedir(), '.codex'); }

function cut(s, n) {
  if (typeof s !== 'string') s = s == null ? '' : String(s);
  return s.length > n ? s.slice(0, n) + `\n… (${s.length - n}자 더 있음)` : s;
}
/** 자동 메시지 한 줄 요약. <task-notification> 은 상태와 요약만 */
function autoNote(kind, raw) {
  if (/<task-notification>/.test(raw)) {
    const tag = t => { const m = raw.match(new RegExp(`<${t}>([\\s\\S]*?)</${t}>`)); return m ? m[1].trim() : ''; };
    const st = { completed: '끝남', failed: '실패', killed: '중단됨', stopped: '중단됨' }[tag('status')] || tag('status');
    return `백그라운드 작업${st ? ' ' + st : ''}: ` + oneLine(tag('summary') || tag('result') || '알림', 160);
  }
  return `자동 메시지(${kind || '?'}): ` + oneLine(raw, 160);
}

function attachShort(t) {
  t = String(t || '');
  const i = t.indexOf('\n\n[첨부 파일]\n');
  if (i < 0) return t;
  const n = t.slice(i).split('\n').filter(l => l.startsWith('- ')).length;
  return t.slice(0, i) + ` 📎${n}`;
}

function oneLine(s, n = 140) {
  s = String(s || '').replace(/\s+/g, ' ').trim();
  return s.length > n ? s.slice(0, n) + '…' : s;
}
// Windows 의 \\?\C:\... 같은 긴 경로 표시는 떼어 낸다
function normCwd(c) { return String(c).replace(/^\\\\\?\\(UNC\\)?/, (_, unc) => (unc ? '\\\\' : '')); }
// peer.js 와 같은 표식 (순환 참조를 피하려고 여기에도 둔다)
const PEER_HEAD = '[Agent Chat] 아래는 이 세션의 사용자가 휴대폰 앱에서 직접 입력한 메시지입니다. 사용자 본인이 보낸 것이니 PC 에서 입력한 것과 똑같이 처리하세요.';
function unwrapPeer(content) {
  if (typeof content !== 'string') return null;
  const i = content.indexOf(PEER_HEAD);
  if (i < 0) return null;
  const m = content.slice(i + PEER_HEAD.length).match(/^\n---\n([\s\S]*?)\n---/);
  return m ? m[1] : null;
}
function json(v) { try { return JSON.stringify(v, null, 1); } catch { return String(v); } }

// 파일에서 state.offset 이후에 새로 붙은 "완성된 줄"만 읽는다(쓰는 중인 마지막 줄은 다음에).
function readNewLines(file, state) {
  const st = fs.statSync(file);
  if (st.size < state.offset) return null; // 파일이 줄었다 → 처음부터 다시
  const lines = [];
  if (st.size === state.offset) return lines;
  const fd = fs.openSync(file, 'r');
  try {
    let pos = state.offset;
    let carry = Buffer.alloc(0);
    const CHUNK = 4 << 20;
    while (pos < st.size) {
      const n = Math.min(CHUNK, st.size - pos);
      const buf = Buffer.allocUnsafe(n);
      const r = fs.readSync(fd, buf, 0, n, pos);
      if (r <= 0) break;
      pos += r;
      const data = carry.length ? Buffer.concat([carry, buf.subarray(0, r)]) : buf.subarray(0, r);
      let start = 0, i;
      while ((i = data.indexOf(10, start)) !== -1) {
        if (i > start) lines.push(data.toString('utf8', start, i));
        start = i + 1;
      }
      carry = Buffer.from(data.subarray(start));
    }
    state.offset = pos - carry.length;
  } finally { fs.closeSync(fd); }
  return lines;
}

// 공통: keep=false 면 목록용(제목 · 폴더 · 미리보기만), true 면 메시지까지 모은다.
class BaseParser {
  constructor(keep) {
    this.keep = keep;
    this.items = [];
    this.tools = new Map();
    this.rev = 0; // 항목이 바뀔 때마다 올라가는 번호 (실시간으로 바뀐 것만 보내려고)
    this.meta = { cwd: '', title: '', firstUser: '', last: '', lastRole: '' };
  }
  push(item) {
    // 목록 · 제목에는 첨부 경로 대신 "📎 n개"
    const shown = item.role === 'user' ? attachShort(item.text) : item.text;
    if (item.role === 'user' && !this.meta.firstUser) this.meta.firstUser = oneLine(shown, 120);
    if (item.role === 'user' || item.role === 'assistant') {
      this.meta.last = oneLine(String(shown || '').replace(/```[^\n]*|[*`#>|]+/g, ' '), 140);
      this.meta.lastRole = item.role;
    }
    if (!this.keep) return;
    const prev = this.items[this.items.length - 1];
    if (item.role === 'assistant' && item.mid && prev && prev.role === 'assistant' && prev.mid === item.mid) {
      prev.text += '\n\n' + item.text;
      prev.v = ++this.rev;
      return;
    }
    item.n = this.items.length;
    item.v = ++this.rev;
    this.items.push(item);
    if (item.toolId) this.tools.set(item.toolId, item);
  }
  toolResult(id, output, isError) {
    if (!this.keep) return;
    const t = this.tools.get(id);
    if (!t) return;
    t.output = cut(output, TOOL_OUT_MAX);
    t.status = isError ? 'error' : 'done';
    t.v = ++this.rev;
  }
  feedLine(line) {
    let o;
    try { o = JSON.parse(line); } catch { return; }
    if (o && typeof o === 'object') this.feed(o);
  }
  title() {
    const m = this.meta;
    return m.customTitle || m.aiTitle || m.summary || m.threadName || m.firstUser || '(제목 없음)';
  }
}

function toolSummary(name, input) {
  if (!input || typeof input !== 'object') return oneLine(input, 160);
  const pick = input.command ?? input.cmd ?? input.file_path ?? input.path ?? input.pattern ??
    input.url ?? input.query ?? input.description ?? input.prompt;
  if (Array.isArray(pick)) return oneLine(pick[pick.length - 1], 160);
  if (pick != null) return oneLine(pick, 160);
  return oneLine(json(input), 160);
}

function blockText(c) {
  if (typeof c === 'string') return c;
  if (Array.isArray(c)) {
    return c.map(b => (typeof b === 'string' ? b : b && b.type === 'text' ? b.text :
      b && b.type === 'image' ? '[이미지]' : '')).filter(Boolean).join('\n');
  }
  if (c && typeof c === 'object' && typeof c.text === 'string') return c.text;
  return c == null ? '' : json(c);
}

// ---------------- Claude Code ----------------
function cleanClaudeUser(s) {
  if (typeof s !== 'string') return '';
  if (/^\s*<local-command-(stdout|stderr)>/.test(s)) return '';
  if (/^\s*Caveat: The messages below/.test(s)) return '';
  const cmd = s.match(/<command-name>([^<]*)<\/command-name>/);
  if (cmd) {
    const args = s.match(/<command-args>([^<]*)<\/command-args>/);
    return (cmd[1].trim() + ' ' + (args ? args[1].trim() : '')).trim();
  }
  s = s.replace(/<system-reminder>[\s\S]*?<\/system-reminder>/g, '');
  return s.trim();
}

class ClaudeParser extends BaseParser {
  feed(o) {
    const m = this.meta;
    if (o.cwd && !m.cwd) m.cwd = normCwd(o.cwd);
    switch (o.type) {
      case 'ai-title': if (o.aiTitle) m.aiTitle = o.aiTitle; return;
      case 'custom-title': if (o.customTitle) m.customTitle = o.customTitle; return;
      case 'summary': if (o.summary) m.summary = o.summary; return;
      case 'user': return this.user(o);
      case 'assistant': return this.assistant(o);
      case 'system':
        if (o.subtype === 'compact_boundary') this.push({ role: 'system', text: '대화가 압축되었습니다', ts: o.timestamp });
        return;
      default:
    }
  }
  user(o) {
    if (o.isSidechain || o.isCompactSummary || !o.message) return;
    if (o.isMeta) {
      // 다른 세션이 소켓으로 넣은 메시지. 휴대폰(Agent Chat)이 넣은 것은 내 말풍선으로 보여 준다
      const og = o.origin;
      if (!og || og.kind !== 'peer') return;
      const raw = typeof o.message.content === 'string' ? o.message.content : blockText(o.message.content);
      const mine = unwrapPeer(raw);
      if (mine !== null) this.push({ role: 'user', text: mine, ts: o.timestamp, via: 'phone' });
      else this.push({ role: 'system', text: `다른 Claude 세션(${og.from || '?'})의 메시지: ` + oneLine(raw.replace(/^Another Claude session sent a message:\s*/, ''), 160), ts: o.timestamp });
      return;
    }
    const c = o.message.content;
    // 사람이 친 게 아닌 자동 메시지 (백그라운드 작업 끝 알림 등): VS Code 처럼 말풍선이 아니라 한 줄 알림으로
    const raw0 = typeof c === 'string' ? c : Array.isArray(c) ? c.filter(b => b && b.type === 'text').map(b => b.text).join('\n') : '';
    const kind = o.origin && o.origin.kind;
    if ((kind && kind !== 'human') || /^\s*<task-notification>/.test(raw0)) {
      if (Array.isArray(c)) for (const b of c) if (b && b.type === 'tool_result') this.toolResult(b.tool_use_id, blockText(b.content), b.is_error);
      if (raw0.trim()) this.push({ role: 'system', text: autoNote(kind, raw0), ts: o.timestamp });
      return;
    }
    const texts = [];
    if (typeof c === 'string') texts.push(cleanClaudeUser(c));
    else if (Array.isArray(c)) {
      for (const b of c) {
        if (!b) continue;
        if (b.type === 'text') texts.push(cleanClaudeUser(b.text));
        else if (b.type === 'image') texts.push('[이미지]');
        else if (b.type === 'tool_result') this.toolResult(b.tool_use_id, blockText(b.content), b.is_error);
      }
    }
    const text = texts.filter(Boolean).join('\n').trim();
    if (!text) return;
    if (/^\[Request interrupted by user/.test(text)) {
      this.push({ role: 'system', text: '사용자가 중단함', ts: o.timestamp });
      return;
    }
    this.push({ role: 'user', text, ts: o.timestamp });
  }
  assistant(o) {
    if (o.isSidechain || !o.message || !Array.isArray(o.message.content)) return;
    if (o.message.model && !/^<.*>$/.test(o.message.model)) this.meta.model = o.message.model;
    const mid = o.message.id || o.uuid;
    if (o.isApiErrorMessage) {
      this.push({ role: 'system', text: blockText(o.message.content) || 'API 오류', ts: o.timestamp, error: true });
      return;
    }
    for (const b of o.message.content) {
      if (!b) continue;
      if (b.type === 'text' && b.text && b.text.trim()) {
        this.push({ role: 'assistant', text: b.text, mid, ts: o.timestamp });
      } else if (b.type === 'tool_use') {
        this.push({
          role: 'tool', name: b.name, summary: toolSummary(b.name, b.input),
          input: cut(json(b.input), TOOL_IN_MAX), toolId: b.id, status: 'run', ts: o.timestamp,
        });
      }
    }
  }
}

// ---------------- Codex ----------------
const CODEX_WRAPPERS = new Set(['session_meta', 'response_item', 'event_msg', 'turn_context', 'compacted', 'world_state']);

function isCodexInjected(text) {
  const t = text.trim();
  if (!t) return true;
  if (/^# AGENTS\.md instructions/.test(t)) return true;
  // <environment_context> … </environment_context> 처럼 통째로 태그인 자동 삽입문
  const m = t.match(/^<([a-z_]+)>/);
  return !!(m && t.endsWith(`</${m[1]}>`));
}

function codexOutput(p) {
  const out = p.output;
  if (typeof out === 'string') {
    try { const j = JSON.parse(out); if (j && typeof j.output === 'string') return j.output; } catch { /* 그냥 글자 */ }
    return out;
  }
  if (out && typeof out === 'object') {
    if (typeof out.content === 'string') return out.content;
    if (Array.isArray(out.content)) return blockText(out.content.map(x => ({ type: 'text', text: x.text || '' })));
    if (Array.isArray(out)) return blockText(out.map(x => ({ type: 'text', text: x.text || '' })));
  }
  return json(out);
}

class CodexParser extends BaseParser {
  feed(o) {
    const m = this.meta;
    let t = o.type, p = o.payload;
    if (!CODEX_WRAPPERS.has(t)) {
      // 예전 형식: 첫 줄이 {id, timestamp, instructions}, 나머지는 항목이 그대로
      if (!t && o.id) { m.id = o.id; return; }
      if (o.record_type) return;
      p = o; t = 'response_item';
    }
    if (!p || typeof p !== 'object') return;
    const ts = o.timestamp;
    if (t === 'session_meta') {
      m.id = p.id || p.session_id || m.id;
      if (p.cwd) m.cwd = normCwd(p.cwd);
      if (p.originator) m.originator = p.originator;
      return;
    }
    if (t === 'turn_context') {
      if (p.cwd && !m.cwd) m.cwd = normCwd(p.cwd);
      if (p.model) m.model = p.model;
      const eff = p.effort || p.reasoning_effort || (p.collaboration_mode && p.collaboration_mode.settings && p.collaboration_mode.settings.reasoning_effort);
      if (eff) m.effort = eff;
      return;
    }
    if (t === 'event_msg') {
      if (p.type === 'error' && p.message) this.push({ role: 'system', text: p.message, ts, error: true });
      else if (p.type === 'turn_aborted') this.push({ role: 'system', text: '작업이 중단됨', ts });
      else if (p.type === 'thread_name_updated' && p.thread_name) m.threadName = p.thread_name;
      else if (p.type === 'token_count' && p.rate_limits) { m.rateLimits = p.rate_limits; m.rateAt = Date.parse(ts) || 0; }
      return;
    }
    if (t !== 'response_item') return;
    switch (p.type) {
      case 'message': {
        if (!Array.isArray(p.content)) return;
        if (p.role === 'user') {
          const text = p.content.filter(c => c && (c.type === 'input_text' || c.type === 'text'))
            .map(c => c.text || '').filter(x => !isCodexInjected(x)).join('\n').trim();
          const img = p.content.some(c => c && c.type === 'input_image');
          if (text || img) this.push({ role: 'user', text: (text + (img ? '\n[이미지]' : '')).trim(), ts });
        } else if (p.role === 'assistant') {
          const text = p.content.filter(c => c && (c.type === 'output_text' || c.type === 'text'))
            .map(c => c.text || '').join('\n').trim();
          if (text) this.push({ role: 'assistant', text, ts });
        }
        return;
      }
      case 'configuration_update':
        if (p.reasoning && p.reasoning.effort) this.meta.effort = p.reasoning.effort;
        return;
      case 'function_call': {
        let args = p.arguments;
        try { args = JSON.parse(p.arguments); } catch { /* 글자 그대로 */ }
        this.push({ role: 'tool', name: p.name, summary: toolSummary(p.name, args), input: cut(typeof args === 'string' ? args : json(args), TOOL_IN_MAX), toolId: p.call_id, status: 'run', ts });
        return;
      }
      case 'custom_tool_call':
        this.push({ role: 'tool', name: p.name, summary: oneLine(p.input, 160), input: cut(p.input, TOOL_IN_MAX), toolId: p.call_id, status: 'run', ts });
        return;
      case 'local_shell_call': {
        const cmd = p.action && p.action.command;
        const s = Array.isArray(cmd) ? cmd.join(' ') : String(cmd || '');
        this.push({ role: 'tool', name: 'shell', summary: oneLine(s, 160), input: cut(s, TOOL_IN_MAX), toolId: p.call_id || p.id, status: 'run', ts });
        return;
      }
      case 'web_search_call': {
        const q = p.action && (p.action.query || p.action.url);
        this.push({ role: 'tool', name: 'web_search', summary: oneLine(q || '', 160), input: '', status: 'done', ts });
        return;
      }
      case 'function_call_output':
      case 'custom_tool_call_output':
      case 'local_shell_call_output':
        this.toolResult(p.call_id, codexOutput(p), false);
        return;
      default:
    }
  }
}

// ---------------- 파일 찾기 ----------------
function listClaudeFiles() {
  const root = path.join(claudeHome(), 'projects');
  const out = [];
  let dirs = [];
  try { dirs = fs.readdirSync(root, { withFileTypes: true }); } catch { return out; }
  for (const d of dirs) {
    if (!d.isDirectory()) continue;
    const dir = path.join(root, d.name);
    let files = [];
    try { files = fs.readdirSync(dir, { withFileTypes: true }); } catch { continue; }
    for (const f of files) {
      if (!f.isFile() || !f.name.endsWith('.jsonl') || f.name.startsWith('agent-')) continue;
      out.push({ agent: 'claude', id: f.name.slice(0, -6), file: path.join(dir, f.name) });
    }
  }
  return out;
}

function listCodexFiles() {
  const out = [];
  const walk = (dir, depth) => {
    let ents = [];
    try { ents = fs.readdirSync(dir, { withFileTypes: true }); } catch { return; }
    for (const e of ents) {
      const p = path.join(dir, e.name);
      if (e.isDirectory() && depth < 4) walk(p, depth + 1);
      else if (e.isFile() && e.name.endsWith('.jsonl')) {
        const m = e.name.match(UUID_RE);
        if (m) out.push({ agent: 'codex', id: m[1].toLowerCase(), file: p });
      }
    }
  };
  walk(path.join(codexHome(), 'sessions'), 0);
  return out;
}

function codexThreadNames() {
  const names = new Map();
  const f = path.join(codexHome(), 'session_index.jsonl');
  let text = '';
  try { text = fs.readFileSync(f, 'utf8'); } catch { return names; }
  for (const line of text.split('\n')) {
    try { const o = JSON.parse(line); if (o.id && o.thread_name) names.set(String(o.id).toLowerCase(), o.thread_name); } catch { /* 빈 줄 */ }
  }
  return names;
}

function makeParser(agent, keep) { return agent === 'codex' ? new CodexParser(keep) : new ClaudeParser(keep); }

// 세션 하나를 끝까지(이어서) 읽는 묶음
class Tracked {
  constructor(entry, keep) { this.entry = entry; this.keep = keep; this.reset(); }
  reset() { this.parser = makeParser(this.entry.agent, this.keep); this.state = { offset: 0 }; this.epoch = (this.epoch || 0) + 1; }
  update() {
    let lines;
    try { lines = readNewLines(this.entry.file, this.state); } catch { return false; }
    if (lines === null) { this.reset(); lines = readNewLines(this.entry.file, this.state) || []; }
    for (const l of lines) this.parser.feedLine(l);
    return lines.length > 0;
  }
}

class Store {
  constructor() {
    this.metaCache = new Map(); // key → Tracked(keep=false)
    this.full = new Map();      // key → Tracked(keep=true), 최근 몇 개만
    this.index = new Map();     // key → entry
  }
  scan() {
    const all = [...listClaudeFiles(), ...listCodexFiles()];
    this.lastScan = Date.now();
    const seen = new Map();
    for (const e of all) {
      try { const st = fs.statSync(e.file); e.mtime = st.mtimeMs; e.size = st.size; } catch { e.mtime = 0; e.size = 0; }
      const key = e.agent + ':' + e.id;
      // 같은 id 가 두 곳에 있으면(폴더를 옮긴 경우 등) 최근에 쓴 쪽
      const prev = seen.get(key);
      if (prev && prev.mtime >= e.mtime) continue;
      seen.set(key, e);
      this.index.set(key, e);
    }
    return all;
  }
  find(agent, id) {
    const key = agent + ':' + id;
    let e = this.index.get(key);
    // 없거나 지워졌으면 바로, 아니면 3초에 한 번 다시 훑어 새로 생긴 같은 id 기록도 잡는다
    if (!e || !fs.existsSync(e.file) || Date.now() - (this.lastScan || 0) > 3000) { this.scan(); e = this.index.get(key); }
    return e || null;
  }
  list(limit = 150) {
    const all = this.scan().filter(e => e.size > 0).sort((a, b) => b.mtime - a.mtime).slice(0, limit);
    const names = codexThreadNames();
    return all.map(e => {
      const key = e.agent + ':' + e.id;
      let t = this.metaCache.get(key);
      if (!t || t.entry.file !== e.file) { t = new Tracked(e, false); this.metaCache.set(key, t); }
      t.update();
      const m = t.parser.meta;
      if (e.agent === 'codex' && names.has(e.id)) m.threadName = names.get(e.id);
      return {
        agent: e.agent, id: e.id, title: t.parser.title(), cwd: m.cwd, project: m.cwd ? path.basename(m.cwd) : '',
        mtime: e.mtime, preview: m.last, lastRole: m.lastRole, originator: m.originator || '', model: m.model || '', effort: m.effort || '',
      };
    }).filter(s => s.preview || s.title !== '(제목 없음)');
  }
  /** Codex 사용량: 최근 기록들 중 가장 마지막에 남은 rate_limits */
  latestCodexRate() {
    let best = null;
    for (const t of this.metaCache.values()) {
      const m = t.parser.meta;
      if (t.entry.agent === 'codex' && m.rateLimits && (!best || m.rateAt > best.at)) best = { rl: m.rateLimits, at: m.rateAt };
    }
    return best;
  }
  messages(agent, id) {
    const e = this.find(agent, id);
    if (!e) return null;
    const key = agent + ':' + id;
    let t = this.full.get(key);
    if (!t || t.entry.file !== e.file) {
      t = new Tracked(e, true);
      this.full.set(key, t);
      while (this.full.size > 8) this.full.delete(this.full.keys().next().value);
    } else { this.full.delete(key); this.full.set(key, t); }
    t.update();
    let mtime = 0;
    try { mtime = fs.statSync(e.file).mtimeMs; } catch { /* 지워짐 */ }
    const m = t.parser.meta;
    if (agent === 'codex') { const n = codexThreadNames().get(id); if (n) m.threadName = n; }
    return { items: t.parser.items, rev: t.parser.rev, epoch: t.epoch, offset: t.state.offset, mtime, title: t.parser.title(), cwd: m.cwd, model: m.model || '', effort: m.effort || '' };
  }
}

module.exports = {
  normCwd, Store, ClaudeParser, CodexParser, readNewLines, claudeHome, codexHome, listClaudeFiles, listCodexFiles,
};
