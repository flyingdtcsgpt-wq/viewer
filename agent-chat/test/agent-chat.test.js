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
  fs.writeFileSync(path.join(home, 'config.json'), JSON.stringify({ token: 'test-token-1234567890', port: 0, host: '127.0.0.1', claudeBin: fake, codexBin: fake, codexPickupMs: 500, codexActiveMs: 0, codexQuietMs: 1500, ...extra }));
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
    // Claude Code 의 대화 목록은 entrypoint 가 sdk-* 인 대화를 숨긴다 → 폰에서 만든 대화는 우리 이름으로
    const nf = path.join(tmp, 'claude', 'projects', work.replace(/[^a-zA-Z0-9]/g, '-'), nid + '.jsonl');
    assert.strictEqual(JSON.parse(fs.readFileSync(nf, 'utf8').split('\n')[0]).entrypoint, 'agent-chat');

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
    const first = await waitFor(async () => { const x = await call(`/api/messages?agent=codex&id=${id}`); return x.status === 200 && x.body.items && x.body.items.length === 2 && !x.body.job.running ? x.body : null; });
    // 새 대화는 VS Code 와 같은 길(app-server)로: 출처가 vscode 라 VS Code 의 Codex 목록에 보인다
    assert.match(first.items[1].text, /^codex: 안녕 app-server sandbox=read-only approval=never/);
    const rf = fs.readdirSync(path.join(tmp, 'codex', 'sessions', '2026', '11', '06')).find(n => n.includes(id));
    assert.strictEqual(JSON.parse(fs.readFileSync(path.join(tmp, 'codex', 'sessions', '2026', '11', '06', rf), 'utf8').split('\n')[0]).payload.source, 'vscode');
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
    assert.ok(info.models.claude.includes('opus') && info.efforts.claude.includes('max') && info.efforts.codex.length > 0);
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

