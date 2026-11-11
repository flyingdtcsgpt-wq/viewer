'use strict';
// Codex 운영 규칙: Codex 가 모든 대화에서 읽는 전역 안내문($CODEX_HOME/AGENTS.md)에
// Agent Chat 이 관리하는 한 덩어리를 넣고 뺀다. 사용자가 켜고 끌 때만 고치고, 표시 밖의 내용은 건드리지 않는다.
//
// 왜: "매시간 보고해" 같은 일을 시키면 Codex 는 감시 스크립트가 매번 `codex exec` 를 새로 띄우게 만들기 쉽다.
// 그러면 실행마다 새 대화가 생겨 한 대화에서 이어 볼 수 없다. 규칙은 그 대신
//   - 사용자에게 보일 보고/다음 할 일: 지금 대화의 줄에 넣기  codex queue --thread "$CODEX_THREAD_ID" --message …
//   - 사용자가 볼 필요 없는 점검(모델 확인 등): 기록을 남기지 않는 codex exec --ephemeral
// 을 쓰게 한다. ($CODEX_THREAD_ID 는 Codex 가 자기 셸 명령에 넣어 주는 지금 대화의 id)
const fs = require('fs');
const path = require('path');
const os = require('os');

const START = '<!-- agent-chat:codex-rules:start (Agent Chat 이 관리. 휴대폰 앱이나 PC 연결 화면에서 끄면 지워짐) -->';
const END = '<!-- agent-chat:codex-rules:end -->';
const RULES = `## 반복 작업 · 정기 보고는 지금 대화 안에서
- 매시간 보고 같은 반복 작업이나 감시 스크립트를 만들 때 \`codex exec\` 로 새 대화를 띄우지 마라. 실행할 때마다 새 대화가 생겨 사용자가 한 대화에서 이어 볼 수 없다.
- 사용자에게 보여야 하는 보고나 다음 할 일은 지금 대화에 메시지로 넣어라:
  \`codex queue --thread "<이 대화 id>" --message "<할 일>"\`
  이 대화 id 는 셸의 \`CODEX_THREAD_ID\` 값이다. 스크립트 · 예약 작업을 만들 때 그 값을 스크립트에 적어 두어라 (나중에 도는 스크립트에는 이 변수가 없을 수 있다).
  넣은 메시지는 지금 하던 일이 끝나면 이 대화에서 이어서 처리된다.
- 사용자가 볼 필요 없는 점검(모델 응답 확인 등)에 Codex 를 따로 돌려야 하면 기록을 남기지 않게 \`codex exec --ephemeral\` 을 써라.
- 이 규칙과 다르게 해야 하면 먼저 사용자에게 물어라.`;

function file() { return path.join(process.env.CODEX_HOME || path.join(os.homedir(), '.codex'), 'AGENTS.md'); }

function read() { try { return fs.readFileSync(file(), 'utf8'); } catch { return ''; } }

function strip(text) {
  const i = text.indexOf(START);
  if (i < 0) return text;
  const j = text.indexOf(END, i);
  const end = j < 0 ? text.length : j + END.length;
  const before = text.slice(0, i).replace(/\n+$/, ''), after = text.slice(end).replace(/^\n+/, '');
  if (!after.trim()) return before ? before + '\n' : '';
  return before ? before + '\n\n' + after : after;
}

function status() { return { installed: read().includes(START), path: file(), rules: RULES }; }

function set(on) {
  const f = file();
  const old = read();
  let text = strip(old);
  if (on) text = (text.trim() ? text.replace(/\n*$/, '\n\n') : '') + `${START}\n${RULES}\n${END}\n`;
  if (text === old) return status();
  fs.mkdirSync(path.dirname(f), { recursive: true });
  const tmp = f + '.agent-chat-tmp';
  fs.writeFileSync(tmp, text);
  fs.renameSync(tmp, f);
  return status();
}

module.exports = { status, set, RULES, START, END };
