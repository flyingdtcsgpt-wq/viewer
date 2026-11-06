'use strict';
const test = require('node:test');
const assert = require('node:assert');
const fs = require('fs');
const os = require('os');
const path = require('path');
const { spawn } = require('child_process');

const tmp = fs.mkdtempSync(path.join(os.tmpdir(), 'agent-chat-test-'));
process.env.CLAUDE_CONFIG_DIR = path.join(tmp, 'claude');
process.env.CODEX_HOME = path.join(tmp, 'codex');
const { ClaudeParser, CodexParser, readNewLines, Store } = require('../lib/sources');

const work = path.join(tmp, 'work');
fs.mkdirSync(work, { recursive: true });
const CID = '11111111-2222-3333-4444-555555555555';
const XID = '01a1afa6-87a9-75c1-8507-4c1539b6e9bd';

function writeFixtures() {
  const cdir = path.join(tmp, 'claude', 'projects', work.replace(/[^a-zA-Z0-9]/g, '-'));
  fs.mkdirSync(cdir, { recursive: true });
  const lines = [
    { type: 'queue-operation', operation: 'enqueue' },
    { type: 'user', cwd: work, sessionId: CID, message: { role: 'user', content: '파일 목록 보여줘' } },
    { type: 'user', isMeta: true, cwd: work, message: { role: 'user', content: '숨김' } },
    { type: 'assistant', message: { id: 'm1', role: 'assistant', content: [{ type: 'thinking', thinking: '...' }] } },
    { type: 'assistant', message: { id: 'm1', role: 'assistant', content: [{ type: 'text', text: '볼게요' }] } },
    { type: 'assistant', message: { id: 'm1', role: 'assistant', content: [{ type: 'tool_use', id: 't1', name: 'Bash', input: { command: 'ls -la' } }] } },
    { type: 'user', message: { role: 'user', content: [{ type: 'tool_result', tool_use_id: 't1', content: 'a.txt\nb.txt' }] } },
    { type: 'assistant', message: { id: 'm2', role: 'assistant', content: [{ type: 'text', text: '**두 개**입니다' }] } },
    { type: 'user', isSidechain: true, message: { role: 'user', content: '서브에이전트' } },
    { type: 'user', message: { role: 'user', content: '<command-name>/clear</command-name><command-args></command-args>' } },
    { type: 'ai-title', aiTitle: '파일 목록', sessionId: CID },
  ];
  fs.writeFileSync(path.join(cdir, CID + '.jsonl'), lines.map(l => JSON.stringify(l)).join('\n') + '\n');

  const xdir = path.join(tmp, 'codex', 'sessions', '2026', '11', '05');
  fs.mkdirSync(xdir, { recursive: true });
  const x = [
    { type: 'session_meta', payload: { id: XID, cwd: work, originator: 'codex_vscode' } },
    { type: 'response_item', payload: { type: 'message', role: 'developer', content: [{ type: 'input_text', text: 'system stuff' }] } },
    { type: 'response_item', payload: { type: 'message', role: 'user', content: [{ type: 'input_text', text: '<environment_context>\n<cwd>/x</cwd>\n</environment_context>' }] } },
    { type: 'response_item', payload: { type: 'message', role: 'user', content: [{ type: 'input_text', text: '테스트 돌려줘' }] } },
    { type: 'response_item', payload: { type: 'function_call', name: 'exec_command', arguments: '{"cmd":"npm test"}', call_id: 'c1' } },
    { type: 'response_item', payload: { type: 'function_call_output', call_id: 'c1', output: 'ok 1' } },
    { type: 'response_item', payload: { type: 'reasoning', summary: [] } },
    { type: 'event_msg', payload: { type: 'agent_message', message: '중복이라 무시' } },
    { type: 'response_item', payload: { type: 'message', role: 'assistant', content: [{ type: 'output_text', text: '통과했습니다' }] } },
  ];
  fs.writeFileSync(path.join(xdir, `rollout-2026-11-05T10-00-00-${XID}.jsonl`), x.map(l => JSON.stringify(l)).join('\n') + '\n');
}
writeFixtures();

