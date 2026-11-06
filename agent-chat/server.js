#!/usr/bin/env node
'use strict';
// Agent Chat: PC 의 VS Code(Claude Code · Codex 확장) 대화를 휴대폰에서 채팅창처럼 보고 이어서 시키는 작은 서버.
// 외부 라이브러리 없이 Node 18+ 만 있으면 된다.  실행: node server.js
const http = require('http');
const fs = require('fs');
const path = require('path');
const os = require('os');
const zlib = require('zlib');
const crypto = require('crypto');
const { Store } = require('./lib/sources');
const { Runner, CLAUDE_MODES, CODEX_MODES, ID_RE } = require('./lib/runner');

const HOME = process.env.AGENT_CHAT_HOME || path.join(os.homedir(), '.agent-chat');
const CONFIG_FILE = path.join(HOME, 'config.json');
const PUBLIC = path.join(__dirname, 'public');

function loadConfig() {
  let c = {};
  try { c = JSON.parse(fs.readFileSync(CONFIG_FILE, 'utf8')); } catch { /* 처음 실행 */ }
  let changed = false;
  if (!c.token || String(c.token).length < 16) { c.token = crypto.randomBytes(18).toString('base64url'); changed = true; }
  if (!c.port) { c.port = 8790; changed = true; }
  if (!c.host) { c.host = '0.0.0.0'; changed = true; }
  for (const k of ['claudeBin', 'codexBin', 'claudeHome', 'codexHome']) if (!(k in c)) { c[k] = ''; changed = true; }
  for (const k of ['claudeArgs', 'codexArgs', 'projects']) if (!Array.isArray(c[k])) { c[k] = []; changed = true; }
  if (changed) {
    fs.mkdirSync(HOME, { recursive: true });
    fs.writeFileSync(CONFIG_FILE, JSON.stringify(c, null, 2), { mode: 0o600 });
  }
  if (process.env.AGENT_CHAT_PORT) c.port = Number(process.env.AGENT_CHAT_PORT);
  if (process.env.AGENT_CHAT_HOST) c.host = process.env.AGENT_CHAT_HOST;
  // 기록 폴더를 바꿔 쓰는 경우 (claude/codex 실행에도 같은 값이 넘어간다)
  if (c.claudeHome) process.env.CLAUDE_CONFIG_DIR = c.claudeHome;
  if (c.codexHome) process.env.CODEX_HOME = c.codexHome;
  return c;
}

const config = loadConfig();
const store = new Store();
const runner = new Runner(config);
runner.setMaxListeners(100);

// ---------- 인증 (토큰) + 틀린 시도 막기 ----------
const fails = new Map(); // ip → {n, until}
function authed(req) {
  const h = req.headers.authorization || '';
  const got = Buffer.from(h.startsWith('Bearer ') ? h.slice(7) : '');
  const want = Buffer.from(config.token);
  return got.length === want.length && crypto.timingSafeEqual(got, want);
}
function blocked(ip) { const f = fails.get(ip); return f && f.until > Date.now(); }
function noteFail(ip) {
  const f = fails.get(ip) || { n: 0, until: 0 };
  f.n++;
  if (f.n >= 10) { f.until = Date.now() + 10 * 60 * 1000; f.n = 0; }
  fails.set(ip, f);
}

// ---------- 응답 도우미 ----------
const SEC_HEADERS = {
  'X-Content-Type-Options': 'nosniff',
  'Referrer-Policy': 'no-referrer',
  'Content-Security-Policy': "default-src 'self'; img-src 'self' data:; style-src 'self'; script-src 'self'; connect-src 'self'; frame-ancestors 'none'",
};
function send(req, res, status, body, type = 'application/json; charset=utf-8', extra = {}) {
  let data = Buffer.isBuffer(body) ? body : Buffer.from(typeof body === 'string' ? body : JSON.stringify(body));
  const headers = { 'Content-Type': type, 'Cache-Control': 'no-store', ...SEC_HEADERS, ...extra };
  if (data.length > 1024 && /\bgzip\b/.test(req.headers['accept-encoding'] || '')) {
    data = zlib.gzipSync(data);
    headers['Content-Encoding'] = 'gzip';
  }
  headers['Content-Length'] = data.length;
  res.writeHead(status, headers);
  res.end(data);
}
function readBody(req) {
  return new Promise((resolve, reject) => {
    let size = 0; const chunks = [];
    req.on('data', c => { size += c.length; if (size > 1 << 20) { reject(Object.assign(new Error('너무 큽니다'), { status: 413 })); req.destroy(); } else chunks.push(c); });
    req.on('end', () => { try { resolve(chunks.length ? JSON.parse(Buffer.concat(chunks).toString('utf8')) : {}); } catch { reject(Object.assign(new Error('JSON 이 아닙니다'), { status: 400 })); } });
    req.on('error', reject);
  });
}