test('남은 사용량: Claude 작업 이벤트 · 계정 조회, Codex 기록', async () => {
  const { Usage } = require('../lib/usage');
  const u = new Usage();
  // 실제 claude -p stream-json 에서 본 모양
  u.fromClaudeEvent({ status: 'allowed', resetsAt: 1794164400, rateLimitType: 'seven_day', unifiedWindows: { seven_day: { utilization: 0.67, resetsAt: 1794164400, status: 'allowed' } } });
  assert.deepStrictEqual(u.claude.windows.map(w => [w.key, w.label, w.pct, w.resetsAt]), [['seven_day', '주간', 67, 1794164400000]]);
  u.fromClaudeEvent({ unifiedWindows: { five_hour: { utilization: 0.125, resetsAt: 1794100000 } } });
  assert.deepStrictEqual(u.claude.windows.map(w => [w.key, w.pct]), [['five_hour', 12.5], ['seven_day', 67]], '창이 합쳐지고 5시간이 앞');
  u.fromCodex({ primary: { used_percent: 40, window_minutes: 300, resets_in_seconds: 600 }, secondary: { used_percent: 81.5, window_minutes: 10080, resets_at: 1794200000 } }, 1000);
  assert.deepStrictEqual(u.codex.windows.map(w => [w.label, w.pct, w.resetsAt]), [['5시간', 40, 601000], ['주간', 81.5, 1794200000000]]);
  // Codex 계정 조회 (app-server account/rateLimits/read): codex 칸을 먼저
  u.fromCodexAccount({ rateLimits: { primary: { usedPercent: 1, windowDurationMins: 300 } }, rateLimitsByLimitId: { codex: { primary: { usedPercent: 96, windowDurationMins: 10080, resetsAt: 1794300000 } } } });
  assert.deepStrictEqual(u.codex.windows.map(w => [w.label, w.pct, w.resetsAt]), [['주간', 96, 1794300000000]]);
  assert.strictEqual(u.codex.source, 'account');
  u.fromCodex({ primary: { used_percent: 10, window_minutes: 10080 } }, 5000);
  assert.strictEqual(u.codex.windows[0].pct, 96, '오래된 기록 값이 계정 조회 값을 덮지 않는다');

  // 서버: Claude 는 로그인 정보로 조회(가짜 사용량 서버), Codex 는 기록의 token_count
  const http = require('http');
  let gotAuth = '';
  const fake = http.createServer((req, res) => { gotAuth = req.headers.authorization; res.end(JSON.stringify({ five_hour: { utilization: 32, resets_at: '2026-11-06T20:00:00Z' }, seven_day: { utilization: 67.4, resets_at: '2026-11-09T09:00:00Z' }, extra: 1 })); });
  await new Promise(r => fake.listen(0, '127.0.0.1', r));
  fs.writeFileSync(path.join(tmp, 'claude', '.credentials.json'), JSON.stringify({ claudeAiOauth: { accessToken: 'oauth-test-token' } }));
  const xdir = path.join(tmp, 'codex', 'sessions', '2026', '11', '07');
  fs.mkdirSync(xdir, { recursive: true });
  const rid = '22222222-aaaa-bbbb-cccc-333333333333';
  fs.writeFileSync(path.join(xdir, `rollout-2026-11-07T00-00-00-${rid}.jsonl`), [
    { type: 'session_meta', payload: { id: rid, cwd: work } },
    { type: 'response_item', payload: { type: 'message', role: 'user', content: [{ type: 'input_text', text: 'hi' }] } },
    { timestamp: '2026-11-07T00:00:05Z', type: 'event_msg', payload: { type: 'token_count', info: {}, rate_limits: { primary: { used_percent: 12, window_minutes: 300, resets_at: 1794200000 }, secondary: { used_percent: 55, window_minutes: 10080 } } } },
  ].map(l => JSON.stringify(l)).join('\n') + '\n');
  process.env.AGENT_CHAT_CLAUDE_USAGE_URL = `http://127.0.0.1:${fake.address().port}/api/oauth/usage`;
  const { child, call } = await startServer('claude');
  delete process.env.AGENT_CHAT_CLAUDE_USAGE_URL;
  try {
    const r = (await call('/api/usage')).body;
    assert.strictEqual(gotAuth, 'Bearer oauth-test-token');
    assert.deepStrictEqual(r.claude.windows.map(w => [w.label, w.pct]), [['5시간', 32], ['주간', 67.4]]);
    assert.strictEqual(r.claude.source, 'account');
    // Codex 는 계정 조회(가짜 app-server)가 되면 그 값, 기록의 오래된 값이 아니라
    assert.deepStrictEqual(r.codex.windows.map(w => [w.label, w.pct]), [['주간', 96]]);
    assert.strictEqual(r.codex.source, 'account');
  } finally {
    child.kill(); fake.close();
    fs.rmSync(path.join(tmp, 'claude', '.credentials.json'), { force: true });
  }
});

test('한 대화 = 한 claude 프로세스: 메시지마다 새로 뜨지 않고, 설정을 바꾸면 그때만 새로', async () => {
  const { child, call } = await startServer('claude', { claudeIdleMs: 1500 });
  const msgs = () => call(`/api/messages?agent=claude&id=${CID}`).then(x => x.body);
  const sendWait = async (prompt, opts, expect) => {
    const r = await call('/api/send', { agent: 'claude', id: CID, prompt, mode: 'plan', opts });
    assert.strictEqual(r.status, 200);
    return waitFor(async () => { const b = await msgs(); return b.items.some(i => i.text === expect) && !b.job.running ? b.job : null; });
  };
  try {
    const j1 = await sendWait('하나', {}, 'echo: 하나 mode=plan');
    assert.ok(j1.pid > 0, '켜 둔 프로세스 번호');
    const j2 = await sendWait('둘', {}, 'echo: 둘 mode=plan');
    assert.strictEqual(j2.pid, j1.pid, '두 번째 메시지도 같은 프로세스');
    const j3 = await sendWait('셋', { model: 'opus' }, 'echo: 셋 mode=plan model=opus');
    assert.notStrictEqual(j3.pid, j1.pid, '모델을 바꾸면 새로 띄움');
    // 중단: 같은 프로세스는 살아 있고 오류로 치지 않음
    await call('/api/send', { agent: 'claude', id: CID, prompt: 'HANG 오래', mode: 'plan', opts: { model: 'opus' } });
    await waitFor(async () => (await msgs()).job.running);
    assert.strictEqual((await call('/api/stop', { agent: 'claude', id: CID })).body.stopped, true);
    const js = await waitFor(async () => { const j = (await msgs()).job; return !j.running ? j : null; });
    assert.strictEqual(js.error, '');
    assert.strictEqual(js.stopped, true);
    const j4 = await sendWait('넷', { model: 'opus' }, 'echo: 넷 mode=plan model=opus');
    assert.strictEqual(j4.pid, j3.pid, '중단한 뒤에도 같은 프로세스');
    // 조용하면 닫힌다 (여기서는 1.5초)
    await waitFor(async () => (await msgs()).job.pid === 0, 15000);
    const j5 = await sendWait('다섯', { model: 'opus' }, 'echo: 다섯 mode=plan model=opus');
    assert.ok(j5.pid > 0 && j5.pid !== j4.pid, '닫힌 뒤에는 새로 띄워 이어서');
  } finally { child.kill(); }
});

