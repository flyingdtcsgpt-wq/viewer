#!/usr/bin/env node
'use strict';
// 테스트용 가짜 claude / codex: 표준입력으로 받은 말을 기록 파일에 덧붙이고 대답을 적는다.
const fs = require('fs');
const path = require('path');
const crypto = require('crypto');
const args = process.argv.slice(2);
const kind = process.env.FAKE_KIND;
let input = '';
process.stdin.on('data', d => { input += d; });
process.stdin.on('end', () => {
  if (input.includes('FAIL')) { process.stderr.write('일부러 실패\n'); process.exit(3); }
  if (kind === 'claude') {
    const i = args.indexOf('--resume') >= 0 ? args.indexOf('--resume') : args.indexOf('--session-id');
    const id = args[i + 1];
    const dir = path.join(process.env.CLAUDE_CONFIG_DIR, 'projects', process.cwd().replace(/[^a-zA-Z0-9]/g, '-'));
    fs.mkdirSync(dir, { recursive: true });
    const f = path.join(dir, id + '.jsonl');
    const w = o => fs.appendFileSync(f, JSON.stringify(o) + '\n');
    w({ type: 'user', cwd: process.cwd(), sessionId: id, message: { role: 'user', content: input } });
    w({ type: 'assistant', cwd: process.cwd(), message: { id: 'm' + Date.now(), role: 'assistant', content: [{ type: 'text', text: 'echo: ' + input + ' mode=' + args[args.indexOf('--permission-mode') + 1] }] } });
    process.stdout.write('echo: ' + input);
  } else {
    const resume = args[1] === 'resume';
    const id = resume ? args[args.length - 2] : crypto.randomUUID();
    const dir = path.join(process.env.CODEX_HOME, 'sessions', '2026', '11', '06');
    fs.mkdirSync(dir, { recursive: true });
    const existing = fs.readdirSync(dir).find(n => n.includes(id));
    const f = path.join(dir, existing || `rollout-2026-11-06T00-00-00-${id}.jsonl`);
    const w = o => fs.appendFileSync(f, JSON.stringify(o) + '\n');
    console.log(JSON.stringify({ type: 'thread.started', thread_id: id }));
    if (!existing) w({ type: 'session_meta', payload: { id, cwd: process.cwd(), originator: 'codex_exec' } });
    w({ type: 'response_item', payload: { type: 'message', role: 'user', content: [{ type: 'input_text', text: input }] } });
    w({ type: 'response_item', payload: { type: 'message', role: 'assistant', content: [{ type: 'output_text', text: 'codex: ' + input + ' args=' + args.join(' ') }] } });
  }
});
