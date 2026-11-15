'use strict';
// CI (Windows) 전용: 진짜 VS Code 창을 상대로 "창에 직접 입력" 의 앞 단계를 확인한다. 글은 치지 않는다.
//   1) VS Code 의 자식 프로세스에서 위로 올라가 IDE 와 그 창(제목에 폴더 이름)을 찾는가
//   2) 그 창을 맨 앞으로 가져오는가
//   3) "<IDE>.exe --open-url -- <scheme>://…" 로 열기 요청을 넘긴 뒤에도 창이 맨 앞인가
// 사용: node test/ide-window.win.js <Code.exe 경로>
const { spawn, execFileSync } = require('child_process');
const assert = require('assert');
const fs = require('fs');
const os = require('os');
const path = require('path');
const typer = require('../lib/typer');

const codeExe = process.argv[2];
const sleep = ms => new Promise(r => setTimeout(r, ms));
const ps = cmd => execFileSync('powershell.exe', ['-NoProfile', '-Command', cmd], { encoding: 'utf8' }).trim();

(async () => {
  assert.ok(codeExe && fs.existsSync(codeExe), 'Code.exe 경로가 필요합니다');
  // 예전: <폴더>\resources\app\product.json · 요즘 VS Code: <폴더>\<커밋>\resources\app\product.json
  const root = path.dirname(codeExe);
  console.log('설치 폴더:', fs.readdirSync(root).join(' '));
  const pj = [root, ...fs.readdirSync(root).map(n => path.join(root, n))].map(d => path.join(d, 'resources', 'app', 'product.json')).find(f => fs.existsSync(f));
  assert.ok(pj, 'product.json 을 찾지 못함');
  console.log('product.json:', path.relative(root, pj));
  const product = JSON.parse(fs.readFileSync(pj, 'utf8'));
  console.log('IDE:', product.nameShort, product.version, '· urlProtocol:', product.urlProtocol);
  console.log('주소를 묻지 않고 여는 확장:', JSON.stringify(product.trustedExtensionProtocolHandlers || []));

  const folder = 'ac-ide-' + Math.random().toString(36).slice(2, 8);
  const dir = path.join(os.tmpdir(), folder);
  const data = path.join(os.tmpdir(), folder + '-data');
  fs.mkdirSync(dir, { recursive: true });
  fs.writeFileSync(path.join(dir, 'hello.txt'), 'hello');
  const env = { ...process.env };
  delete env.ELECTRON_RUN_AS_NODE;
  const code = spawn(codeExe, ['--user-data-dir', data, '--extensions-dir', path.join(data, 'ext'), '--disable-workspace-trust', '--skip-welcome', '--skip-release-notes', '--disable-updates', dir], { stdio: 'ignore', env });
  try {
    // 그 대화의 claude 프로세스 대신: VS Code 가 띄운 자식 프로세스 하나
    let child = 0;
    for (let i = 0; i < 60 && !child; i++) {
      await sleep(1000);
      child = Number(ps(`(Get-CimInstance Win32_Process -Filter 'ParentProcessId=${code.pid}' | Select-Object -First 1).ProcessId`)) || 0;
    }
    assert.ok(child, 'VS Code 의 자식 프로세스를 찾지 못함');
    const base = { folder, pid: child };

    let found = null;
    for (let i = 0; i < 60 && !found; i++) { const r = await typer.run({ ...base, dryRun: true }); if (r.ok) found = r; else await sleep(1000); }
    assert.ok(found, '창을 찾지 못함');
    console.log('1) 찾음:', JSON.stringify(found));
    assert.ok(found.window.includes(folder));
    assert.strictEqual(found.ide, product.nameShort);

    const miss = await typer.run({ ...base, folder: 'no-such-folder-xyz', paste: true, submit: true, text: 'x' });
    assert.deepStrictEqual([miss.ok, miss.stage, miss.submitted], [false, 'no-folder-window', false]);

    const front = await typer.run({ ...base });
    console.log('2) 앞으로:', JSON.stringify(front));
    assert.deepStrictEqual([front.ok, front.stage, front.typed, front.submitted], [true, 'done', false, false]);

    const open = await typer.run({ ...base, uri: 'anthropic.claude-code/open?session=11111111-2222-4333-8444-555555555555', settleMs: 3000 });
    console.log('3) 열기 요청 뒤:', JSON.stringify(open));
    assert.deepStrictEqual([open.ok, open.stage, open.typed, open.submitted], [true, 'done', false, false]);
    console.log('OK');
  } finally {
    try { execFileSync('taskkill', ['/pid', String(code.pid), '/T', '/F'], { stdio: 'ignore' }); } catch { /* 이미 끝 */ }
  }
  process.exit(0);
})().catch(e => { console.error(e); process.exit(1); });
