#!/usr/bin/env node
'use strict';
// 테스트용 가짜 claude / codex: 받은 말을 기록 파일에 덧붙이고 대답을 적는다.
//  claude --input-format stream-json : 진짜처럼 표준입력이 열려 있는 동안 메시지를 계속 받는다(한 프로세스).
//  그 밖(codex, 예전 claude -p)       : 표준입력 전체가 메시지 하나.
const fs = require('fs');
const path = require('path');
const crypto = require('crypto');
const args = process.argv.slice(2);
const kind = process.env.FAKE_KIND;
const out = o => process.stdout.write(JSON.stringify(o) + '\n');

function claudeTurn(input, done) {
  if (input.includes('FAIL')) { process.stderr.write('일부러 실패\n'); process.exit(3); }
  const i = args.indexOf('--resume') >= 0 ? args.indexOf('--resume') : args.indexOf('--session-id');
  const id = args[i + 1];
  const dir = path.join(process.env.CLAUDE_CONFIG_DIR, 'projects', process.cwd().replace(/[^a-zA-Z0-9]/g, '-'));
  fs.mkdirSync(dir, { recursive: true });
  const f = path.join(dir, id + '.jsonl');
  const w = o => fs.appendFileSync(f, JSON.stringify(o) + '\n');
  const answer = 'echo: ' + input + ' mode=' + args[args.indexOf('--permission-mode') + 1] + (process.env.ANTHROPIC_API_KEY ? ' auth=api:' + process.env.ANTHROPIC_API_KEY : '') +
    (args.includes('--model') ? ' model=' + args[args.indexOf('--model') + 1] : '') +
    (args.includes('--effort') ? ' effort=' + args[args.indexOf('--effort') + 1] : '') +
    (args.includes('--settings') ? ' think=on' : '') + (process.env.CLAUDE_CODE_DISABLE_THINKING ? ' think=off' : '');
  w({ type: 'user', cwd: process.cwd(), sessionId: id, message: { role: 'user', content: input } });
  out({ type: 'stream_event', event: { type: 'message_start' } });
  // 글자 단위로 흘려보내기 (실시간 표시 시험)
  const parts = answer.match(/.{1,6}/gs);
  const delay = input.includes('HANG') ? 60000 : input.includes('SLOW') ? 400 : 120;
  let k = 0;
  const turn = { stopped: false, timer: null };
  const tick = () => {
    if (turn.stopped) return;
    if (k < parts.length) {
      out({ type: 'stream_event', event: { type: 'content_block_delta', delta: { type: 'text_delta', text: parts[k++] } } });
      turn.timer = setTimeout(tick, delay);
      return;
    }
    const msg = { id: 'm' + Date.now() + Math.random(), role: 'assistant', content: [{ type: 'text', text: answer }] };
    out({ type: 'assistant', message: msg });
    w({ type: 'assistant', cwd: process.cwd(), message: msg });
    out({ type: 'result', subtype: 'success', is_error: false, result: answer, session_id: id });
    done();
  };
  turn.stop = () => { turn.stopped = true; clearTimeout(turn.timer); out({ type: 'result', subtype: 'error_during_execution', is_error: true, result: 'interrupted' }); done(); };
  tick();
  return turn;
}

