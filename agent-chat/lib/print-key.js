#!/usr/bin/env node
'use strict';
// Claude Code 의 apiKeyHelper 가 실행한다: PC 의 Agent Chat 설정에서 Anthropic API 키를 읽어 출력.
// 인자: 설정 폴더 (없으면 AGENT_CHAT_HOME 또는 ~/.agent-chat)
const fs = require('fs');
const path = require('path');
const os = require('os');
const home = process.argv[2] || process.env.AGENT_CHAT_HOME || path.join(os.homedir(), '.agent-chat');
try {
  const c = JSON.parse(fs.readFileSync(path.join(home, 'config.json'), 'utf8'));
  if (c.anthropicApiKey) { process.stdout.write(String(c.anthropicApiKey)); process.exit(0); }
} catch { /* 아래 */ }
process.stderr.write('Agent Chat: Anthropic API key is not set (open "Agent Chat 휴대폰 연결" on the PC)\n');
process.exit(1);
