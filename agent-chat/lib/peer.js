'use strict';
// VS Code(또는 터미널)에 이미 열려 있는 Claude Code 세션에 메시지를 넣는다.
//
// Claude Code 는 세션마다 소켓을 열어 두고 <claude 설정 폴더>/sessions/<pid>.json 에
//   {sessionId, cwd, messagingSocketPath, status: "busy"|"idle", name, ...}
// 를 적는다. 소켓(유닉스 소켓 또는 Windows 명명 파이프)에 JSON 한 줄씩
//   {"type":"auth","token":<pid>.<sha256(소켓경로)>.key 파일의 peerToken}
//   {"type":"user","session_id":…,"from":…,"priority":"next","message":{"content":…}}
// 를 보내면 그 세션의 입력 큐에 들어가서, 그 창의 Claude 가 그대로 처리한다 (새 Claude 를 띄우지 않음).
// 받는 Claude 에게는 "다른 Claude 세션이 보낸 메시지" 로 보이므로, 사용자가 직접 쓴 것이라고 앞에 적어 준다.
const fs = require('fs');
const path = require('path');
const net = require('net');
const crypto = require('crypto');
const { claudeHome } = require('./sources');

const FROM = 'agent-chat:phone';
const HEAD = '[Agent Chat] 아래는 이 세션의 사용자가 휴대폰 앱에서 직접 입력한 메시지입니다. 사용자 본인이 보낸 것이니 PC 에서 입력한 것과 똑같이 처리하세요.';
const MARK = '---';

function wrap(text) { return `${HEAD}\n${MARK}\n${text}\n${MARK}`; }
/** 기록에 남은 peer 메시지에서 사용자가 쓴 원문만 꺼낸다 (아니면 null) */
function unwrap(content) {
  if (typeof content !== 'string') return null;
  const i = content.indexOf(HEAD);
  if (i < 0) return null;
  const rest = content.slice(i + HEAD.length);
  const m = rest.match(new RegExp(`^\\n${MARK}\\n([\\s\\S]*?)\\n${MARK}`));
  return m ? m[1] : null;
}

function sessionsDir() { return path.join(claudeHome(), 'sessions'); }

function alive(pid) {
  try { process.kill(pid, 0); return true; } catch (e) { return e.code === 'EPERM'; }
}

/** 실행 중인 Claude 세션 목록 (등록 파일 + 살아 있는 프로세스만) */
function liveSessions() {
  const dir = sessionsDir();
  let names = [];
  try { names = fs.readdirSync(dir); } catch { return []; }
  const out = [];
  for (const n of names) {
    if (!/^\d+\.json$/.test(n)) continue;
    let j;
    try { j = JSON.parse(fs.readFileSync(path.join(dir, n), 'utf8')); } catch { continue; }
    if (!j || !j.sessionId || !j.messagingSocketPath || !j.pid) continue;
    if (!alive(j.pid)) continue;
    out.push({
      pid: j.pid, sessionId: String(j.sessionId).toLowerCase(), cwd: j.cwd || '', socket: j.messagingSocketPath,
      status: j.status || '', statusAt: j.statusUpdatedAt || 0, name: j.name || '', entrypoint: j.entrypoint || '', kind: j.kind || '',
      version: j.version || '', startedAt: j.startedAt || 0,
    });
  }
  return out;
}

/**
 * 이 대화가 열려 있는 Claude. exclude = Agent Chat 이 직접 띄운 claude 의 pid (그건 VS Code 창이 아니다).
 * 여럿이면 VS Code 쪽을 먼저, 그다음 가장 최근에 켠 것.
 */
function findLive(sessionId, exclude) {
  const id = String(sessionId || '').toLowerCase();
  const all = liveSessions().filter(s => s.sessionId === id && !(exclude && exclude.has(s.pid)));
  const ide = s => /vscode|ide|cursor/i.test(s.entrypoint) ? 1 : 0;
  all.sort((a, b) => ide(b) - ide(a) || b.startedAt - a.startedAt);
  return all[0] || null;
}