test('중단을 안 들으면 5초 뒤 프로세스를 끄고, 다음 메시지는 새 프로세스로', async () => {
  process.env.FAKE_IGNORE_INTERRUPT = '1';
  const { child, call } = await startServer('claude');
  delete process.env.FAKE_IGNORE_INTERRUPT;
  const msgs = () => call(`/api/messages?agent=claude&id=${CID}`).then(x => x.body);
  try {
    await call('/api/send', { agent: 'claude', id: CID, prompt: 'HANG 안 멈춤', mode: 'plan' });
    const before = await waitFor(async () => { const j = (await msgs()).job; return j.running ? j : null; });
    await call('/api/stop', { agent: 'claude', id: CID });
    const after = await waitFor(async () => { const j = (await msgs()).job; return !j.running ? j : null; }, 10000);
    assert.strictEqual(after.stopped, true);
    assert.strictEqual(after.error, '');
    await call('/api/send', { agent: 'claude', id: CID, prompt: '다시', mode: 'plan' });
    const j = await waitFor(async () => { const b = await msgs(); return b.items.some(i => i.text === 'echo: 다시 mode=plan') && !b.job.running ? b.job : null; });
    assert.notStrictEqual(j.pid, before.pid);
  } finally { child.kill(); }
});

test('VS Code 에 열린 대화: 새 Claude 를 띄우지 않고 그 세션의 소켓으로 넣는다 (인증 줄 + user 줄)', async () => {
  const net = require('net');
  const crypto = require('crypto');
  const peer = require('../lib/peer');
  // 가짜 "VS Code 의 Claude": 소켓을 열고 등록 파일과 키 파일을 쓴다 (진짜 Claude Code 와 같은 자리)
  const sdir = path.join(tmp, 'claude', 'sessions');
  fs.mkdirSync(sdir, { recursive: true });
  const sock = process.platform === 'win32' ? `\\\\.\\pipe\\cc-msg-${crypto.randomBytes(16).toString('hex')}` : path.join(tmp, 'vs.sock');
  const got = [];
  const srv = net.createServer(c => { let b = ''; c.on('data', d => { b += d; let i; while ((i = b.indexOf('\n')) >= 0) { got.push(JSON.parse(b.slice(0, i))); b = b.slice(i + 1); } }); });
  await new Promise(r => srv.listen(sock, r));
  const pid = process.pid; // 살아 있는 프로세스여야 한다
  fs.writeFileSync(path.join(sdir, `${pid}.json`), JSON.stringify({ pid, sessionId: CID, cwd: work, messagingSocketPath: sock, status: 'idle', name: 'work-ab', entrypoint: 'vscode', kind: 'interactive', startedAt: Date.now() }));
  const hash = peer.hashCandidates(sock)[0];
  fs.writeFileSync(path.join(sdir, `${pid}.${hash}.key`), JSON.stringify({ peerToken: 'ab'.repeat(16) }));
  const { child, call } = await startServer('claude');
  try {
    const list = (await call('/api/sessions')).body.sessions;
    const me = list.find(x => x.id === CID);
    assert.ok(me.live && me.live.pid === pid && me.live.name === 'work-ab', '목록에 VS Code 세션 표시');
    const r = await call('/api/send', { agent: 'claude', id: CID, prompt: '폰에서 보냄', mode: 'plan', opts: { model: 'opus' } });
    assert.strictEqual(r.status, 200);
    assert.strictEqual(r.body.relayed, true);
    assert.strictEqual(r.body.pid, pid);
    await waitFor(async () => got.length >= 2);
    assert.deepStrictEqual(got[0], { type: 'auth', token: 'ab'.repeat(16) });
    assert.strictEqual(got[1].type, 'user');
    assert.strictEqual(got[1].session_id, CID);
    assert.strictEqual(got[1].from, 'agent-chat:phone');
    assert.strictEqual(got[1].priority, 'next');
    assert.strictEqual(peer.unwrap(got[1].message.content), '폰에서 보냄');
    // 우리 쪽 claude 는 뜨지 않았다 (가짜 claude 는 기록에 echo 를 남기는데 없어야 함)
    await new Promise(r => setTimeout(r, 800));
    const m = (await call(`/api/messages?agent=claude&id=${CID}`)).body;
    assert.ok(!m.items.some(i => (i.text || '').includes('echo: 폰에서 보냄')));
    assert.strictEqual(m.job.pid, 0);
    // 기록에 남은 peer 메시지(진짜 Claude Code 가 쓰는 모양)는 내 말풍선으로 보인다
    const { ClaudeParser } = require('../lib/sources');
    const p = new ClaudeParser(true);
    p.feed({ type: 'user', isMeta: true, origin: { kind: 'peer', from: 'agent-chat:phone' }, message: { role: 'user', content: 'Another Claude session sent a message:\n' + peer.wrap('폰에서 보냄') + '\n\nThis came from another Claude session — not typed by your user...' } });
    p.feed({ type: 'user', isMeta: true, origin: { kind: 'peer', from: 'uds:/tmp/cc-socks/7.sock' }, message: { role: 'user', content: 'Another Claude session sent a message:\n작업 현황 알려줘\n\nThis came from...' } });
    const q = new ClaudeParser(true);
    q.feed({ type: 'user', origin: { kind: 'task-notification' }, message: { role: 'user', content: '<task-notification>\n<task-id>a6c4</task-id>\n<status>completed</status>\n<summary>Agent "B3 lifetime experiment R6" is waiting</summary>\n<result>long…</result>\n</task-notification>' } });
    q.feed({ type: 'user', origin: { kind: 'human' }, message: { role: 'user', content: '사람이 친 말' } });
    assert.deepStrictEqual(q.items.map(i => [i.role, i.text]), [['system', '백그라운드 작업 끝남: Agent "B3 lifetime experiment R6" is waiting'], ['user', '사람이 친 말']]);
    assert.deepStrictEqual(p.items.map(i => [i.role, i.text, i.via || '']), [['user', '폰에서 보냄', 'phone'], ['system', '다른 Claude 세션(uds:/tmp/cc-socks/7.sock)의 메시지: 작업 현황 알려줘 This came from...', '']]);
    // 인증 실패 흉내: 서버가 바로 끊으면 오류
    srv.close();
    const bad = net.createServer(c => c.destroy());
    await new Promise(r => bad.listen(sock, r));
    const r2 = await call('/api/send', { agent: 'claude', id: CID, prompt: '다시', mode: 'plan' });
    assert.strictEqual(r2.status, 502);
    bad.close();
  } finally {
    child.kill();
    fs.rmSync(path.join(sdir, `${pid}.json`), { force: true });
    fs.rmSync(path.join(sdir, `${pid}.${hash}.key`), { force: true });
  }
});