const STATIC = {
  '/': ['index.html', 'text/html; charset=utf-8'],
  '/index.html': ['index.html', 'text/html; charset=utf-8'],
  '/app.js': ['app.js', 'text/javascript; charset=utf-8'],
  '/style.css': ['style.css', 'text/css; charset=utf-8'],
  '/manifest.json': ['manifest.json', 'application/manifest+json'],
  '/icon.svg': ['icon.svg', 'image/svg+xml'],
};

function agentOf(v) { return v === 'codex' ? 'codex' : v === 'claude' ? 'claude' : null; }

function projects() {
  const seen = new Map();
  for (const p of config.projects) if (p && fs.existsSync(p)) seen.set(p, 0);
  for (const s of store.list(300)) if (s.cwd && !seen.has(s.cwd)) seen.set(s.cwd, s.mtime);
  return [...seen.keys()].filter(p => { try { return fs.statSync(p).isDirectory(); } catch { return false; } })
    .map(p => ({ path: p, name: path.basename(p) || p }));
}

// 실시간: 기록 파일이 바뀌거나 답변이 흘러나오면 바로 휴대폰으로 (Server-Sent Events)
//   event: msgs  {full, epoch, total, from, items(바뀐 것만), title, cwd, active}
//   event: job   {running, live(쓰는 중인 답변), tool(실행 중인 도구), error, queued}
function stream(req, res, q) {
  const agent = agentOf(q.get('agent')); const id = q.get('id') || '';
  if (!agent || !ID_RE.test(id)) return send(req, res, 400, { error: '잘못된 요청' });
  const limit = Math.min(Number(q.get('limit')) || 300, 5000);
  res.writeHead(200, { 'Content-Type': 'text/event-stream; charset=utf-8', 'Cache-Control': 'no-store', 'X-Accel-Buffering': 'no', ...SEC_HEADERS });
  res.write('retry: 2000\n\n');
  const out = (ev, data) => res.write(`event: ${ev}\ndata: ${JSON.stringify(data)}\n\n`);
  let epoch = -1, rev = -1, from = -1, title = '', active = null, jobKey = '';
  const tickFile = () => {
    const m = store.messages(agent, id);
    if (!m) return;
    const f = Math.max(0, m.items.length - limit);
    const isActive = Date.now() - m.mtime < 20000;
    if (m.epoch === epoch && m.rev === rev && f === from && m.title === title && isActive === active) return;
    const full = m.epoch !== epoch || f !== from;
    const items = full ? m.items.slice(f) : m.items.filter(it => it.v > rev && it.n >= f);
    epoch = m.epoch; rev = m.rev; from = f; title = m.title; active = isActive;
    out('msgs', { full, epoch, total: m.items.length, from: f, items, title: m.title, cwd: m.cwd, active: isActive });
  };
  const tickJob = () => {
    const j = runner.job(agent, id);
    const k = JSON.stringify(j);
    if (k === jobKey) return;
    jobKey = k;
    out('job', j || { running: false });
  };
  tickFile(); tickJob();
  const onChange = key => { if (key === agent + ':' + id) { tickJob(); tickFile(); } };
  runner.on('change', onChange);
  const iv = setInterval(() => { try { tickFile(); tickJob(); } catch { /* 다음에 */ } }, 400);
  const hb = setInterval(() => res.write(': ping\n\n'), 15000);
  const close = () => { clearInterval(iv); clearInterval(hb); runner.off('change', onChange); };
  req.on('close', close);
  res.on('error', close);
}