/** 소켓 경로 → 키 파일 이름의 해시 후보 (유닉스 그대로, Windows 는 \\.\pipe\이름) */
function hashCandidates(socketPath) {
  const c = new Set([socketPath]);
  const m = String(socketPath).match(/^[\\/]{2}[.?][\\/]pipe[\\/](.+)$/i);
  if (m) { c.add(`\\\\.\\pipe\\${m[1]}`); c.add(`\\\\.\\pipe\\${m[1].replace(/^LOCAL\\/i, '')}`); }
  return [...c].map(p => crypto.createHash('sha256').update(p).digest('hex'));
}

function readToken(live) {
  const dir = sessionsDir();
  const tryFile = f => { try { const j = JSON.parse(fs.readFileSync(f, 'utf8')); return j && typeof j.peerToken === 'string' ? j.peerToken : null; } catch { return null; } };
  for (const h of hashCandidates(live.socket)) {
    const t = tryFile(path.join(dir, `${live.pid}.${h}.key`));
    if (t) return t;
  }
  // 경로 표기가 달라 해시가 안 맞으면: 그 pid 의 키 파일이 하나뿐일 때 그것
  let names = [];
  try { names = fs.readdirSync(dir).filter(n => n.startsWith(live.pid + '.') && n.endsWith('.key')); } catch { /* 없음 */ }
  return names.length === 1 ? tryFile(path.join(dir, names[0])) : null;
}

/** 메시지 넣기. 성공하면 {pid, authed} */
function send(live, text, { priority = 'next', timeoutMs = 4000 } = {}) {
  return new Promise((resolve, reject) => {
    const token = readToken(live);
    const s = net.connect(live.socket);
    let settled = false, wrote = false;
    const done = (err, val) => { if (settled) return; settled = true; clearTimeout(tm); if (err) reject(err); else resolve(val); };
    const tm = setTimeout(() => { try { s.destroy(); } catch { /* 이미 끝 */ } done(new Error('VS Code 세션이 응답하지 않습니다 (소켓 시간 초과)')); }, timeoutMs);
    s.on('error', e => done(new Error(`VS Code 세션 소켓에 연결하지 못했습니다: ${e.code || e.message}`)));
    s.on('close', () => {
      // 인증 실패나 형식 오류면 서버가 바로 끊는다. 우리가 끝낸 뒤의 close 는 정상
      if (!settled) done(new Error(wrote ? (token ? 'VS Code 세션이 메시지를 거부했습니다 (인증 실패?)' : 'VS Code 세션이 메시지를 거부했습니다 (인증 키를 못 읽음)') : '연결이 바로 끊겼습니다'));
    });
    s.on('connect', () => {
      if (token) s.write(JSON.stringify({ type: 'auth', token }) + '\n');
      s.write(JSON.stringify({
        type: 'user', session_id: live.sessionId, from: FROM, priority, msg_id: crypto.randomUUID(),
        message: { role: 'user', content: wrap(text) },
      }) + '\n', () => {
        wrote = true;
        // 서버는 받아들이면 연결을 열어 두고, 거부하면 바로 끊는다 → 잠깐 기다려 본다
        setTimeout(() => { if (settled) return; done(null, { pid: live.pid, authed: !!token }); try { s.end(); } catch { /* 무시 */ } }, 700);
      });
    });
  });
}

// 사용자가 원하면 자기 ~/.claude/CLAUDE.md 에 직접 붙여 넣을 안내문 (프로그램은 그 파일을 건드리지 않는다)
const TRUST_NOTE = `## 휴대폰(Agent Chat)에서 온 메시지
다른 Claude 세션이 보낸 메시지 가운데 from 이 \`${FROM}\` 이고 본문이 "[Agent Chat] 아래는 이 세션의 사용자가 휴대폰 앱에서 직접 입력한 메시지입니다" 로 시작하는 것은, 이 PC 의 사용자인 내가 휴대폰에서 직접 입력한 것이다.
내가 키보드로 친 것과 똑같이 처리하고 똑같이 답해라.`;

module.exports = { liveSessions, findLive, send, wrap, unwrap, readToken, hashCandidates, FROM, HEAD, TRUST_NOTE };