test('Codex: VS Code 에 열린 대화면 Codex 의 줄에 넣어 그쪽이 처리, 아니면 줄에서 빼고 따로 실행', async () => {
  const qf = path.join(tmp, 'codex', 'fake_queue.json');
  const rollout = () => { const d = path.join(tmp, 'codex', 'sessions'); const walk = x => fs.readdirSync(x, { withFileTypes: true }).flatMap(e => e.isDirectory() ? walk(path.join(x, e.name)) : [path.join(x, e.name)]); return walk(d).find(f => f.includes(XID)); };
  const readQ = () => { try { return JSON.parse(fs.readFileSync(qf, 'utf8')); } catch { return []; } };
  // 가짜 "VS Code 의 Codex": 이 대화의 줄을 가져가 정상 사용자 메시지로 처리
  let consuming = true;
  const consumer = setInterval(() => {
    if (!consuming) return;
    const q = readQ(); const mine = q.filter(x => x.threadId === XID);
    if (!mine.length) return;
    fs.writeFileSync(qf, JSON.stringify(q.filter(x => x.threadId !== XID)));
    for (const m of mine) {
      const t = m.input.map(i => i.text).join('');
      fs.appendFileSync(rollout(), JSON.stringify({ type: 'response_item', payload: { type: 'message', role: 'user', content: [{ type: 'input_text', text: t }] } }) + '\n' +
        JSON.stringify({ type: 'response_item', payload: { type: 'message', role: 'assistant', content: [{ type: 'output_text', text: 'vscode-codex: ' + t }] } }) + '\n');
    }
  }, 150);
  const { child, call } = await startServer('codex', { codexPickupMs: 2000, codexActiveMs: 4000, codexQuietMs: 2500 });
  const items = () => call(`/api/messages?agent=codex&id=${XID}`).then(x => x.body.items.map(i => i.text));
  try {
    // 1) 열려 있음: 줄에 넣으면 VS Code 쪽이 처리 (우리 codex exec 는 안 돈다)
    let r = await call('/api/send', { agent: 'codex', id: XID, prompt: '폰에서 1', mode: 'read-only' });
    assert.strictEqual(r.status, 200);
    assert.strictEqual(r.body.relayed, true);
    await waitFor(async () => (await items()).includes('vscode-codex: 폰에서 1'));
    assert.ok(!(await items()).some(t => /^codex: 폰에서 1/.test(t)), '따로 실행하지 않음');
    // 2) 아무도 안 가져가고 조용함: 줄에서 빼고 따로 실행
    consuming = false;
    await new Promise(res => setTimeout(res, 4500)); // 기록이 조용해지도록
    r = await call('/api/send', { agent: 'codex', id: XID, prompt: '폰에서 2', mode: 'read-only' });
    assert.strictEqual(r.status, 200);
    assert.ok(!r.body.relayed);
    await waitFor(async () => (await items()).some(t => /^codex: 폰에서 2/.test(t)), 15000);
    assert.strictEqual(readQ().filter(x => x.threadId === XID).length, 0, '줄에서 뺐음 (나중에 두 번 실행 안 됨)');
    // 3) 대화가 바쁨(방금 기록됨): 줄에서 기다렸다가 VS Code 쪽이 처리
    fs.appendFileSync(rollout(), JSON.stringify({ type: 'event_msg', payload: { type: 'task_started' } }) + '\n');
    r = await call('/api/send', { agent: 'codex', id: XID, prompt: '폰에서 3', mode: 'read-only' });
    assert.strictEqual(r.body.waiting, true);
    const j = (await call(`/api/messages?agent=codex&id=${XID}`)).body.job;
    assert.strictEqual(j.relayWaiting, true);
    consuming = true;
    await waitFor(async () => (await items()).includes('vscode-codex: 폰에서 3'), 15000);
    await waitFor(async () => !(await call(`/api/messages?agent=codex&id=${XID}`)).body.job.running, 10000);
    // 4) VS Code 가 대화를 연 채(잠금 파일) 오래 일함: 기록이 조용해도 따로 실행하지 않고 끝까지 기다린다
    //    (따로 돌리면 진짜 Codex 는 "already has an active writer" 로 실패)
    consuming = false;
    const lock = path.join(tmp, 'codex', 'thread-writer-locks', XID + '.lock');
    fs.mkdirSync(path.dirname(lock), { recursive: true }); fs.writeFileSync(lock, '');
    await new Promise(res => setTimeout(res, 4500));
    r = await call('/api/send', { agent: 'codex', id: XID, prompt: '폰에서 4', mode: 'read-only' });
    assert.strictEqual(r.body.waiting, true);
    await new Promise(res => setTimeout(res, 6000)); // codexQuietMs(2.5초) 를 훌쩍 넘김
    assert.ok(!(await items()).some(t => /^codex: 폰에서 4/.test(t)), '잠금이 있으면 따로 실행하지 않음');
    assert.strictEqual(readQ().filter(x => x.threadId === XID).length, 1, '줄에서 기다리는 중');
    consuming = true;
    await waitFor(async () => (await items()).includes('vscode-codex: 폰에서 4'), 15000);
    fs.rmSync(lock, { force: true });
    await waitFor(async () => !(await call(`/api/messages?agent=codex&id=${XID}`)).body.job.running, 10000);
    // 5) 잠금 파일은 없는데 따로 실행이 "already has an active writer" 로 막힘: 오류로 끝내지 않고 줄에 넣어 기다린다
    consuming = false;
    const busyF = path.join(tmp, 'codex', 'fake_writer_busy'); fs.writeFileSync(busyF, '');
    await new Promise(res => setTimeout(res, 4500));
    r = await call('/api/send', { agent: 'codex', id: XID, prompt: '폰에서 5', mode: 'read-only' });
    assert.strictEqual(r.status, 200);
    await waitFor(async () => { const j = (await call(`/api/messages?agent=codex&id=${XID}`)).body.job; return j && j.relayWaiting && readQ().some(x => x.threadId === XID); }, 15000);
    // 기다리는 동안 하나 더 보내도 Codex 의 줄로
    r = await call('/api/send', { agent: 'codex', id: XID, prompt: '폰에서 6', mode: 'read-only' });
    assert.strictEqual(r.status, 200);
    await new Promise(res => setTimeout(res, 5000)); // 조용해도 다시 따로 실행하지 않음
    let j5 = (await call(`/api/messages?agent=codex&id=${XID}`)).body.job;
    assert.ok(!j5.error, '오류로 끝나지 않음: ' + j5.error);
    consuming = true;
    await waitFor(async () => { const t = await items(); return t.includes('vscode-codex: 폰에서 5') && t.includes('vscode-codex: 폰에서 6'); }, 15000);
    fs.rmSync(busyF, { force: true });
  } finally { clearInterval(consumer); child.kill(); }
});

