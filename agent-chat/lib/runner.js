'use strict';
// 휴대폰에서 보낸 말을 PC 의 claude / codex 프로그램으로 같은 세션에 이어서 보낸다.
//   Claude : claude -p --resume <id> --permission-mode <모드> --output-format stream-json --include-partial-messages
//            → 답변이 글자 단위로 흘러나오는 것을 그대로 휴대폰에 보여 준다(실시간)
//   Codex  : codex exec resume <id> -  (-c sandbox_mode=<모드>) --json → 지금 실행 중인 명령을 실시간으로
// 말은 표준입력으로 넘긴다. 프로그램은 설정 → PATH → 흔한 설치 위치 → VS Code 확장 폴더 순서로 찾는다.
const fs = require('fs');
const path = require('path');
const os = require('os');
const crypto = require('crypto');
const { EventEmitter } = require('events');
const { spawn } = require('child_process');
const peer = require('./peer');
const codexPeer = require('./codexPeer');
const sleep = ms => new Promise(r => setTimeout(r, ms));

const isWin = process.platform === 'win32';
const ID_RE = /^[0-9A-Za-z][0-9A-Za-z-]{6,63}$/;
const CLAUDE_MODES = ['acceptEdits', 'auto', 'bypassPermissions', 'plan', 'default', 'manual', 'dontAsk'];
const CODEX_MODES = ['workspace-write', 'read-only', 'danger-full-access'];
// 보낼 때 고르는 모델 · 추론 강도 · 생각(thinking)
const CLAUDE_MODELS = ['fable', 'opus', 'sonnet', 'haiku'];
const CLAUDE_EFFORTS = ['low', 'medium', 'high', 'xhigh', 'max'];
const CODEX_EFFORTS = ['minimal', 'low', 'medium', 'high', 'xhigh', 'max', 'ultra'];
const MODEL_RE = /^[A-Za-z0-9][A-Za-z0-9._:\-\[\]]{0,79}$/;

/** 화면에서 온 값을 검사해서 쓸 수 있는 것만 남긴다 */
function cleanOpts(agent, o) {
  o = o && typeof o === 'object' ? o : {};
  const out = {};
  if (typeof o.model === 'string' && MODEL_RE.test(o.model.trim())) out.model = o.model.trim();
  // Codex 는 모델마다 새 강도가 생길 수 있어(목록은 Codex 가 알려 줌) 모양만 본다
  if (agent === 'claude' ? CLAUDE_EFFORTS.includes(o.effort) : typeof o.effort === 'string' && /^[a-z][a-z0-9-]{1,15}$/.test(o.effort)) out.effort = o.effort;
  if (agent === 'claude' && (o.thinking === 'on' || o.thinking === 'off')) out.thinking = o.thinking;
  return out;
}

function isFile(p) { try { return fs.statSync(p).isFile(); } catch { return false; } }

function findOnPath(name) {
  const dirs = (process.env.PATH || '').split(path.delimiter).filter(Boolean);
  const exts = isWin ? ['.exe', '.cmd', '.bat'] : [''];
  for (const d of dirs) {
    for (const x of exts) {
      const p = path.join(d.replace(/^"|"$/g, ''), name + x);
      if (isFile(p)) return p;
    }
  }
  return null;
}

// npm 으로 깐 claude.cmd / codex.cmd 는 cmd.exe 를 거치지 않도록 안의 .js 를 node 로 바로 실행한다.
const NPM_ENTRY = {
  claude: [['@anthropic-ai', 'claude-code', 'cli.js']],
  codex: [['@openai', 'codex', 'bin', 'codex.js']],
};
function npmShimTarget(agent, shim) {
  if (!/\.(cmd|bat|ps1)$/i.test(shim) && !/[\\/]npm[\\/]/i.test(shim)) return null;
  for (const parts of NPM_ENTRY[agent]) {
    const p = path.join(path.dirname(shim), 'node_modules', ...parts);
    if (isFile(p)) return p;
  }
  return null;
}