test('Claude 기록 → 채팅 항목', () => {
  const p = new ClaudeParser(true);
  const f = path.join(tmp, 'claude', 'projects', work.replace(/[^a-zA-Z0-9]/g, '-'), CID + '.jsonl');
  for (const l of fs.readFileSync(f, 'utf8').split('\n').filter(Boolean)) p.feedLine(l);
  const items = p.items.map(i => [i.role, i.text || i.name, i.output || '']);
  assert.deepStrictEqual(items, [
    ['user', '파일 목록 보여줘', ''],
    ['assistant', '볼게요', ''],
    ['tool', 'Bash', 'a.txt\nb.txt'],
    ['assistant', '**두 개**입니다', ''],
    ['user', '/clear', ''],
  ]);
  assert.strictEqual(p.items[2].summary, 'ls -la');
  assert.strictEqual(p.items[2].status, 'done');
  assert.strictEqual(p.title(), '파일 목록');
  assert.strictEqual(p.meta.cwd, work);
});

test('Codex 기록 → 채팅 항목 (자동 삽입문 · 개발자 메시지 제외)', () => {
  const p = new CodexParser(true);
  const f = fs.readdirSync(path.join(tmp, 'codex', 'sessions', '2026', '11', '05'))[0];
  for (const l of fs.readFileSync(path.join(tmp, 'codex', 'sessions', '2026', '11', '05', f), 'utf8').split('\n').filter(Boolean)) p.feedLine(l);
  assert.deepStrictEqual(p.items.map(i => [i.role, i.text || i.summary, i.output || '']), [
    ['user', '테스트 돌려줘', ''],
    ['tool', 'npm test', 'ok 1'],
    ['assistant', '통과했습니다', ''],
  ]);
  assert.strictEqual(p.meta.originator, 'codex_vscode');
});

test('이어 읽기: 쓰는 중인 마지막 줄은 다음 번에', () => {
  const f = path.join(tmp, 'partial.jsonl');
  fs.writeFileSync(f, '{"a":1}\n{"b":');
  const st = { offset: 0 };
  assert.deepStrictEqual(readNewLines(f, st), ['{"a":1}']);
  fs.appendFileSync(f, '2}\n');
  assert.deepStrictEqual(readNewLines(f, st), ['{"b":2}']);
  assert.deepStrictEqual(readNewLines(f, st), []);
  fs.writeFileSync(f, '');
  assert.strictEqual(readNewLines(f, st), null);
});

test('목록: 두 에이전트 세션이 최근 순으로', () => {
  const s = new Store();
  const list = s.list();
  assert.strictEqual(list.length, 2);
  const c = list.find(x => x.agent === 'claude');
  assert.strictEqual(c.title, '파일 목록');
  assert.strictEqual(c.project, 'work');
  const x = list.find(x => x.agent === 'codex');
  assert.strictEqual(x.id, XID);
  assert.strictEqual(x.preview, '통과했습니다');
});

// ---------- 서버 끝까지 (가짜 claude/codex 로) ----------
async function startServer(kind) {
  const home = path.join(tmp, 'home-' + kind);
  fs.mkdirSync(home, { recursive: true });
  const fake = path.join(__dirname, 'fake-agent.js');
  fs.writeFileSync(path.join(home, 'config.json'), JSON.stringify({ token: 'test-token-1234567890', port: 0, host: '127.0.0.1', claudeBin: fake, codexBin: fake }));
  const port = 18000 + Math.floor(Math.random() * 2000);
  const child = spawn(process.execPath, [path.join(__dirname, '..', 'server.js')], {
    env: { ...process.env, AGENT_CHAT_HOME: home, AGENT_CHAT_PORT: String(port), FAKE_KIND: kind }, stdio: ['ignore', 'pipe', 'pipe'],
  });
  await new Promise((res, rej) => {
    child.stdout.on('data', d => { if (String(d).includes('Agent Chat')) res(); });
    child.on('exit', c => rej(new Error('server exit ' + c)));
    setTimeout(() => rej(new Error('timeout')), 5000);
  });
  const call = async (p, body, tok = 'test-token-1234567890') => {
    const r = await fetch(`http://127.0.0.1:${port}${p}`, {
      method: body ? 'POST' : 'GET', headers: { Authorization: 'Bearer ' + tok, 'Content-Type': 'application/json' },
      body: body ? JSON.stringify(body) : undefined,
    });
    return { status: r.status, body: await r.json().catch(() => null) };
  };
  return { child, call, port };
}
const waitFor = async (fn, ms = 5000) => {
  const end = Date.now() + ms;
  for (;;) { const v = await fn(); if (v) return v; if (Date.now() > end) throw new Error('waitFor timeout'); await new Promise(r => setTimeout(r, 100)); }
};

