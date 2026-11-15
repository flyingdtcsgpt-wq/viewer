'use strict';
// Antigravity IDE 의 에이전트 화면을 휴대폰으로.
//
// Antigravity IDE 는 백엔드(~/.gemini/bin/agy --hub --hub-port=<포트> …)를 띄우고, 그 "허브" 가
// http://127.0.0.1:<포트>/ 에서 에이전트 화면(대화 목록 · 대화 · 허락 물음 · 모델 고르기)을 웹으로 내보낸다.
// IDE 오른쪽의 에이전트 창은 그 웹 화면을 끼워 넣은 것이다. 허브는 이 PC(127.0.0.1)에서 온 요청만 받는다.
//
// 여기서는 그 화면을 Agent Chat 의 인증 뒤에서 그대로 전달한다 (역방향 프록시).
//   휴대폰 ──(Agent Chat 토큰으로 받은 1회용 표)──▶ 이 프록시 ──(Host 를 127.0.0.1 로)──▶ 허브
// 휴대폰에서 보낸 글은 IDE 가 쓰는 바로 그 백엔드로 들어가므로 IDE 에 열린 대화에 그대로 이어지고,
// 화면이 잠겨 있어도 된다. 대화 형식을 우리가 해석하지 않으므로 Antigravity 가 바뀌어도 덜 깨진다.
//
// 안전장치: 표(1분 · 한 번) → 쿠키(토큰에서 만든 값) 가 있어야 하고, 허브 목록에 있는 포트로만 전달한다.
const fs = require('fs');
const os = require('os');
const path = require('path');
const http = require('http');
const net = require('net');
const crypto = require('crypto');

function geminiHome() { return process.env.AGENT_CHAT_GEMINI_HOME || path.join(os.homedir(), '.gemini'); }

// 허브가 남긴 표지 파일들: <gemini>/antigravity…/daemon/hub_<포트>.json
function hubFiles() {
  const out = [];
  let dirs = [];
  try { dirs = fs.readdirSync(geminiHome()).filter(n => /^antigravity/i.test(n)); } catch { return out; }
  for (const d of dirs) {
    const dd = path.join(geminiHome(), d, 'daemon');
    let names = [];
    try { names = fs.readdirSync(dd); } catch { continue; }
    for (const n of names) {
      const m = n.match(/^hub_(\d{2,5})\.json$/);
      if (!m) continue;
      const file = path.join(dd, n);
      let mtime = 0, info = {};
      try { mtime = fs.statSync(file).mtimeMs; } catch { continue; }
      try { const j = JSON.parse(fs.readFileSync(file, 'utf8')); if (j && typeof j === 'object') info = j; } catch { /* 형식을 몰라도 포트는 안다 */ }
      out.push({ port: Number(m[1]), file, mtime, app: d, info });
    }
  }
  return out.sort((a, b) => b.mtime - a.mtime);
}

function probe(port, timeoutMs = 1500) {
  return new Promise(resolve => {
    const req = http.get({ host: '127.0.0.1', port, path: '/', headers: { Host: `127.0.0.1:${port}` }, timeout: timeoutMs }, res => { res.resume(); resolve(res.statusCode > 0 && res.statusCode < 500); });
    req.on('timeout', () => { req.destroy(); resolve(false); });
    req.on('error', () => resolve(false));
  });
}

// 표지 파일에서 사람이 알아볼 이름(작업 폴더)을 찾아본다. 형식이 문서에 없어 있을 법한 이름을 훑는다
function labelOf(h) {
  const i = h.info || {};
  const pick = v => (typeof v === 'string' && v ? v : Array.isArray(v) && typeof v[0] === 'string' ? v[0] : '');
  const raw = pick(i.workspace) || pick(i.workspaceUri) || pick(i.workspace_uri) || pick(i.workspaces) || pick(i.addDirs) || pick(i.add_dirs) || pick(i.cwd) || '';
  let p = raw;
  try { if (/^file:/.test(raw)) p = decodeURIComponent(new URL(raw).pathname); } catch { /* 그대로 */ }
  return p ? path.basename(p.replace(/[\\/]+$/, '')) || p : '';
}

/** 지금 켜져 있는 허브들 (최근 것 먼저) */
async function hubs() {
  const files = hubFiles();
  const ok = await Promise.all(files.map(f => probe(f.port)));
  return files.filter((f, i) => ok[i]).map(f => ({ port: f.port, app: f.app, label: labelOf(f), since: f.mtime }));
}

const COOKIE = 'ac_ag';
function parseCookies(h) {
  const o = {};
  for (const part of String(h || '').split(';')) { const i = part.indexOf('='); if (i > 0) o[part.slice(0, i).trim()] = part.slice(i + 1).trim(); }
  return o;
}