test('Codex 모델 목록은 Codex 가 알려 주는 대로 (새 모델 자동 추가), 강도도 모델별로', async () => {
  const { child, call } = await startServer('codex');
  try {
    const d = (await call('/api/info')).body;
    assert.deepStrictEqual(d.models.codex.slice(0, 2), ['gpt-6.2-astra', 'gpt-6-luna']);
    assert.ok(!d.models.codex.includes('secret'), '숨긴 모델은 빼기');
    assert.deepStrictEqual(d.efforts.codex, ['low', 'medium', 'high', 'max', 'ultra']);
    assert.deepStrictEqual(d.codexModelEfforts['gpt-6.2-astra'], ['low', 'high', 'ultra']);
    const { cleanOpts } = require('../lib/runner');
    assert.deepStrictEqual(cleanOpts('codex', { model: 'gpt-6.2-astra', effort: 'ultra' }), { model: 'gpt-6.2-astra', effort: 'ultra' });
    assert.deepStrictEqual(cleanOpts('codex', { effort: 'x; rm' }), {});
  } finally { child.kill(); }
});

test('첨부: 프로젝트 폴더의 .agent-chat-uploads 에 저장, 보낼 글에 경로, 그 폴더 밖은 거부', async () => {
  const { child, call, port } = await startServer('claude');
  const H = { Authorization: 'Bearer test-token-1234567890' };
  try {
    const png = Buffer.from('89504e470d0a1a0a0000000d49484452', 'hex');
    let r = await fetch(`http://127.0.0.1:${port}/api/upload?agent=claude&id=${CID}&name=${encodeURIComponent('../스샷 1.png')}`, { method: 'POST', headers: H, body: png });
    assert.strictEqual(r.status, 200);
    const up = await r.json();
    assert.strictEqual(up.name, '스샷 1.png');
    assert.strictEqual(up.image, true);
    assert.strictEqual(path.dirname(up.path), path.join(work, '.agent-chat-uploads'));
    assert.match(fs.readFileSync(path.join(work, '.agent-chat-uploads', '.gitignore'), 'utf8'), /^\*$/m);
    // 보기: 첨부 폴더 안 파일만
    r = await fetch(`http://127.0.0.1:${port}/api/file?agent=claude&id=${CID}&path=${encodeURIComponent(up.path)}`, { headers: H });
    assert.strictEqual(r.status, 200);
    assert.strictEqual(r.headers.get('content-type'), 'image/png');
    assert.ok(Buffer.from(await r.arrayBuffer()).equals(png));
    const secret = path.join(work, 'secret.txt'); fs.writeFileSync(secret, 'x');
    r = await fetch(`http://127.0.0.1:${port}/api/file?agent=claude&id=${CID}&path=${encodeURIComponent(secret)}`, { headers: H });
    assert.strictEqual(r.status, 404);
    r = await fetch(`http://127.0.0.1:${port}/api/upload?agent=claude&id=${CID}&name=a.png`, { method: 'POST', body: png });
    assert.strictEqual(r.status, 401);
    // 보내기: 다른 폴더 경로는 거부, 첨부 경로는 글 끝에
    let s = await call('/api/send', { agent: 'claude', id: CID, prompt: '이거 봐', files: [secret], mode: 'plan' });
    assert.strictEqual(s.status, 400);
    s = await call('/api/send', { agent: 'claude', id: CID, prompt: '이거 봐', files: [up.path], mode: 'plan' });
    assert.strictEqual(s.status, 200);
    const want = `이거 봐\n\n[첨부 파일]\n- ${up.path}`;
    await waitFor(async () => { const m = (await call(`/api/messages?agent=claude&id=${CID}`)).body; return m.items.some(i => i.role === 'user' && i.text === want) && !m.job.running; });
  } finally { child.kill(); }
});