test('서버: 토큰 없으면 401, 화면 파일은 열림', async () => {
  const { child, call, port } = await startServer('claude');
  try {
    assert.strictEqual((await call('/api/sessions', null, 'wrong')).status, 401);
    const r = await fetch(`http://127.0.0.1:${port}/`);
    assert.strictEqual(r.status, 200);
    assert.match(await r.text(), /Agent Chat/);
    assert.strictEqual((await fetch(`http://127.0.0.1:${port}/../server.js`)).status, 404);
  } finally { child.kill(); }
});

test('서버: Claude 세션에 이어서 보내기 · 새 세션 · 실패 표시', async () => {
  const { child, call } = await startServer('claude');
  try {
    let r = await call('/api/sessions');
    assert.strictEqual(r.status, 200);
    assert.ok(r.body.sessions.some(s => s.id === CID));
    r = await call('/api/send', { agent: 'claude', id: CID, prompt: '하나 더', mode: 'plan' });
    assert.strictEqual(r.status, 200);
    const m = await waitFor(async () => {
      const x = await call(`/api/messages?agent=claude&id=${CID}`);
      return x.body.items.some(i => i.text === 'echo: 하나 더 mode=plan') && !x.body.job.running ? x.body : null;
    });
    assert.ok(m.items.some(i => i.role === 'user' && i.text === '하나 더'));

    r = await call('/api/new', { agent: 'claude', cwd: work, prompt: '새로', mode: 'acceptEdits' });
    assert.strictEqual(r.status, 200);
    const nid = r.body.id;
    await waitFor(async () => { const x = await call(`/api/messages?agent=claude&id=${nid}`); return x.status === 200 && x.body.items && x.body.items.length === 2; });

    r = await call('/api/send', { agent: 'claude', id: nid, prompt: 'FAIL', mode: 'auto' });
    const err = await waitFor(async () => { const x = await call(`/api/messages?agent=claude&id=${nid}`); return x.body.job && x.body.job.error; });
    assert.match(err, /일부러 실패/);

    r = await call('/api/new', { agent: 'claude', cwd: path.join(tmp, 'nope'), prompt: 'x', mode: 'auto' });
    assert.strictEqual(r.status, 400);
  } finally { child.kill(); }
});

test('서버: Codex 새 세션은 thread id 를 돌려주고, 이어 보내면 같은 파일에', async () => {
  const { child, call } = await startServer('codex');
  try {
    let r = await call('/api/new', { agent: 'codex', cwd: work, prompt: '안녕', mode: 'read-only' });
    assert.strictEqual(r.status, 200);
    const id = r.body.id;
    assert.match(id, /^[0-9a-f-]{36}$/);
    await waitFor(async () => { const x = await call(`/api/messages?agent=codex&id=${id}`); return x.status === 200 && x.body.items && x.body.items.length === 2 && !x.body.job.running; });
    r = await call('/api/send', { agent: 'codex', id, prompt: '다음', mode: 'workspace-write' });
    assert.strictEqual(r.status, 200);
    const m = await waitFor(async () => { const x = await call(`/api/messages?agent=codex&id=${id}`); return x.body.items && x.body.items.length === 4 ? x.body : null; });
    assert.match(m.items[3].text, /resume .*sandbox_mode=workspace-write/);
    const same = await call(`/api/messages?agent=codex&id=${id}&stamp=${encodeURIComponent(m.stamp)}`);
    assert.ok(same.body.same || same.body.stamp !== m.stamp);
  } finally { child.kill(); }
});

test.after(() => { try { fs.rmSync(tmp, { recursive: true, force: true }); } catch { /* 무시 */ } });