function commonLocations(agent) {
  const h = os.homedir();
  const appData = process.env.APPDATA || path.join(h, 'AppData', 'Roaming');
  const local = process.env.LOCALAPPDATA || path.join(h, 'AppData', 'Local');
  if (isWin) {
    return agent === 'claude'
      ? [path.join(h, '.local', 'bin', 'claude.exe'), path.join(appData, 'npm', 'claude.cmd'), path.join(local, 'Programs', 'claude', 'claude.exe')]
      : [path.join(appData, 'npm', 'codex.cmd'), path.join(h, '.local', 'bin', 'codex.exe')];
  }
  return agent === 'claude'
    ? [path.join(h, '.local', 'bin', 'claude'), path.join(h, '.claude', 'local', 'claude'), '/opt/homebrew/bin/claude', '/usr/local/bin/claude']
    : [path.join(h, '.local', 'bin', 'codex'), '/opt/homebrew/bin/codex', '/usr/local/bin/codex'];
}

function extensionDirs() {
  const h = os.homedir();
  return ['.vscode', '.vscode-insiders', '.cursor', '.windsurf', '.vscode-server', '.vscode-oss']
    .map(d => path.join(h, d, 'extensions'));
}

// VS Code 확장 폴더(가장 최근 버전부터)에서 실행 파일을 찾는다.
function findInExtensions(prefix, names) {
  const hits = [];
  for (const root of extensionDirs()) {
    let ents = [];
    try { ents = fs.readdirSync(root, { withFileTypes: true }); } catch { continue; }
    for (const e of ents) {
      if (!e.isDirectory() || !e.name.toLowerCase().startsWith(prefix)) continue;
      const dir = path.join(root, e.name);
      let mt = 0;
      try { mt = fs.statSync(dir).mtimeMs; } catch { /* 없음 */ }
      hits.push({ dir, mt });
    }
  }
  hits.sort((a, b) => b.mt - a.mt);
  for (const name of names) {
    for (const h of hits) {
      const found = walkFind(h.dir, name, 0);
      if (found) return found;
    }
  }
  return null;
}

function walkFind(dir, name, depth) {
  let ents = [];
  try { ents = fs.readdirSync(dir, { withFileTypes: true }); } catch { return null; }
  for (const e of ents) if (e.isFile() && e.name === name) return path.join(dir, e.name);
  if (depth >= 5) return null;
  for (const e of ents) {
    if (e.isDirectory() && e.name !== 'node_modules' && !e.name.startsWith('.')) {
      const f = walkFind(path.join(dir, e.name), name, depth + 1);
      if (f) return f;
    }
  }
  return null;
}

function resolveBin(agent, config) {
  const own = agent === 'claude' ? config.claudeBin : config.codexBin;
  let bin = own && isFile(own) ? own : null;
  if (!bin) bin = findOnPath(agent) || commonLocations(agent).find(isFile) || null;
  if (!bin) {
    bin = agent === 'claude'
      ? findInExtensions('anthropic.claude-code', isWin ? ['claude.exe', 'cli.js'] : ['claude', 'cli.js'])
      : findInExtensions('openai.chatgpt', isWin ? ['codex.exe'] : ['codex']);
  }
  if (!bin) return null;
  return npmShimTarget(agent, bin) || bin;
}

function buildArgs(agent, { id, isNew, mode, opts = {} }, config) {
  if (agent === 'claude') {
    const a = ['-p', '--permission-mode', mode, '--output-format', 'stream-json', '--verbose', '--include-partial-messages'];
    a.push(isNew ? '--session-id' : '--resume', id);
    if (opts.model) a.push('--model', opts.model);
    if (opts.effort) a.push('--effort', opts.effort);
    if (opts.thinking === 'on' && config.thinkingOnFile) a.push('--settings', config.thinkingOnFile);
    return a.concat(config.claudeArgs || []);
  }
  const extra = [];
  if (opts.model) extra.push('-m', opts.model);
  if (opts.effort) extra.push('-c', `model_reasoning_effort=${opts.effort}`);
  if (isNew) return ['exec', '--json', '--skip-git-repo-check', '-s', mode, ...extra, ...(config.codexArgs || []), '-'];
  return ['exec', 'resume', '--json', '--skip-git-repo-check', '-c', `sandbox_mode=${mode}`, ...extra, ...(config.codexArgs || []), id, '-'];
}

/** 생각 끄기는 환경변수로 */
function envFor(agent, env, opts = {}) {
  if (agent !== 'claude' || !opts.thinking) return env;
  const e = { ...(env || process.env) };
  if (opts.thinking === 'off') e.CLAUDE_CODE_DISABLE_THINKING = '1';
  else delete e.CLAUDE_CODE_DISABLE_THINKING;
  return e;
}