test('폰에서 띄워 둔 claude 가 쉬는 중에 VS Code 가 같은 대화를 열면 우리 것을 닫는다 (대화가 갈라지지 않게)', async () => {
  const { spawn } = require('child_process');
  const { child, call } = await startServer('claude', { handoffCheckMs: 300 });
  const sdir = path.join(process.env.CLAUDE_CONFIG_DIR, 'sessions');
  const vs = spawn(process.execPath, ['-e', 'setTimeout(()=>{},20000)']);
  try {
    let r = await call('/api/send', { agent: 'claude', id: CID, prompt: '넘기기 전', mode: 'plan' });
    assert.strictEqual(r.status, 200);
    const j = await waitFor(async () => { const b = (await call(`/api/messages?agent=claude&id=${CID}`)).body; return b.items.some(i => (i.text || '').startsWith('echo: 넘기기 전')) && !b.job.running ? b.job : null; });
    assert.ok(j.pid > 0, '우리 claude 가 켜져 있음');
    fs.mkdirSync(sdir, { recursive: true });
    fs.writeFileSync(path.join(sdir, `${vs.pid}.json`), JSON.stringify({ pid: vs.pid, sessionId: CID, messagingSocketPath: path.join(tmp, 'none.sock'), entrypoint: 'claude-vscode', status: 'idle', startedAt: Date.now() }));
    await waitFor(async () => (await call(`/api/messages?agent=claude&id=${CID}`)).body.job.pid === 0, 5000);
  } finally { vs.kill(); fs.rmSync(path.join(sdir, `${vs.pid}.json`), { force: true }); child.kill(); }
});

