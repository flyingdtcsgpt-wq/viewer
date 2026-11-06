'use strict';
// 휴대폰에서 보낸 말을 PC 의 claude / codex 프로그램으로 같은 세션에 이어서 보낸다.
//   Claude : claude -p --resume <id> --permission-mode <모드>   (말은 표준입력으로)
//   Codex  : codex exec resume <id> -  (-c sandbox_mode=<모드>, 말은 표준입력으로)
// 프로그램은 PATH → VS Code 확장 폴더 안에 들어 있는 것 순서로 찾는다.
const fs = require('fs');
const path = require('path');
const os = require('os');
const crypto = require('crypto');
const { spawn } = require('child_process');

const isWin = process.platform === 'win32';
const ID_RE = /^[0-9A-Za-z][0-9A-Za-z-]{6,63}$/;
const CLAUDE_MODES = ['acceptEdits', 'auto', 'bypassPermissions', 'plan', 'default', 'manual', 'dontAsk'];
const CODEX_MODES = ['workspace-write', 'read-only', 'danger-full-access'];

function isFile(p) { try { return fs.statSync(p).isFile(); } catch { return false; } }

function findOnPath(name) {
  const dirs = (process.env.PATH || '').split(path.delimiter).filter(Boolean);
  const exts = isWin ? ['.exe', '.cmd', '.bat', ''] : [''];
  for (const d of dirs) {
    for (const x of exts) {
      const p = path.join(d, name + x);
      if (isFile(p)) return p;
    }
  }
  return null;
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
  if (agent === 'claude') {
    if (config.claudeBin && isFile(config.claudeBin)) return config.claudeBin;
    return findOnPath('claude') ||
      findInExtensions('anthropic.claude-code', isWin ? ['claude.exe', 'cli.js'] : ['claude', 'cli.js']);
  }
  if (config.codexBin && isFile(config.codexBin)) return config.codexBin;
  return findOnPath('codex') || findInExtensions('openai.chatgpt', isWin ? ['codex.exe'] : ['codex']);
}

function buildArgs(agent, { id, isNew, mode }, config) {
  if (agent === 'claude') {
    const a = ['-p', '--permission-mode', mode];
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

function tail(s, add, max = 6000) { s += add; return s.length > max ? s.slice(-max) : s; }

class Runner {
  constructor(config) {
    this.config = config;
    this.jobs = new Map(); // "agent:id" → job
  }
  bins() { return { claude: resolveBin('claude', this.config), codex: resolveBin('codex', this.config) }; }
  job(agent, id) {
    const j = this.jobs.get(agent + ':' + id);
    if (!j) return null;
    if (j.done && Date.now() - j.endedAt > 30 * 60 * 1000) { this.jobs.delete(agent + ':' + id); return null; }
    return { running: !j.done, startedAt: j.startedAt, endedAt: j.endedAt || 0, error: j.error || '', stopped: !!j.stopped };
  }
  running(agent, id) { const j = this.jobs.get(agent + ':' + id); return !!(j && !j.done); }

  // 반환: Promise<{id}>  (새 Codex 세션은 id 가 정해질 때까지 기다린다)
  start(agent, { id, cwd, prompt, mode }) {
    if (agent !== 'claude' && agent !== 'codex') throw httpError(400, '알 수 없는 에이전트');
    const modes = agent === 'claude' ? CLAUDE_MODES : CODEX_MODES;
    if (!modes.includes(mode)) mode = modes[0];
    if (typeof prompt !== 'string' || !prompt.trim()) throw httpError(400, '보낼 내용이 없습니다');
    if (!cwd || !fs.existsSync(cwd) || !fs.statSync(cwd).isDirectory()) throw httpError(400, `작업 폴더가 없습니다: ${cwd || '(없음)'}`);
    const isNew = !id;
    if (!isNew && !ID_RE.test(id)) throw httpError(400, '세션 id 가 이상합니다');
    if (!isNew && this.running(agent, id)) throw httpError(409, '이 세션은 아직 작업 중입니다');
    const bin = resolveBin(agent, this.config);
    if (!bin) throw httpError(500, `${agent} 프로그램을 찾지 못했습니다. config.json 의 ${agent}Bin 에 경로를 적어 주세요`);
    if (isNew && agent === 'claude') id = crypto.randomUUID();

    const child = launch(bin, buildArgs(agent, { id, isNew, mode }, this.config), cwd);
    const job = { agent, id, child, startedAt: Date.now(), out: '', err: '', done: false };
    if (id) this.jobs.set(agent + ':' + id, job);

    let resolveId;
    const idReady = new Promise((res, rej) => { resolveId = res; job.reject = rej; });
    if (id) resolveId({ id });

    let buf = '';
    child.stdout.on('data', d => {
      const s = d.toString('utf8');
      job.out = tail(job.out, s);
      if (agent !== 'codex') return;
      buf += s;
      let i;
      while ((i = buf.indexOf('\n')) !== -1) {
        const line = buf.slice(0, i); buf = buf.slice(i + 1);
        let ev; try { ev = JSON.parse(line); } catch { continue; }
        if (ev.type === 'thread.started' && ev.thread_id && !job.id) {
          job.id = String(ev.thread_id).toLowerCase();
          this.jobs.set('codex:' + job.id, job);
          resolveId({ id: job.id });
        } else if (ev.type === 'turn.failed' && ev.error) job.error = ev.error.message || String(ev.error);
        else if (ev.type === 'error' && ev.message && !/^Reconnecting/.test(ev.message)) job.error = ev.message;
      }
    });
    child.stderr.on('data', d => { job.err = tail(job.err, d.toString('utf8')); });
    child.on('error', e => { job.error = `실행 실패: ${e.message}`; finish(-1); });
    child.on('close', code => finish(code));
    const finish = code => {
      if (job.done) return;
      job.done = true; job.endedAt = Date.now(); job.code = code;
      if (code !== 0 && !job.stopped && !job.error) {
        job.error = (job.err.trim() || job.out.trim()).split('\n').slice(-8).join('\n') || `종료 코드 ${code}`;
      }
      if (!job.id) job.reject(httpError(500, job.error || 'Codex 세션을 시작하지 못했습니다'));
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

function httpError(status, message) { const e = new Error(message); e.status = status; return e; }

module.exports = { Runner, CLAUDE_MODES, CODEX_MODES, resolveBin, buildArgs, httpError, ID_RE };