if (args[0] === 'app-server') {
  // 가짜 Codex app-server: 줄(queue) 요청만 흉내. 줄은 $CODEX_HOME/fake_queue.json
  const qf = path.join(process.env.CODEX_HOME, 'fake_queue.json');
  const readQ = () => { try { return JSON.parse(fs.readFileSync(qf, 'utf8')); } catch { return []; } };
  const writeQ = q => fs.writeFileSync(qf, JSON.stringify(q));
  let buf = '';
  const reply = (id, result, error) => process.stdout.write(JSON.stringify(error ? { jsonrpc: '2.0', id, error } : { jsonrpc: '2.0', id, result }) + '\n');
  process.stdin.on('data', d => {
    buf += d;
    let i;
    while ((i = buf.indexOf('\n')) !== -1) {
      const line = buf.slice(0, i); buf = buf.slice(i + 1);
      let o; try { o = JSON.parse(line); } catch { continue; }
      if (o.id == null) continue;
      const p = o.params || {};
      if (o.method === 'initialize') reply(o.id, { userAgent: 'fake' });
      else if (o.method === 'thread/queue/add') {
        if (!p.clientUserMessageId) { reply(o.id, null, { code: -32600, message: 'missing field `clientUserMessageId`' }); continue; }
        const q = readQ(); const id = crypto.randomUUID();
        q.push({ id, threadId: p.threadId, input: p.input, clientUserMessageId: p.clientUserMessageId }); writeQ(q);
        reply(o.id, {});
      } else if (o.method === 'model/list') {
        reply(o.id, { data: [
          { id: 'gpt-6.2-astra', model: 'gpt-6.2-astra', hidden: false, supportedReasoningEfforts: [{ reasoningEffort: 'low' }, { reasoningEffort: 'high' }, { reasoningEffort: 'ultra' }] },
          { id: 'gpt-6-luna', model: 'gpt-6-luna', hidden: false, supportedReasoningEfforts: [{ reasoningEffort: 'medium' }, { reasoningEffort: 'max' }] },
          { id: 'secret', model: 'secret', hidden: true, supportedReasoningEfforts: [] },
        ], nextCursor: null });
      } else if (o.method === 'account/rateLimits/read') {
        const snap = l => ({ limitId: l, primary: { usedPercent: 96, windowDurationMins: 10080, resetsAt: 1794300000 }, secondary: null });
        reply(o.id, { rateLimits: snap(null), rateLimitsByLimitId: { codex: snap('codex') } });
      } else if (o.method === 'thread/queue/list') reply(o.id, { data: readQ().filter(x => x.threadId === p.threadId), nextCursor: null });
      else if (o.method === 'thread/queue/delete') { const q = readQ(); const n = q.filter(x => x.id !== p.queuedSubmissionId); writeQ(n); reply(o.id, { deleted: n.length !== q.length }); }
      else reply(o.id, null, { code: -32601, message: 'unknown' });
    }
  });
  process.stdin.on('end', () => process.exit(0));
} else if (kind === 'claude' && args.includes('--input-format')) {
  // 한 프로세스에서 메시지를 차례로
  const q = [];
  let cur = null, ended = false, buf = '';
  const next = () => {
    if (cur) return;
    const m = q.shift();
    if (!m) { if (ended) process.exit(0); return; }
    cur = claudeTurn(m, () => { cur = null; next(); });
  };
  process.stdin.on('data', d => {
    buf += d;
    let i;
    while ((i = buf.indexOf('\n')) !== -1) {
      const line = buf.slice(0, i); buf = buf.slice(i + 1);
      let o; try { o = JSON.parse(line); } catch { continue; }
      if (o.type === 'user') { q.push(typeof o.message.content === 'string' ? o.message.content : ''); next(); }
      else if (o.type === 'control_request' && o.request && o.request.subtype === 'interrupt' && cur && !process.env.FAKE_IGNORE_INTERRUPT) cur.stop();
    }
  });
  process.stdin.on('end', () => { ended = true; if (!cur) process.exit(0); });
} else {
  let input = '';
  process.stdin.on('data', d => { input += d; });
  process.stdin.on('end', () => {
    if (kind === 'claude') { claudeTurn(input, () => {}); return; }
    if (input.includes('FAIL')) { process.stderr.write('일부러 실패\n'); process.exit(3); }
    const resume = args[1] === 'resume';
    const id = resume ? args[args.length - 2] : crypto.randomUUID();
    const dir = path.join(process.env.CODEX_HOME, 'sessions', '2026', '11', '06');
    fs.mkdirSync(dir, { recursive: true });
    // 진짜 codex 처럼: 이어서 할 때는 원래 기록 파일(날짜 폴더 어디든)에 덧붙인다
    const findOld = d => { for (const e of fs.readdirSync(d, { withFileTypes: true })) { const p = path.join(d, e.name); if (e.isDirectory()) { const r = findOld(p); if (r) return r; } else if (e.name.includes(id)) return p; } return null; };
    const existing = resume ? findOld(path.join(process.env.CODEX_HOME, 'sessions')) : null;
    const f = existing || path.join(dir, `rollout-2026-11-06T00-00-00-${id}.jsonl`);
    const w = o => fs.appendFileSync(f, JSON.stringify(o) + '\n');
    console.log(JSON.stringify({ type: 'thread.started', thread_id: id }));
    if (!existing) w({ type: 'session_meta', payload: { id, cwd: process.cwd(), originator: 'codex_exec' } });
    w({ type: 'response_item', payload: { type: 'message', role: 'user', content: [{ type: 'input_text', text: input }] } });
    w({ type: 'response_item', payload: { type: 'message', role: 'assistant', content: [{ type: 'output_text', text: 'codex: ' + input + ' args=' + args.join(' ') + (process.env.CODEX_API_KEY ? ' auth=api:' + process.env.CODEX_API_KEY : '') }] } });
  });
}
