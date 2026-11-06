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
async function startServer(kind, extra = {}) {
  const home = path.join(tmp, 'home-' + kind);
  fs.mkdirSync(home, { recursive: true });
  const fake = path.join(__dirname, 'fake-agent.js');
  fs.writeFileSync(path.join(home, 'config.json'), JSON.stringify({ token: 'test-token-1234567890', port: 0, host: '127.0.0.1', claudeBin: fake, codexBin: fake, ...extra }));
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

// SSE 를 열어 두고 조건이 맞을 때까지 이벤트를 모은다
async function collect(port, q, until, ms = 15000) {
  const ctrl = new AbortController();
  const r = await fetch(`http://127.0.0.1:${port}/api/stream?${q}`, { headers: { Authorization: 'Bearer test-token-1234567890' }, signal: ctrl.signal });
  const reader = r.body.getReader(); const dec = new TextDecoder();
  const evs = []; let buf = '';
  const timer = setTimeout(() => ctrl.abort(), ms);
  try {
    for (;;) {
      const { value, done } = await reader.read();
      if (done) break;
      buf += dec.decode(value, { stream: true });
      let i;
      while ((i = buf.indexOf('\n\n')) !== -1) {
        const block = buf.slice(0, i); buf = buf.slice(i + 2);
        const ev = (block.match(/^event: (.*)$/m) || [])[1]; const data = (block.match(/^data: (.*)$/m) || [])[1];
        if (ev && data) { evs.push({ ev, d: JSON.parse(data) }); if (until(evs)) { ctrl.abort(); return evs; } }
      }
    }
  } catch (e) { if (!ctrl.signal.aborted) throw e; } finally { clearTimeout(timer); }
  throw new Error('조건이 오지 않음: ' + JSON.stringify(evs.slice(-3)));
}

test('실시간: 답변이 글자 단위로 흘러오고, 작업 중 보낸 말은 줄 섰다가 이어서', async () => {
  const { child, call, port } = await startServer('claude');
  try {
    const first = collect(port, `agent=claude&id=${CID}`, evs => evs.some(e => e.ev === 'msgs' && e.d.items.some(i => i.text === 'echo: 둘째 mode=auto')));
    await new Promise(r => setTimeout(r, 300));
    let r = await call('/api/send', { agent: 'claude', id: CID, prompt: 'SLOW 첫째', mode: 'plan' });
    assert.strictEqual(r.status, 200);
    r = await call('/api/send', { agent: 'claude', id: CID, prompt: '둘째', mode: 'auto' });
    assert.strictEqual(r.body.queued, 1);
    const evs = await first;
    const lives = evs.filter(e => e.ev === 'job' && e.d.live).map(e => e.d.live);
    assert.ok(lives.length >= 3, '중간 글자가 여러 번 와야 함: ' + lives.length);
    assert.ok(lives.some(l => l.startsWith('echo: ') && l.length < 'echo: SLOW 첫째 mode=plan'.length), '완성 전 조각');
    assert.ok(evs.some(e => e.ev === 'job' && e.d.queued === 1));
    const msgs = evs.filter(e => e.ev === 'msgs');
    assert.strictEqual(msgs[0].d.full, true);
    assert.ok(msgs.slice(1).every(m => !m.d.full && m.d.items.length <= 3), '처음 이후에는 바뀐 것만');
    const all = msgs.flatMap(m => m.d.items).map(i => i.text);
    assert.ok(all.indexOf('echo: SLOW 첫째 mode=plan') < all.indexOf('echo: 둘째 mode=auto'));
  } finally { child.kill(); }
});

test('PC 연결 화면: 이 PC(localhost)에서만, 주소마다 토큰 포함 · 목록에 busy', async () => {
  const http = require('http');
  const { child, call, port } = await startServer('claude');
  const get = (p, host) => new Promise((res, rej) => {
    http.get({ host: '127.0.0.1', port, path: p, headers: { Host: host } }, r => {
      let b = ''; r.on('data', d => { b += d; }); r.on('end', () => res({ status: r.statusCode, body: b }));
    }).on('error', rej);
  });
  try {
    assert.strictEqual((await get('/connect', `localhost:${port}`)).status, 200);
    const info = await get('/api/connect-info', `127.0.0.1:${port}`);
    assert.strictEqual(info.status, 200);
    for (const u of JSON.parse(info.body).urls) assert.match(u.url, /#t=test-token-1234567890$/);
    assert.strictEqual((await get('/api/connect-info', `evil.example:${port}`)).status, 403);
    const r = await call('/api/sessions');
    assert.ok(r.body.sessions.every(s => typeof s.busy === 'boolean'));
  } finally { child.kill(); }
});

test('숫자 연결 코드: 맞으면 토큰, 한 번만, 5번 틀리면 폐기', async () => {
  const http = require('http');
  const { child, port } = await startServer('claude');
  const req = (method, p, body, host = `127.0.0.1:${port}`) => new Promise((res, rej) => {
    const r = http.request({ host: '127.0.0.1', port, path: p, method, headers: { Host: host, 'Content-Type': 'application/json' } }, x => {
      let b = ''; x.on('data', d => { b += d; }); x.on('end', () => res({ status: x.statusCode, body: b ? JSON.parse(b) : null }));
    });
    r.on('error', rej); if (body) r.write(JSON.stringify(body)); r.end();
  });
  try {
    assert.strictEqual((await req('POST', '/api/pair', { code: '123456' })).status, 410, '연결 화면을 열기 전에는 코드 없음');
    let info = (await req('GET', '/api/connect-info')).body;
    assert.match(info.pairCode, /^\d{6}$/);
    const wrong = info.pairCode === '000000' ? '111111' : '000000';
    assert.strictEqual((await req('POST', '/api/pair', { code: wrong })).status, 403);
    const ok = await req('POST', '/api/pair', { code: info.pairCode.slice(0, 3) + ' ' + info.pairCode.slice(3) });
    assert.strictEqual(ok.status, 200);
    assert.strictEqual(ok.body.token, 'test-token-1234567890');
    assert.strictEqual((await req('POST', '/api/pair', { code: info.pairCode })).status, 410, '한 번 쓰면 끝');
    info = (await req('GET', '/api/connect-info')).body;
    assert.ok(info.lastPaired > 0);
    for (let i = 0; i < 5; i++) await req('POST', '/api/pair', { code: info.pairCode === '000000' ? '111111' : '000000' });
    assert.strictEqual((await req('POST', '/api/pair', { code: info.pairCode })).status, 410, '5번 틀리면 폐기');
  } finally { child.kill(); }
});

test('프로젝트별 구독 / API: Claude 는 폴더 설정 파일 + 폰 작업에 키, Codex 는 폰 작업에만, 구독은 키를 지움', async () => {
  const http = require('http');
  const { execFileSync } = require('child_process');
  const proj = path.join(tmp, 'api-proj');
  fs.mkdirSync(path.join(proj, '.claude'), { recursive: true });
  fs.writeFileSync(path.join(proj, '.claude', 'settings.local.json'), JSON.stringify({ permissions: { allow: ['Bash(ls)'] } }));
  const { child, call, port } = await startServer('claude');
  const local = (p, body) => new Promise((res, rej) => {
    const r = http.request({ host: '127.0.0.1', port, path: p, method: 'POST', headers: { Host: `127.0.0.1:${port}`, 'Content-Type': 'application/json' } }, x => {
      let b = ''; x.on('data', d => { b += d; }); x.on('end', () => res({ status: x.statusCode, body: JSON.parse(b || '{}') }));
    });
    r.on('error', rej); r.write(JSON.stringify(body)); r.end();
  });
  try {
    // 키 없이 API 로는 못 바꿈
    let r = await call('/api/project-auth', { cwd: proj, mode: 'api' });
    assert.strictEqual(r.status, 400);
    // 키는 이 PC(localhost)에서만, 형식 확인
    assert.strictEqual((await local('/api/local/keys', { anthropic: 'nope' })).status, 400);
    r = await local('/api/local/keys', { anthropic: 'sk-ant-test-AAAA', openai: 'sk-test-BBBB' });
    assert.strictEqual(r.status, 200);
    assert.strictEqual(r.body.anthropic, true);
    assert.ok(!JSON.stringify(r.body).includes('sk-ant-test-AAAA'), '키 전체를 돌려주지 않음');
    // API 로 바꾸면 Claude 프로젝트 설정에 apiKeyHelper (원래 있던 설정은 그대로)
    r = await call('/api/project-auth', { cwd: proj, mode: 'api' });
    assert.strictEqual(r.status, 200);
    const sf = path.join(proj, '.claude', 'settings.local.json');
    let st = JSON.parse(fs.readFileSync(sf, 'utf8'));
    assert.deepStrictEqual(st.permissions, { allow: ['Bash(ls)'] });
    assert.match(st.apiKeyHelper, /print-key\.js/);
    assert.ok(!fs.readFileSync(sf, 'utf8').includes('sk-ant-test-AAAA'), '프로젝트 폴더에 키가 남지 않음');
    // apiKeyHelper 명령이 실제로 키를 출력 (Claude Code 가 하는 것처럼 셸로 실행)
    if (process.platform === 'win32') {
      // Windows: cmd 로도, Git Bash 로도 (Claude Code 가 어느 셸을 쓰든)
      const out = execFileSync('cmd.exe', ['/d', '/s', '/c', `"${st.apiKeyHelper}"`], { encoding: 'utf8', windowsVerbatimArguments: true });
      assert.strictEqual(out, 'sk-ant-test-AAAA');
      const bash = ['C:\\Program Files\\Git\\bin\\bash.exe'].find(f => fs.existsSync(f));
      if (bash) assert.strictEqual(execFileSync(bash, ['-c', st.apiKeyHelper], { encoding: 'utf8' }), 'sk-ant-test-AAAA');
    } else {
      assert.strictEqual(execFileSync('sh', ['-c', st.apiKeyHelper], { encoding: 'utf8' }), 'sk-ant-test-AAAA');
    }
    // 목록 · 새 대화: API 프로젝트에서 폰 작업에 키가 붙는다
    r = await call('/api/new', { agent: 'claude', cwd: proj, prompt: '키?', mode: 'plan' });
    const nid = r.body.id;
    await waitFor(async () => { const x = await call(`/api/messages?agent=claude&id=${nid}`); return x.body.items && x.body.items.some(i => i.text === 'echo: 키? mode=plan auth=api:sk-ant-test-AAAA'); });
    const list = (await call('/api/sessions')).body.sessions;
    assert.strictEqual(list.find(s => s.id === nid).auth, 'api');
    // 구독으로 되돌리면 apiKeyHelper 만 빠지고, 폰 작업에 키가 붙지 않는다 (환경에 키가 있어도 지움)
    r = await call('/api/project-auth', { cwd: proj, mode: 'sub' });
    st = JSON.parse(fs.readFileSync(sf, 'utf8'));
    assert.strictEqual(st.apiKeyHelper, undefined);
    assert.deepStrictEqual(st.permissions, { allow: ['Bash(ls)'] });
    r = await call('/api/send', { agent: 'claude', id: nid, prompt: '이제?', mode: 'plan' });
    await waitFor(async () => { const x = await call(`/api/messages?agent=claude&id=${nid}`); return x.body.items.some(i => i.text === 'echo: 이제? mode=plan'); });
    // 다른 apiKeyHelper 가 이미 있으면 건드리지 않는다
    const other = path.join(tmp, 'other-proj');
    fs.mkdirSync(path.join(other, '.claude'), { recursive: true });
    fs.writeFileSync(path.join(other, '.claude', 'settings.local.json'), JSON.stringify({ apiKeyHelper: 'my-own-helper' }));
    assert.strictEqual((await call('/api/project-auth', { cwd: other, mode: 'api' })).status, 409);
  } finally { child.kill(); }
});

test('Codex 프로젝트를 API 로: 폰 작업에만 CODEX_API_KEY', async () => {
  const http = require('http');
  const proj = path.join(tmp, 'codex-api-proj');
  fs.mkdirSync(proj, { recursive: true });
  const { child, call, port } = await startServer('codex');
  const local = body => new Promise((res, rej) => {
    const r = http.request({ host: '127.0.0.1', port, path: '/api/local/keys', method: 'POST', headers: { Host: `127.0.0.1:${port}`, 'Content-Type': 'application/json' } }, x => { x.resume(); x.on('end', () => res(x.statusCode)); });
    r.on('error', rej); r.write(JSON.stringify(body)); r.end();
  });
  try {
    assert.strictEqual(await local({ openai: 'sk-test-CCCC' }), 200);
    const r = await call('/api/new', { agent: 'codex', cwd: proj, prompt: '키?', mode: 'read-only', auth: 'api' });
    assert.strictEqual(r.status, 200);
    await waitFor(async () => { const x = await call(`/api/messages?agent=codex&id=${r.body.id}`); return x.body.items && x.body.items.some(i => /auth=api:sk-test-CCCC$/.test(i.text || '')); });
  } finally { child.kill(); }
});

test('보낼 때 모델 · 추론 강도 · 생각: 고른 것만 넘기고, 이상한 값은 버린다', async () => {
  const { child, call } = await startServer('claude');
  try {
    let r = await call('/api/send', { agent: 'claude', id: CID, prompt: '옵션1', mode: 'plan', opts: { model: 'opus', effort: 'high', thinking: 'off' } });
    assert.strictEqual(r.status, 200);
    await waitFor(async () => { const x = await call(`/api/messages?agent=claude&id=${CID}`); return x.body.items.some(i => i.text === 'echo: 옵션1 mode=plan model=opus effort=high think=off'); });
    r = await call('/api/send', { agent: 'claude', id: CID, prompt: '옵션2', mode: 'plan', opts: { model: 'x; rm -rf /', effort: 'huge', thinking: 'on' } });
    await waitFor(async () => { const x = await call(`/api/messages?agent=claude&id=${CID}`); return x.body.items.some(i => i.text === 'echo: 옵션2 mode=plan think=on'); });
    const info = (await call('/api/info')).body;
    assert.ok(info.models.claude.includes('opus') && info.efforts.claude.includes('max') && info.efforts.codex.includes('minimal'));
  } finally { child.kill(); }
});

test('Codex: 모델 · 추론 강도 옵션, 기록에서 쓴 모델 읽기', async () => {
  const { child, call } = await startServer('codex');
  try {
    let r = await call('/api/send', { agent: 'codex', id: XID, prompt: '옵션', mode: 'read-only', opts: { model: 'gpt-6.1-sol', effort: 'xhigh', thinking: 'off' } });
    assert.strictEqual(r.status, 200);
    const m = await waitFor(async () => { const x = await call(`/api/messages?agent=codex&id=${XID}`); return x.body.items && x.body.items.find(i => (i.text || '').startsWith('codex: 옵션')); });
    assert.match(m.text, /-m gpt-6\.1-sol/);
    assert.match(m.text, /model_reasoning_effort=xhigh/);
  } finally { child.kill(); }
  const { CodexParser, ClaudeParser } = require('../lib/sources');
  const p = new CodexParser(false);
  p.feed({ type: 'turn_context', payload: { cwd: '/x', model: 'gpt-6.1-sol' } });
  p.feed({ type: 'response_item', payload: { type: 'configuration_update', reasoning: { effort: 'low' } } });
  assert.deepStrictEqual([p.meta.model, p.meta.effort], ['gpt-6.1-sol', 'low']);
  const c = new ClaudeParser(false);
  c.feed({ type: 'assistant', message: { id: 'a', model: 'claude-opus-5-5', role: 'assistant', content: [{ type: 'text', text: 'hi' }] } });
  assert.strictEqual(c.meta.model, 'claude-opus-5-5');
});

test('Windows 도우미: npm 의 claude.cmd 는 안의 cli.js 로, 한국어 오류 글자 읽기', () => {
  const { npmShimTarget, decode } = require('../lib/runner');
  const npm = path.join(tmp, 'npm');
  const cli = path.join(npm, 'node_modules', '@anthropic-ai', 'claude-code', 'cli.js');
  fs.mkdirSync(path.dirname(cli), { recursive: true });
  fs.writeFileSync(cli, '');
  fs.writeFileSync(path.join(npm, 'claude.cmd'), '');
  assert.strictEqual(npmShimTarget('claude', path.join(npm, 'claude.cmd')), cli);
  assert.strictEqual(npmShimTarget('codex', path.join(npm, 'codex.cmd')), null);
  assert.strictEqual(decode(Buffer.from('한글 오류', 'utf8')), '한글 오류');
  // CP949 로 된 "오류"
  assert.strictEqual(decode(Buffer.from([0xbf, 0xc0, 0xb7, 0xf9])), '오류');
  const { normCwd } = require('../lib/sources');
  assert.strictEqual(normCwd('\\\\?\\C:\\Users\\me\\proj'), 'C:\\Users\\me\\proj');
});

test('Windows: 공백 있는 폴더의 .cmd 로 실행해도 따옴표 · & · 한글이 그대로', { skip: process.platform !== 'win32' }, async () => {
  const dir = path.join(tmp, 'my tools');
  fs.mkdirSync(dir, { recursive: true });
  const cmd = path.join(dir, 'fake claude.cmd');
  fs.writeFileSync(cmd, `@"${process.execPath}" "${path.join(__dirname, 'fake-agent.js')}" %*\r\n`);
  const { child, call } = await startServer('claude', { claudeBin: cmd });
  try {
    const text = '따옴표 "a" & | > 100% 한글';
    const r = await call('/api/send', { agent: 'claude', id: CID, prompt: text, mode: 'acceptEdits' });
    assert.strictEqual(r.status, 200);
    await waitFor(async () => {
      const x = await call(`/api/messages?agent=claude&id=${CID}`);
      return x.body.items.some(i => i.text === `echo: ${text} mode=acceptEdits`);
    }, 15000);
  } finally { child.kill(); }
});

test.after(() => { try { fs.rmSync(tmp, { recursive: true, force: true }); } catch { /* 무시 */ } });
