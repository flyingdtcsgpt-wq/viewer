'use strict';
// PC 의 IDE 창(VS Code · Antigravity · Cursor …)에 사람이 치듯 글을 넣는다. Windows 전용.
// 실제 일(창 찾기 · 앞으로 가져오기 · 열기 요청 · 붙여넣기 · Enter)은 type-into.ps1 이 한다.
//
// Claude Code 확장은 <scheme>://anthropic.claude-code/open?session=<id> 주소를 받으면
// 그 대화의 탭(이미 열려 있으면 그 탭)을 앞으로 가져온다. 그 뒤 글을 붙여넣고(Ctrl+V) Enter 를 누른다.
const fs = require('fs');
const os = require('os');
const path = require('path');
const crypto = require('crypto');
const { spawn } = require('child_process');

const SCRIPT = path.join(__dirname, 'type-into.ps1');

function supported() { return process.platform === 'win32' && fs.existsSync(SCRIPT); }

function powershell() {
  const root = process.env.SystemRoot || 'C:\\Windows';
  const p = path.join(root, 'System32', 'WindowsPowerShell', 'v1.0', 'powershell.exe');
  return fs.existsSync(p) ? p : 'powershell.exe';
}

// type-into.ps1 이 알려 주는 단계(stage) → 사용자에게 보일 말 (스크립트는 ASCII 만 쓴다)
function explain(r) {
  switch (r.stage) {
    case 'desktop': return 'PC 화면이 잠겨 있거나 원격 데스크톱 연결이 끊긴 상태라 키보드 입력을 넣을 수 없습니다';
    case 'in-use': return 'PC 에서 누군가 키보드를 누르고 있어 끼어들지 않았습니다';
    case 'no-window': return 'IDE 창을 찾지 못했습니다 (VS Code 창이 없음)';
    case 'no-folder-window': return `제목에 '${r.detail || ''}' 가 든 IDE 창이 없습니다`;
    case 'many-windows': return `'${r.detail || ''}' 창이 여러 개라 고를 수 없습니다`;
    case 'focus': return 'IDE 창을 맨 앞으로 가져오지 못했습니다 (화면 잠김 · 다른 창이 막음)';
    case 'open': return 'IDE 에 대화 열기 요청을 보내지 못했습니다' + (r.detail ? ': ' + r.detail : '');
    case 'job': return '작업 파일을 읽지 못했습니다' + (r.detail ? ': ' + r.detail : '');
    default: return r.detail || r.stage || '알 수 없는 오류';
  }
}

// 키보드와 맨 앞 창은 PC 에 하나뿐이라 한 번에 하나씩만
let chain = Promise.resolve();
/** job 을 type-into.ps1 에 넘기고 결과 {ok, stage, error, typed, submitted, window, ide} */
function run(job, timeoutMs = 30000) {
  const p = chain.then(() => runNow(job, timeoutMs));
  chain = p.catch(() => {});
  return p;
}
function runNow(job, timeoutMs) {
  return new Promise(resolve => {
    const f = path.join(os.tmpdir(), `agent-chat-type-${process.pid}-${crypto.randomBytes(4).toString('hex')}.json`);
    try { fs.writeFileSync(f, JSON.stringify(job), { mode: 0o600 }); } catch (e) { resolve({ ok: false, stage: 'job', error: e.message, typed: false }); return; }
    const child = spawn(powershell(), ['-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass', '-File', SCRIPT], {
      env: { ...process.env, AC_TYPE_JOB: f }, windowsHide: true, stdio: ['ignore', 'pipe', 'pipe'],
    });
    let out = '', err = '', done = false;
    const finish = r => { if (done) return; done = true; clearTimeout(tm); fs.rm(f, { force: true }, () => {}); resolve(r); };
    const tm = setTimeout(() => { try { child.kill(); } catch { /* 이미 끝 */ } finish({ ok: false, stage: 'timeout', error: 'PC 창에 입력하는 데 너무 오래 걸립니다', typed: true, submitted: true }); }, timeoutMs);
    child.stdout.on('data', d => { out += d; });
    child.stderr.on('data', d => { err += d; });
    child.on('error', e => finish({ ok: false, stage: 'spawn', error: 'PowerShell 을 실행하지 못했습니다: ' + e.message, typed: false }));
    child.on('close', () => {
      const line = out.trim().split(/\r?\n/).filter(l => l.trim().startsWith('{')).pop();
      let r = null;
      try { r = JSON.parse(line); } catch { /* 아래 */ }
      if (r && typeof r === 'object') { if (!r.ok && !r.error) r.error = explain(r); finish(r); }
      else finish({ ok: false, stage: 'script', error: (err.trim() || out.trim() || '결과를 읽지 못했습니다').split(/\r?\n/).slice(0, 4).join(' '), typed: false });
    });
  });
}

/**
 * Claude 대화(live = peer.findLive 의 결과)에 넣을 작업.
 * 주소에는 대화 id 만 싣는다: 확장(2.1.325 에서 확인)은 이미 탭으로 열린 대화에는 prompt 를 채워 주지 않고
 * 탭만 앞으로 가져온다. 그래서 글은 붙여넣기(Ctrl+V)로 넣고 Enter 를 누른다.
 */
function claudeJob(live, text, { settleMs, ideNames, dryRun } = {}) {
  return {
    text, folder: path.basename(live.cwd || '') || '', pid: live.pid,
    uri: `anthropic.claude-code/open?session=${encodeURIComponent(live.sessionId)}`,
    paste: true, submit: true,
    settleMs: settleMs || 0, ideNames: ideNames || [], dryRun: !!dryRun,
  };
}

async function typeIntoClaude(live, text, opts) { return run(claudeJob(live, text, opts)); }

module.exports = { supported, run, claudeJob, typeIntoClaude, explain, SCRIPT };
