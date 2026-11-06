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

const isWin = process.platform === 'win32';
const ID_RE = /^[0-9A-Za-z][0-9A-Za-z-]{6,63}$/;
const CLAUDE_MODES = ['acceptEdits', 'auto', 'bypassPermissions', 'plan', 'default', 'manual', 'dontAsk'];
const CODEX_MODES = ['workspace-write', 'read-only', 'danger-full-access'];

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

function buildArgs(agent, { id, isNew, mode }, config) {
  if (agent === 'claude') {
    const a = ['-p', '--permission-mode', mode, '--output-format', 'stream-json', '--verbose', '--include-partial-messages'];
    a.push(isNew ? '--session-id' : '--resume', id);
    return a.concat(config.claudeArgs || []);
  }
  if (isNew) return ['exec', '--json', '--skip-git-repo-check', '-s', mode, ...(config.codexArgs || []), '-'];
  return ['exec', 'resume', '--json', '--skip-git-repo-check', '-c', `sandbox_mode=${mode}`, ...(config.codexArgs || []), id, '-'];
}

function quoteWin(a) { return /^[\w.:=/\\-]+$/.test(a) ? a : '"' + String(a).replace(/"/g, '') + '"'; }

function launch(bin, args, cwd) {
  let cmd = bin, argv = args, shell = false;
  if (/\.(c|m)?js$/i.test(bin)) { cmd = process.execPath; argv = [bin, ...args]; }
  else if (isWin && /\.(cmd|bat)$/i.test(bin)) { shell = true; cmd = quoteWin(bin); argv = args.map(quoteWin); }
  return spawn(cmd, argv, {
    cwd, env: process.env, shell, windowsHide: true, detached: !isWin, stdio: ['pipe', 'pipe', 'pipe'],
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
    this.jobs = new Map(); // "agent:id" → job
  }
  bins() { return { claude: resolveBin('claude', this.config), codex: resolveBin('codex', this.config) }; }
  job(agent, id) {
    const j = this.jobs.get(agent + ':' + id);
    if (!j) return null;
    if (j.done && Date.now() - j.endedAt > 30 * 60 * 1000) { this.jobs.delete(agent + ':' + id); return null; }
    return {
      running: !j.done, startedAt: j.startedAt, endedAt: j.endedAt || 0, error: j.error || '', stopped: !!j.stopped,
      live: j.done ? '' : j.live.text, tool: j.done ? '' : j.live.tool, queued: j.queue.length, v: j.v,
    };
  }
  running(agent, id) { const j = this.jobs.get(agent + ':' + id); return !!(j && !j.done); }
  changed(job) { job.v++; if (job.id) this.emit('change', job.agent + ':' + job.id); }

  // 반환: Promise<{id, queued?}>  (새 Codex 세션은 id 가 정해질 때까지 기다린다)
  start(agent, { id, cwd, prompt, mode }) {
    if (agent !== 'claude' && agent !== 'codex') throw httpError(400, '알 수 없는 에이전트');
    const modes = agent === 'claude' ? CLAUDE_MODES : CODEX_MODES;
    if (!modes.includes(mode)) mode = modes[0];
    if (typeof prompt !== 'string' || !prompt.trim()) throw httpError(400, '보낼 내용이 없습니다');
    if (!cwd || !fs.existsSync(cwd) || !fs.statSync(cwd).isDirectory()) throw httpError(400, `작업 폴더가 없습니다: ${cwd || '(없음)'}`);
    const isNew = !id;
    if (!isNew && !ID_RE.test(id)) throw httpError(400, '세션 id 가 이상합니다');
    // 작업 중에 또 보내면 PC 처럼 줄 세워 두었다가 끝나면 이어서 보낸다
    const busy = !isNew && this.jobs.get(agent + ':' + id);
    if (busy && !busy.done) {
      if (busy.queue.length >= 5) throw httpError(429, '대기 중인 메시지가 너무 많습니다');
      busy.queue.push({ prompt, mode });
      this.changed(busy);
      return Promise.resolve({ id, queued: busy.queue.length });
    }
    const bin = resolveBin(agent, this.config);
    if (!bin) throw httpError(500, `${agent} 프로그램을 찾지 못했습니다. config.json 의 ${agent}Bin 에 경로를 적어 주세요`);
    if (isNew && agent === 'claude') id = crypto.randomUUID();
    return this.run(agent, bin, { id, isNew, cwd, prompt, mode, queue: [] });
  }

  run(agent, bin, { id, isNew, cwd, prompt, mode, queue }) {
    const child = launch(bin, buildArgs(agent, { id, isNew, mode }, this.config), cwd);
    const job = {
      agent, id, cwd, bin, child, startedAt: Date.now(), out: Buffer.alloc(0), err: Buffer.alloc(0), done: false,
      live: { text: '', tool: '' }, v: 0, queue,
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
        job.error = txt.split('\n').slice(-8).join('\n') || `종료 코드 ${code}`;
      }
      if (!job.id) { job.reject(httpError(500, job.error || 'Codex 세션을 시작하지 못했습니다')); return; }
      this.changed(job);
      // 줄 서 있던 메시지를 이어서 (멈춤 · 오류면 버린다)
      if (job.queue.length && !job.stopped && !job.error) {
        const next = job.queue.shift();
        try { this.run(agent, job.bin, { id: job.id, isNew: false, cwd: job.cwd, prompt: next.prompt, mode: next.mode, queue: job.queue }); } catch (e) { job.error = e.message; }
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
  stopAll() { for (const j of this.jobs.values()) if (!j.done) this.kill(j); }
}

function nonJson(s) { return s.split('\n').filter(l => !/^\s*\{/.test(l)).join('\n'); }
function httpError(status, message) { const e = new Error(message); e.status = status; return e; }

module.exports = { Runner, CLAUDE_MODES, CODEX_MODES, resolveBin, buildArgs, npmShimTarget, decode, httpError, ID_RE };