async function api(req, res, url) {
  const q = url.searchParams;
  const p = url.pathname;
  if (p === '/api/sessions' && req.method === 'GET') {
    const list = store.list(Number(q.get('limit')) || 150).map(s => {
      const j = runner.job(s.agent, s.id);
      return { ...s, running: !!(j && j.running), active: Date.now() - s.mtime < 20000 };
    });
    return send(req, res, 200, { sessions: list });
  }
  if (p === '/api/messages' && req.method === 'GET') {
    const agent = agentOf(q.get('agent')); const id = q.get('id') || '';
    if (!agent || !ID_RE.test(id)) return send(req, res, 400, { error: '잘못된 요청' });
    const m = store.messages(agent, id);
    const job = runner.job(agent, id);
    if (!m) return send(req, res, job ? 200 : 404, job ? { items: [], epoch: 0, total: 0, from: 0, job, pending: true } : { error: '세션이 없습니다' });
    const limit = Math.min(Number(q.get('limit')) || 300, 5000);
    const from = Math.max(0, m.items.length - limit);
    const stamp = `${m.epoch}:${m.offset}:${m.items.length}:${from}:${JSON.stringify(job)}`;
    if (q.get('stamp') === stamp) return send(req, res, 200, { same: true, stamp });
    return send(req, res, 200, {
      stamp, epoch: m.epoch, total: m.items.length, from, items: m.items.slice(from),
      title: m.title, cwd: m.cwd, job, active: Date.now() - m.mtime < 20000,
    });
  }
  if (p === '/api/stream' && req.method === 'GET') return stream(req, res, q);
  if (p === '/api/projects' && req.method === 'GET') return send(req, res, 200, { projects: projects() });
  if (p === '/api/info' && req.method === 'GET') {
    return send(req, res, 200, { bins: runner.bins(), modes: { claude: CLAUDE_MODES.slice(0, 4), codex: CODEX_MODES }, host: os.hostname() });
  }
  if (req.method !== 'POST') return send(req, res, 404, { error: '없는 주소' });
  const body = await readBody(req);
  const agent = agentOf(body.agent);
  if (!agent) return send(req, res, 400, { error: '에이전트를 골라 주세요' });
  if (p === '/api/send') {
    const id = String(body.id || '');
    if (!ID_RE.test(id)) return send(req, res, 400, { error: '세션 id 가 이상합니다' });
    const m = store.messages(agent, id);
    const cwd = (m && m.cwd) || '';
    const r = await runner.start(agent, { id, cwd, prompt: body.prompt, mode: body.mode });
    return send(req, res, 200, r);
  }
  if (p === '/api/new') {
    const r = await runner.start(agent, { id: null, cwd: String(body.cwd || ''), prompt: body.prompt, mode: body.mode });
    return send(req, res, 200, r);
  }
  if (p === '/api/stop') {
    const id = String(body.id || '');
    return send(req, res, 200, { stopped: runner.stop(agent, id) });
  }
  return send(req, res, 404, { error: '없는 주소' });
}

const server = http.createServer(async (req, res) => {
  const ip = req.socket.remoteAddress || '';
  let url;
  try { url = new URL(req.url, 'http://x'); } catch { return send(req, res, 400, { error: '주소 오류' }); }
  try {
    if (!url.pathname.startsWith('/api/')) {
      const s = STATIC[url.pathname];
      if (!s || req.method !== 'GET') return send(req, res, 404, 'Not found', 'text/plain; charset=utf-8');
      return send(req, res, 200, fs.readFileSync(path.join(PUBLIC, s[0])), s[1], { 'Cache-Control': 'no-cache' });
    }
    if (blocked(ip)) return send(req, res, 429, { error: '잠시 후 다시 시도하세요' });
    if (!authed(req)) { noteFail(ip); return send(req, res, 401, { error: '토큰이 필요합니다' }); }
    fails.delete(ip);
    await api(req, res, url);
  } catch (e) {
    if (!res.headersSent) send(req, res, e.status || 500, { error: e.message || String(e) });
  }
});

function addresses() {
  const out = [];
  for (const list of Object.values(os.networkInterfaces())) {
    for (const a of list || []) if (a.family === 'IPv4' && !a.internal) out.push(a.address);
  }
  return out;
}

server.listen(config.port, config.host, () => {
  const bins = runner.bins();
  const hosts = config.host === '0.0.0.0' ? ['localhost', ...addresses()] : [config.host];
  console.log('Agent Chat 실행 중');
  console.log(`  설정 파일 : ${CONFIG_FILE}`);
  console.log(`  claude    : ${bins.claude || '(못 찾음 → config.json 의 claudeBin)'}`);
  console.log(`  codex     : ${bins.codex || '(못 찾음 → config.json 의 codexBin)'}`);
  console.log('  휴대폰에서 아래 주소 중 하나를 여세요 (토큰이 들어 있으니 남에게 보여 주지 마세요):');
  for (const h of hosts) console.log(`    http://${h}:${config.port}/#t=${config.token}`);
});

const bye = () => { runner.stopAll(); process.exit(0); };
process.on('SIGINT', bye);
process.on('SIGTERM', bye);
