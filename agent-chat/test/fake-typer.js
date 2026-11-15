'use strict';
// 테스트용 가짜 "창에 입력하기". $AGENT_CHAT_HOME/fake_typer.json 의 mode 대로 군다:
//   ok     : 입력 성공 → VS Code 의 Claude 가 받은 것처럼 대화 기록에 사용자 말을 덧붙인다
//   locked : 화면 잠김 (Enter 를 누르기 전에 그만둠)
//   lost   : 입력은 했다고 하지만 대화에 나타나지 않음 (VS Code 가 다른 것을 묻고 있었다)
const fs = require('fs');
const path = require('path');
const home = process.env.AGENT_CHAT_HOME;
const read = () => { try { return JSON.parse(fs.readFileSync(path.join(home, 'fake_typer.json'), 'utf8')); } catch { return { mode: 'ok' }; } };
module.exports = {
  supported: () => true,
  async typeIntoClaude(live, text) {
    const c = read();
    fs.appendFileSync(path.join(home, 'fake_typer.log'), JSON.stringify({ pid: live.pid, sessionId: live.sessionId, status: live.status, text, mode: c.mode }) + '\n');
    if (c.mode === 'locked') return { ok: false, stage: 'desktop', error: '화면 잠김', typed: false, submitted: false };
    if (c.mode === 'ok') fs.appendFileSync(c.transcript, JSON.stringify({ type: 'user', cwd: live.cwd, sessionId: live.sessionId, entrypoint: 'claude-vscode', origin: { kind: 'human' }, message: { role: 'user', content: text.replace(/\n/g, '\r\n') } }) + '\n');
    return { ok: true, stage: 'done', typed: true, submitted: true, window: 'main.py - work - Visual Studio Code', ide: 'Code' };
  },
};