class HubProxy {
  /** token: Agent Chat 접속 토큰 (쿠키 값을 만드는 데만 쓴다. 쿠키에 토큰이 들어가지는 않는다) */
  constructor({ token, log } = {}) {
    this.key = crypto.createHmac('sha256', String(token)).update('agent-chat antigravity proxy').digest();
    this.tickets = new Map();
    this.server = null;
    this.port = 0;
    this.log = log || null;
  }
  sign(hubPort) { return crypto.createHmac('sha256', this.key).update(String(hubPort)).digest('hex'); }
  /** 1분 동안 한 번 쓸 수 있는 표 */
  ticket(hubPort) {
    const now = Date.now();
    for (const [k, v] of this.tickets) if (v.exp < now) this.tickets.delete(k);
    const k = crypto.randomBytes(24).toString('hex');
    this.tickets.set(k, { hubPort, exp: now + 60000 });
    return k;
  }
  /** 쿠키가 맞고, 그 포트가 지금도 허브 목록에 있으면 그 포트 */
  hubOf(req) {
    const v = parseCookies(req.headers.cookie)[COOKIE] || '';
    const i = v.indexOf('.');
    if (i < 1) return 0;
    const port = Number(v.slice(0, i)), sig = v.slice(i + 1), want = this.sign(port);
    if (!Number.isInteger(port) || sig.length !== want.length || !crypto.timingSafeEqual(Buffer.from(sig), Buffer.from(want))) return 0;
    return hubFiles().some(h => h.port === port) ? port : 0;
  }
  // 허브로 넘길 머리말: 허브는 Host 가 127.0.0.1 이 아니면 401 을 낸다
  headersFor(req, hubPort) {
    const origin = `http://127.0.0.1:${hubPort}`;
    const h = {};
    for (const [k, v] of Object.entries(req.headers)) {
      const key = k.toLowerCase();
      if (key === 'host') h[k] = `127.0.0.1:${hubPort}`;
      else if (key === 'origin') h[k] = origin;
      else if (key === 'referer') { try { const u = new URL(v); h[k] = origin + u.pathname + u.search; } catch { /* 뺀다 */ } }
      else if (key === 'cookie') { const rest = String(v).split(';').map(s => s.trim()).filter(s => s && !s.startsWith(COOKIE + '=')).join('; '); if (rest) h[k] = rest; }
      else if (/^(x-forwarded-|forwarded$|authorization$)/.test(key)) { /* Agent Chat 의 것은 넘기지 않는다 */ }
      else h[k] = v;
    }
    return h;
  }
  deny(res, status, text) {
    res.writeHead(status, { 'Content-Type': 'text/html; charset=utf-8', 'Cache-Control': 'no-store' });
    res.end(`<!doctype html><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"><body style="font-family:sans-serif;padding:24px"><h3>Agent Chat</h3><p>${text}</p>`);
  }
  handle(req, res) {
    let url;
    try { url = new URL(req.url, 'http://x'); } catch { return this.deny(res, 400, '주소 오류'); }
    if (url.pathname === '/__ac/login') {
      const t = this.tickets.get(url.searchParams.get('k') || '');
      if (!t || t.exp < Date.now()) return this.deny(res, 401, '연결 시간이 지났습니다. Agent Chat 앱에서 다시 여세요.');
      this.tickets.delete(url.searchParams.get('k'));
      res.writeHead(302, { 'Set-Cookie': `${COOKIE}=${t.hubPort}.${this.sign(t.hubPort)}; Path=/; HttpOnly; SameSite=Lax; Max-Age=43200`, Location: '/', 'Cache-Control': 'no-store' });
      return res.end();
    }
    const hubPort = this.hubOf(req);
    if (!hubPort) return this.deny(res, 401, 'Agent Chat 앱에서 Antigravity 를 다시 여세요. (PC 에서 Antigravity IDE 를 껐다 켰다면 주소가 바뀝니다)');
    const up = http.request({ host: '127.0.0.1', port: hubPort, method: req.method, path: req.url, headers: this.headersFor(req, hubPort) }, r => {
      if (this.log) this.log(`${req.method} ${url.pathname} -> ${r.statusCode}`);
      const h = { ...r.headers };
      if (h.location) { try { const u = new URL(h.location, `http://127.0.0.1:${hubPort}`); if (u.hostname === '127.0.0.1' || u.hostname === 'localhost') h.location = u.pathname + u.search + u.hash; } catch { /* 그대로 */ } }
      res.writeHead(r.statusCode, h);
      r.pipe(res);
    });
    up.on('error', e => { if (!res.headersSent) this.deny(res, 502, 'PC 의 Antigravity 에 연결하지 못했습니다: ' + (e.code || e.message)); else res.destroy(); });
    res.on('close', () => up.destroy());
    req.pipe(up);
  }
  upgrade(req, sock, head) {
    const hubPort = this.hubOf(req);
    if (!hubPort) { sock.end('HTTP/1.1 401 Unauthorized\r\nConnection: close\r\n\r\n'); return; }
    const up = net.connect(hubPort, '127.0.0.1', () => {
      const h = this.headersFor(req, hubPort);
      up.write(`${req.method} ${req.url} HTTP/1.1\r\n` + Object.entries(h).map(([k, v]) => (Array.isArray(v) ? v : [v]).map(x => `${k}: ${x}\r\n`).join('')).join('') + '\r\n');
      if (head && head.length) up.write(head);
      sock.pipe(up); up.pipe(sock);
    });
    const end = () => { up.destroy(); sock.destroy(); };
    up.on('error', end); sock.on('error', end); up.on('close', end); sock.on('close', end);
  }
  /** 처음 쓸 때 연다. 반환: 실제 포트 */
  listen(port, host) {
    if (this.server) return Promise.resolve(this.port);
    return new Promise((resolve, reject) => {
      const s = http.createServer((req, res) => { try { this.handle(req, res); } catch (e) { try { this.deny(res, 500, '오류'); } catch { /* 이미 보냄 */ } } });
      s.on('upgrade', (req, sock, head) => { try { this.upgrade(req, sock, head); } catch { sock.destroy(); } });
      s.on('error', e => { if (!this.server) reject(e); });
      s.listen(port, host, () => { this.server = s; this.port = s.address().port; resolve(this.port); });
    });
  }
  close() { if (this.server) { try { this.server.closeAllConnections && this.server.closeAllConnections(); } catch { /* 옛 Node */ } this.server.close(); this.server = null; } }
}

module.exports = { hubs, hubFiles, probe, labelOf, HubProxy, geminiHome, COOKIE };