function quoteWin(a) { return /^[\w.:=/\\-]+$/.test(a) ? a : '"' + String(a).replace(/"/g, '') + '"'; }

function launch(bin, args, cwd, env) {
  let cmd = bin, argv = args, shell = false;
  if (/\.(c|m)?js$/i.test(bin)) { cmd = process.execPath; argv = [bin, ...args]; }
  else if (isWin && /\.(cmd|bat)$/i.test(bin)) { shell = true; cmd = quoteWin(bin); argv = args.map(quoteWin); }
  return spawn(cmd, argv, {
    cwd, env: env || process.env, shell, windowsHide: true, detached: !isWin, stdio: ['pipe', 'pipe', 'pipe'],
  });
}

// Windows 의 cmd 오류 문구는 CP949 로 나오는 일이 있어 UTF-8 이 아니면 한국어 코드페이지로 읽는다.
function decode(buf) {
  try { return new TextDecoder('utf-8', { fatal: true }).decode(buf); } catch { /* 아래 */ }
  try { return new TextDecoder('euc-kr').decode(buf); } catch { return buf.toString('latin1'); }
}
function tailBuf(b, add, max = 8000) { const n = Buffer.concat([b, add]); return n.length > max ? n.subarray(n.length - max) : n; }

class Runner extends EventEmitter {
  constructor(config) {
    super();
    this.config = config;
    this.jobs = new Map(); // "agent:id" → job (한 번의 주고받기)
    this.lives = new Map(); // "claude:id" → 계속 켜 두는 claude 프로세스
  }
  bins() { return { claude: resolveBin('claude', this.config), codex: resolveBin('codex', this.config) }; }
  job(agent, id) {
    const j = this.jobs.get(agent + ':' + id);
    if (!j) return null;
    if (j.done && Date.now() - j.endedAt > 30 * 60 * 1000) { this.jobs.delete(agent + ':' + id); return null; }
    return {
      running: !j.done, startedAt: j.startedAt, endedAt: j.endedAt || 0, error: j.error || '', stopped: !!j.stopped,
      live: j.done ? '' : j.live.text, tool: j.done ? '' : j.live.tool, queued: j.queue.length, v: j.v,
      // 이 대화의 claude 프로세스가 켜져 있으면 그 번호 (메시지마다 새로 뜨지 않는다는 표시)
      pid: (this.lives.get(agent + ':' + id) || {}).pid || 0,
      relayed: !!j.relay, relayPid: j.relayPid || 0, relayWaiting: !j.done && !!j.relayWaiting,
    };
  }
  /** Agent Chat 이 직접 띄워 둔 claude 프로세스들의 pid (VS Code 세션으로 착각하지 않게) */
  ownPids() { return new Set([...this.lives.values()].map(L => L.pid).filter(Boolean)); }
  running(agent, id) { const j = this.jobs.get(agent + ':' + id); return !!(j && !j.done); }
  changed(job) { job.v++; if (job.id) this.emit('change', job.agent + ':' + job.id); }

  // 반환: Promise<{id, queued?}>  (새 Codex 세션은 id 가 정해질 때까지 기다린다)
  start(agent, { id, cwd, prompt, mode, env, opts }) {
    opts = cleanOpts(agent, opts);
    if (agent !== 'claude' && agent !== 'codex') throw httpError(400, '알 수 없는 에이전트');
    const modes = agent === 'claude' ? CLAUDE_MODES : CODEX_MODES;
    if (!modes.includes(mode)) mode = modes[0];
    if (typeof prompt !== 'string' || !prompt.trim()) throw httpError(400, '보낼 내용이 없습니다');
    if (!cwd || !fs.existsSync(cwd) || !fs.statSync(cwd).isDirectory()) throw httpError(400, `작업 폴더가 없습니다: ${cwd || '(없음)'}`);
    const isNew = !id;
    if (!isNew && !ID_RE.test(id)) throw httpError(400, '세션 id 가 이상합니다');
    // 작업 중에 또 보내면 PC 처럼 줄 세워 두었다가 끝나면 이어서 보낸다
    const busy = !isNew && this.jobs.get(agent + ':' + id);
    // Codex 를 VS Code 줄로 넘기는 중이면 이것도 Codex 의 줄로 (순서는 Codex 가 지킨다)
    const codexRelay = agent === 'codex' && busy && busy.relay && this.config.relayToLive !== false;
    if (busy && !busy.done && !codexRelay) {
      if (busy.queue.length >= 5) throw httpError(429, '대기 중인 메시지가 너무 많습니다');
      busy.queue.push({ prompt, mode, opts });
      this.changed(busy);
      return Promise.resolve({ id, queued: busy.queue.length });
    }
    const bin = resolveBin(agent, this.config);
    if (!bin) throw httpError(500, `${agent} 프로그램을 찾지 못했습니다. config.json 의 ${agent}Bin 에 경로를 적어 주세요`);
    if (isNew && agent === 'claude') id = crypto.randomUUID();
    if (agent === 'claude' && !isNew && this.config.relayToLive !== false) {
      // VS Code(또는 터미널)에 이 대화가 열려 있으면 그 Claude 에게 넣는다. 새 Claude 를 띄우지 않는다.
      const live = peer.findLive(id, this.ownPids());
      if (live) return this.relay(live, { id, cwd, prompt });
    }
    if (agent === 'codex' && !isNew && this.config.relayToLive !== false) {
      // VS Code 의 Codex 가 이 대화를 열어 두었으면 Codex 의 정식 "줄" 에 넣어 그쪽이 처리하게 한다
      return this.relayCodex(bin, { id, cwd, prompt, mode, env, opts });
    }
    if (agent === 'claude' && this.config.claudeLive !== false) return this.claudeTurn(bin, { id, isNew, cwd, prompt, mode, env, opts, queue: [] });
    return this.run(agent, bin, { id, isNew, cwd, prompt, mode, env, opts, queue: [] });
  }

  // ---------- Claude: VS Code 에 열려 있는 세션으로 넣기 ----------
  async relay(live, { id, cwd, prompt }) {
    const key = 'claude:' + id;
    const L = this.lives.get(key);
    if (L && !L.dead) this.endLive(L); // 우리가 띄워 둔 것이 있으면 닫는다 (둘이 같은 대화에 쓰지 않게)
    const job = {
      agent: 'claude', id, cwd, relay: true, startedAt: Date.now(), done: false, live: { text: '', tool: '' }, v: 0, queue: [], relayPid: live.pid,
    };
    this.jobs.set(key, job);
    this.changed(job);
    try {
      await peer.send(live, prompt);
    } catch (e) {
      job.error = e.message;
    }
    job.done = true; job.endedAt = Date.now();
    this.changed(job);
    if (job.error) throw httpError(502, job.error);
    return { id, relayed: true, pid: live.pid };
  }

  // ---------- Codex: VS Code 에 열려 있는 대화의 줄에 넣기 ----------
  // 1) 줄에 넣고 몇 초 안에 누가 가져가면 → VS Code 의 Codex 가 처리 중
  // 2) 안 가져갔는데 대화가 지금 바쁘면(기록이 최근에 바뀜) → 그쪽 일이 끝날 때까지 줄에서 기다림
  // 3) 안 가져갔고 조용하면 → 아무 데도 안 열려 있음: 줄에서 빼고(두 번 실행 방지) 예전처럼 따로 실행
  // mustWait: 따로 실행했다가 "다른 Codex 가 이 대화를 쓰는 중" 으로 막힌 메시지 → 가져갈 때까지 줄에서 기다린다
  async relayCodex(bin, { id, cwd, prompt, mode, env, opts, mustWait }) {
    const key = 'codex:' + id;
    const job = {
      agent: 'codex', id, cwd, bin, env, relay: true, startedAt: Date.now(), done: false, live: { text: '', tool: '' }, v: 0, queue: [],
      relayWaiting: false,
    };
    this.jobs.set(key, job);
    this.changed(job);
    const fallback = () => { if (this.jobs.get(key) === job) this.jobs.delete(key); return this.run('codex', bin, { id, isNew: false, cwd, prompt, mode, env, opts, queue: [] }); };
    // VS Code 의 Codex 가 이 대화를 열어 두었으면(잠금 파일) 따로 실행하면 안 된다 → 줄에서 기다린다
    const locked = () => codexPeer.writerLocked(id);
    let s;
    const cantQueue = why => {
      if (!locked()) return fallback();
      if (this.jobs.get(key) === job) this.jobs.delete(key);
      throw httpError(409, `VS Code 의 Codex 가 이 대화를 열어 두어 따로 실행할 수 없고, 그쪽 줄에 넣지도 못했습니다 (${why}). VS Code 의 Codex 창에서 보내 주세요`);
    };
    try { s = await codexPeer.open(launch, bin, cwd, envFor('codex', env, opts)); } catch (e) { return cantQueue(e.message); }
    let qid;
    try { qid = (await codexPeer.add(s, id, prompt)).id; } catch (e) { s.close(); return cantQueue(e.message); }
    if (!qid) { s.close(); return cantQueue('줄 번호 없음'); }
    const gone = async () => { try { return !(await codexPeer.list(s, id)).some(x => x.id === qid); } catch { return false; } };
    const settle = (extra = {}) => { Object.assign(job, extra); job.done = true; job.endedAt = Date.now(); this.changed(job); s.close(); };
    const waitMs = this.config.codexPickupMs || 4000;
    for (let t = 0; t < waitMs; t += 500) {
      await sleep(500);
      if (await gone()) { settle(); return { id, relayed: true }; }
    }
    const active = () => !!mustWait || locked() || (this.activeCheck ? this.activeCheck('codex', id) : false);
    if (active()) {
      // VS Code 쪽이 일하는 중 → 끝나면 가져간다. 그동안 상태를 "대기" 로 둔다
      job.relayWaiting = true;
      this.changed(job);
      this.waitCodexPickup(s, job, { id, qid, gone, active, settle, fallback });
      return { id, relayed: true, waiting: true };
    }
    let removed = true;
    try { removed = !!(await codexPeer.remove(s, id, qid)); } catch { /* 이미 가져갔을 수도 */ }
    s.close();
    if (!removed) { settle(); return { id, relayed: true }; }
    return fallback();
  }

  waitCodexPickup(s, job, { id, qid, gone, active, settle, fallback }) {
    let quietSince = 0;
    const started = Date.now();
    const tick = async () => {
      if (job.done) return;
      if (job.stopped) { try { await codexPeer.remove(s, id, qid); } catch { /* 이미 */ } settle(); return; }
      if (await gone()) { settle(); return; }
      if (active()) quietSince = 0;
      else if (!quietSince) quietSince = Date.now();
      // VS Code 가 대화를 연 채(잠금 파일)면 그쪽 일이 아무리 길어도 기다린다.
      // 잠금이 없고 90초 넘게 조용한데도 안 가져가면 열려 있는 곳이 없는 것 → 빼고 따로 실행
      const quietLong = quietSince && Date.now() - quietSince > (this.config.codexQuietMs || 90000) && !locked();
      if (quietLong || Date.now() - started > 6 * 3600 * 1000) {
        try { await codexPeer.remove(s, id, qid); } catch { /* 이미 */ }
        settle({ relayWaiting: false });
        try { await fallback(); } catch (e) { job.error = e.message; this.changed(job); }
        return;
      }
      job.waitTimer = setTimeout(tick, 3000);
    };
    job.waitTimer = setTimeout(tick, 3000);
  }

  // ---------- Claude: 대화마다 프로세스 하나를 켜 두고 메시지를 이어서 넣는다 ----------
  // claude -p --input-format stream-json … 은 표준입력이 열려 있는 동안 계속 살아 있어서,
  // 백그라운드 작업 · 기억이 메시지 사이에 이어진다. 30분 동안 조용하면 닫는다.
  // 권한 · 모델 · 추론 · 생각 · 구독/API 를 바꾸면 그 다음 메시지부터 새로 띄운다(대화 내용은 그대로 이어짐).
  claudeTurn(bin, { id, isNew, cwd, prompt, mode, env, opts, queue }) {
    const key = 'claude:' + id;
    const e = envFor('claude', env, opts);
    const sig = JSON.stringify([mode, opts, cwd, !!(e && e.ANTHROPIC_API_KEY), (e && e.ANTHROPIC_API_KEY) || '', !!(e && e.CLAUDE_CODE_DISABLE_THINKING)]);
    let L = this.lives.get(key);
    if (L && (L.sig !== sig || L.dead)) { this.endLive(L); L = null; }
    if (!L) L = this.spawnLive(bin, { id, isNew, cwd, mode, opts, env: e, sig });
    const job = {
      agent: 'claude', id, cwd, bin, env, mode, opts, child: L.child, L, startedAt: Date.now(), out: Buffer.alloc(0), err: Buffer.alloc(0), done: false,
      live: { text: '', tool: '' }, v: 0, queue, lastEmit: 0, emitTimer: null,
    };
    this.jobs.set(key, job);
    L.job = job;
    if (L.idle) { clearTimeout(L.idle); L.idle = null; }
    try {
      L.child.stdin.write(JSON.stringify({ type: 'user', message: { role: 'user', content: prompt } }) + '\n');
    } catch (err) { this.finishTurn(job, { is_error: true, result: '보내지 못했습니다: ' + err.message }); }
    this.changed(job);
    return Promise.resolve({ id });
  }

  spawnLive(bin, { id, isNew, cwd, mode, opts, env, sig }) {
    const args = ['-p', '--input-format', 'stream-json', ...buildArgs('claude', { id, isNew, mode, opts }, this.config).slice(1)];
    const child = launch(bin, args, cwd, env);
    const L = { key: 'claude:' + id, child, pid: child.pid, sig, dead: false, job: null, idle: null, err: Buffer.alloc(0) };
    this.lives.set(L.key, L);
    let pending = Buffer.alloc(0);
    child.stdout.on('data', d => {
      if (L.job) L.job.out = tailBuf(L.job.out, d);
      pending = pending.length ? Buffer.concat([pending, d]) : d;
      let i;
      while ((i = pending.indexOf(10)) !== -1) {
        const line = pending.subarray(0, i).toString('utf8'); pending = pending.subarray(i + 1);
        let ev; try { ev = JSON.parse(line); } catch { continue; }
        if (ev && typeof ev === 'object') this.liveEvent(L, ev);
      }
    });
    child.stderr.on('data', d => { L.err = tailBuf(L.err, d); if (L.job) L.job.err = tailBuf(L.job.err, d); });
    child.stdin.on('error', () => { /* 이미 끝난 경우 */ });
    const gone = code => {
      if (L.dead) return;
      L.dead = true;
      if (L.idle) clearTimeout(L.idle);
      if (this.lives.get(L.key) === L) this.lives.delete(L.key);
      const job = L.job;
      if (job && !job.done) {
        const txt = (decode(L.err).trim() || nonJson(decode(job.out)).trim());
        this.finishTurn(job, { is_error: !job.stopped, result: txt.split('\n').slice(-8).join('\n') || `종료 코드 ${code}` });
      }
    };
    child.on('error', err => { L.err = tailBuf(L.err, Buffer.from('실행 실패: ' + err.message)); gone(-1); });
    child.on('close', gone);
    return L;
  }

  liveEvent(L, ev) {
    const job = L.job;
    if (ev.type === 'rate_limit_event' && ev.rate_limit_info) { this.emit('usage', 'claude', ev.rate_limit_info); return; }
    if (!job || job.done) return;
    const soon = () => {
      const now = Date.now();
      if (now - job.lastEmit > 120) { job.lastEmit = now; this.changed(job); return; }
      if (!job.emitTimer) job.emitTimer = setTimeout(() => { job.emitTimer = null; job.lastEmit = Date.now(); this.changed(job); }, 120);
    };
    if (ev.type === 'stream_event' && ev.event) {
      const e = ev.event;
      if (e.type === 'message_start') { job.live.text = ''; soon(); }
      else if (e.type === 'content_block_start' && e.content_block && e.content_block.type === 'tool_use') { job.live.tool = e.content_block.name || 'tool'; soon(); }
      else if (e.type === 'content_block_delta' && e.delta && e.delta.type === 'text_delta') { job.live.text += e.delta.text || ''; soon(); }
    } else if (ev.type === 'assistant') { job.live.text = ''; soon(); }
    else if (ev.type === 'user') { job.live.tool = ''; soon(); }
    else if (ev.type === 'result') this.finishTurn(job, ev);
  }

  finishTurn(job, ev) {
    if (job.done) return;
    if (job.emitTimer) clearTimeout(job.emitTimer);
    if (job.stopTimer) clearTimeout(job.stopTimer);
    job.done = true; job.endedAt = Date.now();
    if (ev && ev.is_error && !job.stopped) job.error = String(ev.result || ev.subtype || '오류');
    this.changed(job);
    const L = job.L;
    if (job.queue.length && !job.stopped && !job.error) {
      const next = job.queue.shift();
      try { this.claudeTurn(job.bin, { id: job.id, isNew: false, cwd: job.cwd, prompt: next.prompt, mode: next.mode, opts: next.opts, env: job.env, queue: job.queue }); } catch (e) { job.error = e.message; }
      return;
    }
    if (L && !L.dead) L.idle = setTimeout(() => this.endLive(L), this.config.claudeIdleMs || 30 * 60 * 1000);
  }

  /** 켜 둔 claude 를 닫는다 (표준입력을 닫으면 스스로 끝난다, force 면 바로 끈다) */
  endLive(L, force) {
    if (!L || L.dead) return;
    if (this.lives.get(L.key) === L) this.lives.delete(L.key);
    if (L.idle) clearTimeout(L.idle);
    try { L.child.stdin.end(); } catch { /* 이미 닫힘 */ }
    if (force) this.kill({ child: L.child });
    else setTimeout(() => { if (!L.dead) this.kill({ child: L.child }); }, 10000);
  }

  run(agent, bin, { id, isNew, cwd, prompt, mode, env, opts, queue }) {
    const child = launch(bin, buildArgs(agent, { id, isNew, mode, opts }, this.config), cwd, envFor(agent, env, opts));
    const job = {
      agent, id, cwd, bin, env, child, startedAt: Date.now(), out: Buffer.alloc(0), err: Buffer.alloc(0), done: false,
      live: { text: '', tool: '' }, v: 0, queue, prompt, mode, opts, isNew,
    };
    if (id) this.jobs.set(agent + ':' + id, job);

    let resolveId;
    const idReady = new Promise((res, rej) => { resolveId = res; job.reject = rej; });
    if (id) resolveId({ id });

    let pending = Buffer.alloc(0);
    let lastEmit = 0, emitTimer = null;
    const soon = () => { // 글자마다 보내지 않고 0.12초에 한 번씩 묶어서
      const now = Date.now();
      if (now - lastEmit > 120) { lastEmit = now; this.changed(job); return; }
      if (!emitTimer) emitTimer = setTimeout(() => { emitTimer = null; lastEmit = Date.now(); this.changed(job); }, 120);
    };
    const onEvent = ev => {
      if (agent === 'claude') {
        if (ev.type === 'stream_event' && ev.event) {
          const e = ev.event;
          if (e.type === 'message_start') { job.live.text = ''; soon(); }
          else if (e.type === 'content_block_start' && e.content_block && e.content_block.type === 'tool_use') { job.live.tool = e.content_block.name || 'tool'; soon(); }
          else if (e.type === 'content_block_delta' && e.delta && e.delta.type === 'text_delta') { job.live.text += e.delta.text || ''; soon(); }
        } else if (ev.type === 'assistant') { job.live.text = ''; soon(); }
        else if (ev.type === 'user') { job.live.tool = ''; soon(); }
        else if (ev.type === 'result' && ev.is_error) job.error = String(ev.result || ev.subtype || '오류');
        else if (ev.type === 'rate_limit_event' && ev.rate_limit_info) this.emit('usage', 'claude', ev.rate_limit_info);
        return;
      }
      if (ev.type === 'thread.started' && ev.thread_id && !job.id) {
        job.id = String(ev.thread_id).toLowerCase();
        this.jobs.set('codex:' + job.id, job);
        resolveId({ id: job.id });
      } else if (ev.type === 'item.started' && ev.item && ev.item.type === 'command_execution') { job.live.tool = String(ev.item.command || 'shell'); soon(); }
      else if (ev.type === 'item.completed' && ev.item && ev.item.type === 'command_execution') { job.live.tool = ''; soon(); }
      else if (ev.type === 'turn.failed' && ev.error) job.error = ev.error.message || String(ev.error);
      else if (ev.type === 'error' && ev.message && !/^Reconnecting/.test(ev.message)) job.error = ev.message;
    };
    child.stdout.on('data', d => {
      job.out = tailBuf(job.out, d);
      pending = pending.length ? Buffer.concat([pending, d]) : d;
      let i;
      while ((i = pending.indexOf(10)) !== -1) {
        const line = pending.subarray(0, i).toString('utf8'); pending = pending.subarray(i + 1);
        let ev; try { ev = JSON.parse(line); } catch { continue; }
        if (ev && typeof ev === 'object') onEvent(ev);
      }
    });
    child.stderr.on('data', d => { job.err = tailBuf(job.err, d); });
    child.on('error', e => { job.error = `실행 실패: ${e.message}`; finish(-1); });
    child.on('close', code => finish(code));
    const finish = code => {
      if (job.done) return;
      if (emitTimer) clearTimeout(emitTimer);
      job.done = true; job.endedAt = Date.now(); job.code = code;
      if (code !== 0 && !job.stopped && !job.error) {
        const txt = (decode(job.err).trim() || nonJson(decode(job.out)).trim());
        // 다른 Codex(VS Code 확장, 또는 Claude 가 돌린 codex)가 이 대화를 쓰는 중 → 오류로 끝내지 말고 그쪽 줄에 넣어 기다린다
        if (agent === 'codex' && job.id && !job.isNew && /already has an active writer/i.test(txt) && this.config.relayToLive !== false) {
          job.requeued = true; job.endedAt = Date.now();
          const rest = job.queue.splice(0);
          this.relayCodex(job.bin, { id: job.id, cwd: job.cwd, prompt: job.prompt, mode: job.mode, env: job.env, opts: job.opts, mustWait: true })
            .then(() => { for (const n of rest) this.relayCodex(job.bin, { id: job.id, cwd: job.cwd, prompt: n.prompt, mode: n.mode, env: job.env, opts: n.opts, mustWait: true }).catch(() => {}); })
            .catch(e => { job.error = e.message; this.changed(job); });
          return;
        }
        job.error = txt.split('\n').slice(-8).join('\n') || `종료 코드 ${code}`;
      }
      if (!job.id) { job.reject(httpError(500, job.error || 'Codex 세션을 시작하지 못했습니다')); return; }
      this.changed(job);
      // 줄 서 있던 메시지를 이어서 (멈춤 · 오류면 버린다). Codex 는 VS Code 가 그새 열었을 수 있으니 줄 넘기기부터
      if (job.queue.length && !job.stopped && !job.error) {
        const next = job.queue.shift();
        const a = { id: job.id, isNew: false, cwd: job.cwd, prompt: next.prompt, mode: next.mode, opts: next.opts, env: job.env, queue: job.queue };
        try {
          if (agent === 'codex' && this.config.relayToLive !== false) {
            const rest = job.queue.splice(0);
            this.relayCodex(job.bin, a).then(() => { for (const n of rest) this.start('codex', { id: job.id, cwd: job.cwd, prompt: n.prompt, mode: n.mode, env: job.env, opts: n.opts }); }).catch(e => { job.error = e.message; this.changed(job); });
          } else this.run(agent, job.bin, a);
        } catch (e) { job.error = e.message; }
      }
    };

    child.stdin.on('error', () => { /* 바로 끝난 경우 */ });
    child.stdin.end(prompt);

    if (!id) setTimeout(() => { if (!job.id) { this.kill(job); job.reject(httpError(504, 'Codex 가 세션을 시작하지 않습니다')); } }, 60000);
    return idReady;
  }
  stop(agent, id) {
    const j = this.jobs.get(agent + ':' + id);
    if (!j || j.done) return false;
    j.stopped = true;
    j.queue.length = 0;
    if (j.relay) return true; // 줄에서 기다리는 Codex 메시지는 다음 확인 때 줄에서 뺀다
    if (j.L && !j.L.dead) {
      // 켜 둔 claude: 먼저 "중단" 을 보내 보고, 5초 안에 안 멈추면 프로세스를 끈다
      try { j.L.child.stdin.write(JSON.stringify({ type: 'control_request', request_id: 'stop-' + Date.now(), request: { subtype: 'interrupt' } }) + '\n'); } catch { /* 닫힘 */ }
      j.stopTimer = setTimeout(() => { if (!j.done) { this.endLive(j.L, true); this.finishTurn(j, null); } }, 5000);
      return true;
    }
    this.kill(j);
    return true;
  }
  kill(j) {
    const pid = j.child.pid;
    if (!pid) return;
    try {
      if (isWin) spawn('taskkill', ['/pid', String(pid), '/T', '/F'], { windowsHide: true });
      else process.kill(-pid, 'SIGTERM');
    } catch { try { j.child.kill(); } catch { /* 이미 끝 */ } }
  }
  stopAll() {
    for (const j of this.jobs.values()) if (!j.done && !j.L) this.kill(j);
    for (const L of [...this.lives.values()]) this.endLive(L, true);
  }
}

function nonJson(s) { return s.split('\n').filter(l => !/^\s*\{/.test(l)).join('\n'); }
function httpError(status, message) { const e = new Error(message); e.status = status; return e; }

module.exports = { Runner, launch, CLAUDE_MODES, CODEX_MODES, CLAUDE_MODELS, CLAUDE_EFFORTS, CODEX_EFFORTS, cleanOpts, resolveBin, buildArgs, npmShimTarget, decode, httpError, ID_RE };