test('VS Code 세션 고르기: Agent Chat 이 띄운 claude 는 빼고, VS Code 쪽을 먼저', async () => {
  const { spawn } = require('child_process');
  const peer = require('../lib/peer');
  const sdir = path.join(process.env.CLAUDE_CONFIG_DIR, 'sessions');
  fs.mkdirSync(sdir, { recursive: true });
  const id = 'abcdef01-2345-4678-9abc-def012345678';
  // 살아 있는 pid 두 개: 하나는 "우리가 띄운 claude -p", 하나는 VS Code 확장
  const a = spawn(process.execPath, ['-e', 'setTimeout(()=>{},20000)']);
  const b = spawn(process.execPath, ['-e', 'setTimeout(()=>{},20000)']);
  try {
    const now = Date.now();
    fs.writeFileSync(path.join(sdir, `${a.pid}.json`), JSON.stringify({ pid: a.pid, sessionId: id, messagingSocketPath: 'x', entrypoint: 'sdk-cli', startedAt: now }));
    fs.writeFileSync(path.join(sdir, `${b.pid}.json`), JSON.stringify({ pid: b.pid, sessionId: id, messagingSocketPath: 'y', entrypoint: 'claude-vscode', startedAt: now - 86400000 }));
    assert.strictEqual(peer.findLive(id).pid, b.pid, '더 오래 켜져 있어도 VS Code 쪽');
    assert.strictEqual(peer.findLive(id, new Set([b.pid])).pid, a.pid);
    assert.strictEqual(peer.findLive(id, new Set([a.pid, b.pid])), null, '우리가 띄운 것만 있으면 없음');
  } finally { a.kill(); b.kill(); for (const p of [a.pid, b.pid]) fs.rmSync(path.join(sdir, `${p}.json`), { force: true }); }
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
