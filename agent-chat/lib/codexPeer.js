'use strict';
// VS Code 의 Codex 확장이 열어 둔 대화에 메시지를 넣는다.
//
// Codex 는 대화마다 "줄 선 메시지" 를 $CODEX_HOME 의 queue DB 에 두고, 그 대화를 열어 둔 app-server
// (VS Code 확장 안에서 돈다) 가 지금 일이 끝나면 그 줄을 가져가 정상 사용자 메시지로 처리한다.
// `codex queue` 명령이 쓰는 것과 같은 길이다.
//
// 우리는 잠깐 띄운 우리만의 app-server(대화를 열지 않음 → 줄을 가져가지 않음)로
//   thread/queue/add  {threadId, input:[{type:'text',text}], clientUserMessageId}
//   thread/queue/list {threadId}
//   thread/queue/delete {threadId, queuedSubmissionId}
// 를 부른다. (experimentalApi 표시 필요)
const crypto = require('crypto');
const { spawn } = require('child_process');

class AppServer {
  constructor(child) {
    this.child = child;
    this.buf = '';
    this.id = 0;
    this.pend = new Map();
    this.closed = false;
    child.stdout.on('data', d => {
      this.buf += d;
      let i;
      while ((i = this.buf.indexOf('\n')) !== -1) {
        const line = this.buf.slice(0, i); this.buf = this.buf.slice(i + 1);
        let o; try { o = JSON.parse(line); } catch { continue; }
        if (o && o.id != null && !o.method && this.pend.has(o.id)) { const p = this.pend.get(o.id); this.pend.delete(o.id); p(o); }
      }
    });
    const fail = () => { this.closed = true; for (const p of this.pend.values()) p({ error: { message: 'Codex app-server 가 끝났습니다' } }); this.pend.clear(); };
    child.on('close', fail);
    child.on('error', fail);
    child.stdin.on('error', () => { /* 끝난 경우 */ });
  }
  rpc(method, params, timeoutMs = 15000) {
    if (this.closed) return Promise.resolve({ error: { message: 'Codex app-server 가 끝났습니다' } });
    return new Promise(resolve => {
      const i = ++this.id;
      const t = setTimeout(() => { this.pend.delete(i); resolve({ error: { message: `${method} 시간 초과` } }); }, timeoutMs);
      this.pend.set(i, o => { clearTimeout(t); resolve(o); });
      this.child.stdin.write(JSON.stringify({ jsonrpc: '2.0', id: i, method, params }) + '\n');
    });
  }
  notify(method, params) { if (!this.closed) this.child.stdin.write(JSON.stringify({ jsonrpc: '2.0', method, params }) + '\n'); }
  close() { try { this.child.stdin.end(); } catch { /* 이미 */ } setTimeout(() => { try { this.child.kill(); } catch { /* 이미 */ } }, 3000).unref(); }
}

/** 우리만의 app-server 를 띄우고 초기화한다. launch(bin,args,cwd,env) 는 runner 의 것을 받는다. */
async function open(launch, bin, cwd, env) {
  const child = launch(bin, ['app-server'], cwd, env);
  const s = new AppServer(child);
  const init = await s.rpc('initialize', { clientInfo: { name: 'agent-chat', title: 'Agent Chat', version: '1' }, capabilities: { experimentalApi: true } });
  if (init.error) { s.close(); throw new Error('Codex app-server 시작 실패: ' + init.error.message); }
  s.notify('initialized', {});
  return s;
}

/**
 * 다른 Codex(VS Code 확장 등)가 이 대화를 열어 두었는가.
 * Codex 는 대화를 연 동안 $CODEX_HOME/thread-writer-locks/<id>.lock 을 두고, 닫으면 지운다.
 * 이때 우리가 따로 codex exec resume 을 돌리면 "already has an active writer" 로 실패한다.
 */
function writerLocked(id) {
  const home = process.env.CODEX_HOME || require('path').join(require('os').homedir(), '.codex');
  try { return require('fs').existsSync(require('path').join(home, 'thread-writer-locks', String(id).toLowerCase() + '.lock')); } catch { return false; }
}

const err = r => (r && r.error ? r.error.message || JSON.stringify(r.error) : '');

async function add(s, threadId, text) {
  const cuid = crypto.randomUUID();
  const r = await s.rpc('thread/queue/add', { threadId, input: [{ type: 'text', text }], clientUserMessageId: cuid });
  if (r.error) throw new Error('줄에 넣지 못했습니다: ' + err(r));
  const res = r.result || {};
  let id = res.id || res.queuedSubmissionId || (res.item && res.item.id) || (res.queuedSubmission && res.queuedSubmission.id) || null;
  if (!id) {
    // 응답에 id 가 없으면 목록에서 우리가 붙인 clientUserMessageId 로 찾는다
    const items = await list(s, threadId);
    const mine = items.find(x => x.clientUserMessageId === cuid);
    id = mine ? mine.id : null;
  }
  return { id, cuid };
}

async function list(s, threadId) {
  const r = await s.rpc('thread/queue/list', { threadId });
  if (r.error) throw new Error('줄을 읽지 못했습니다: ' + err(r));
  return (r.result && r.result.data) || [];
}

async function remove(s, threadId, queuedSubmissionId) {
  const r = await s.rpc('thread/queue/delete', { threadId, queuedSubmissionId });
  if (r.error) throw new Error('줄에서 빼지 못했습니다: ' + err(r));
  return !!(r.result && r.result.deleted);
}

module.exports = { open, add, list, remove, writerLocked };
