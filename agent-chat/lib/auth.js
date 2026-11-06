'use strict';
// 프로젝트(작업 폴더)마다 "구독(OAuth 로그인)" 또는 "API 키" 로 돌린다.
//
//  Claude : API 로 정한 폴더의 .claude/settings.local.json 에 apiKeyHelper 를 넣는다.
//           → 그 폴더의 VS Code 창도, 휴대폰에서 시킨 작업도 API 키로 돈다. 다른 폴더는 그대로 구독.
//           apiKeyHelper 는 키를 직접 적지 않고 print-key.js 를 실행해 PC 설정에서 읽어 온다(프로젝트에 키가 남지 않음).
//  Codex  : 로그인이 PC 에 하나뿐이라 VS Code 창은 나눌 수 없다. 휴대폰에서 시킨 작업에만 CODEX_API_KEY 를 붙인다.
//
// 구독으로 정한 폴더에서 휴대폰이 시킨 작업은 ANTHROPIC_API_KEY / CODEX_API_KEY 를 지워서 확실히 구독으로 돈다.
const fs = require('fs');
const path = require('path');

const isWin = process.platform === 'win32';
const HELPER_MARK = 'print-key.js';

function keyOf(cwd) {
  let p = path.resolve(String(cwd)).replace(/[\\/]+$/, '');
  if (isWin) p = p.toLowerCase();
  return p;
}
const fwd = p => String(p).replace(/\\/g, '/');
function httpError(status, message) { const e = new Error(message); e.status = status; return e; }
function mask(k) { return k ? k.slice(0, 7) + '…' + k.slice(-4) : ''; }

class ProjectAuth {
  /** config: 서버 설정 객체, save(): 설정 파일에 저장, home: 설정 폴더 */
  constructor(config, save, home) {
    this.config = config;
    this.save = save;
    this.home = home;
    if (!config.projectAuth || typeof config.projectAuth !== 'object') config.projectAuth = {};
  }

  mode(cwd) { return cwd && this.config.projectAuth[keyOf(cwd)] === 'api' ? 'api' : 'sub'; }

  keys() {
    return {
      anthropic: !!this.config.anthropicApiKey, openai: !!this.config.openaiApiKey,
      anthropicMasked: mask(this.config.anthropicApiKey), openaiMasked: mask(this.config.openaiApiKey),
    };
  }

  apiProjects() { return Object.keys(this.config.projectAuth).filter(k => this.config.projectAuth[k] === 'api'); }

  /** 휴대폰에서 시키는 작업에 넘길 환경변수 */
  env(agent, cwd) {
    const env = { ...process.env };
    if (this.mode(cwd) === 'api') {
      if (agent === 'claude') {
        if (!this.config.anthropicApiKey) throw httpError(400, '이 프로젝트는 API 로 되어 있는데 Anthropic API 키가 없습니다. PC 의 연결 화면에서 넣으세요');
        env.ANTHROPIC_API_KEY = this.config.anthropicApiKey;
      } else {
        if (!this.config.openaiApiKey) throw httpError(400, '이 프로젝트는 API 로 되어 있는데 OpenAI API 키가 없습니다. PC 의 연결 화면에서 넣으세요');
        env.CODEX_API_KEY = this.config.openaiApiKey;
      }
    } else {
      delete env.ANTHROPIC_API_KEY;
      delete env.CODEX_API_KEY;
    }
    return env;
  }

  helperCommand() {
    return `"${fwd(process.execPath)}" "${fwd(path.join(__dirname, HELPER_MARK))}" "${fwd(this.home)}"`;
  }

  settingsFile(cwd) { return path.join(cwd, '.claude', 'settings.local.json'); }

  /** Claude 의 프로젝트 설정 파일에 apiKeyHelper 를 넣거나 뺀다. 우리가 넣은 것만 뺀다. */
  applyClaude(cwd, mode) {
    const file = this.settingsFile(cwd);
    let obj = {};
    let existed = false;
    try {
      const text = fs.readFileSync(file, 'utf8');
      existed = true;
      obj = text.trim() ? JSON.parse(text) : {};
    } catch (e) {
      if (existed) throw httpError(409, `${file} 를 읽지 못했습니다 (JSON 오류). 직접 고친 뒤 다시 하세요`);
    }
    if (!obj || typeof obj !== 'object' || Array.isArray(obj)) throw httpError(409, `${file} 형식이 이상합니다`);
    const ours = typeof obj.apiKeyHelper === 'string' && obj.apiKeyHelper.includes(HELPER_MARK);
    if (mode === 'api') {
      if (obj.apiKeyHelper && !ours) throw httpError(409, `${file} 에 이미 다른 apiKeyHelper 가 있습니다. 그대로 둡니다`);
      obj.apiKeyHelper = this.helperCommand();
    } else {
      if (!ours) return file;
      delete obj.apiKeyHelper;
      if (!Object.keys(obj).length) { fs.rmSync(file, { force: true }); return file; }
    }
    fs.mkdirSync(path.dirname(file), { recursive: true });
    fs.writeFileSync(file, JSON.stringify(obj, null, 2) + '\n');
    return file;
  }

  set(cwd, mode) {
    if (mode !== 'api' && mode !== 'sub') throw httpError(400, 'mode 는 api 또는 sub');
    if (!cwd || !fs.existsSync(cwd) || !fs.statSync(cwd).isDirectory()) throw httpError(400, `작업 폴더가 없습니다: ${cwd || '(없음)'}`);
    if (mode === 'api' && !this.config.anthropicApiKey && !this.config.openaiApiKey) {
      throw httpError(400, 'API 키가 없습니다. PC 에서 "Agent Chat 휴대폰 연결" 화면을 열어 API 키를 먼저 넣으세요');
    }
    const file = this.applyClaude(cwd, mode);
    if (mode === 'api') this.config.projectAuth[keyOf(cwd)] = 'api';
    else delete this.config.projectAuth[keyOf(cwd)];
    this.save();
    return { mode, claudeSettings: file };
  }

  /** null = 그대로, '' = 지우기 */
  setKeys({ anthropic, openai }) {
    const clean = v => String(v).trim();
    if (anthropic != null) {
      const k = clean(anthropic);
      if (k && !/^sk-ant-/.test(k)) throw httpError(400, 'Anthropic 키는 sk-ant- 로 시작합니다');
      this.config.anthropicApiKey = k;
    }
    if (openai != null) {
      const k = clean(openai);
      if (k && !/^sk-/.test(k)) throw httpError(400, 'OpenAI 키는 sk- 로 시작합니다');
      this.config.openaiApiKey = k;
    }
    this.save();
    return this.keys();
  }

  /** 서버가 켜질 때: 앱 위치가 바뀌었어도 apiKeyHelper 경로를 지금 것으로 맞춘다 */
  refresh() {
    for (const k of this.apiProjects()) {
      try { if (fs.existsSync(k)) this.applyClaude(k, 'api'); } catch { /* 그 프로젝트만 건너뜀 */ }
    }
  }
}

module.exports = { ProjectAuth, keyOf };
