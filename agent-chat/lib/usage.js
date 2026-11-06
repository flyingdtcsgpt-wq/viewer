'use strict';
// 남은 사용량 (구독 요금제의 5시간 · 주간 한도) 모으기
//
//  Claude : 1) 휴대폰에서 시킨 작업이 내보내는 rate_limit_event (utilization 0~1)
//           2) PC 의 Claude 로그인 정보로 사용량 조회 (/api/oauth/usage, Claude Code 의 /usage 와 같은 곳).
//              공식 문서에 없는 주소라 실패하면 조용히 1) 만 쓴다. 1분에 한 번만 묻는다.
//  Codex  : 대화 기록의 token_count 이벤트에 남는 rate_limits (used_percent 0~100) 중 가장 최근 것
const fs = require('fs');
const path = require('path');
const https = require('https');
const { claudeHome } = require('./sources');

const LABEL = { five_hour: '5시간', seven_day: '주간', seven_day_opus: '주간 Opus', seven_day_sonnet: '주간 Sonnet' };
function windowLabel(min) {
  if (min === 300) return '5시간';
  if (min === 10080) return '주간';
  if (!min) return '';
  return min % 1440 === 0 ? `${min / 1440}일` : `${Math.round(min / 60)}시간`;
}
const pct = v => Math.max(0, Math.min(100, Math.round(Number(v) * 10) / 10));
const toMs = t => (t == null || t === '' ? 0 : typeof t === 'number' ? (t < 1e12 ? t * 1000 : t) : Date.parse(t) || 0);

class Usage {
  constructor() {
    this.claude = null; // {windows:[{key,label,pct,resetsAt}], at, source}
    this.codex = null;
    this.lastFetch = 0;
    this.fetching = null;
    this.url = process.env.AGENT_CHAT_CLAUDE_USAGE_URL || 'https://api.anthropic.com/api/oauth/usage';
  }

  /** claude -p --output-format stream-json 의 rate_limit_event.rate_limit_info */
  fromClaudeEvent(info) {
    if (!info || typeof info !== 'object') return;
    const wins = info.unifiedWindows && typeof info.unifiedWindows === 'object' ? info.unifiedWindows : null;
    const list = [];
    if (wins) {
      for (const [k, w] of Object.entries(wins)) {
        if (w && w.utilization != null) list.push({ key: k, label: LABEL[k] || k, pct: pct(w.utilization * 100), resetsAt: toMs(w.resetsAt) });
      }
    }
    if (!list.length) return;
    // 이벤트는 창 하나만 줄 때가 있어서, 이미 아는 다른 창과 합친다
    const old = (this.claude && this.claude.windows) || [];
    const merged = [...list, ...old.filter(o => !list.some(n => n.key === o.key))];
    this.claude = { windows: sortWins(merged), at: Date.now(), source: 'run', status: info.status || '' };
  }

  /** Codex 기록의 rate_limits {primary, secondary} */
  fromCodex(rl, at) {
    if (!rl || typeof rl !== 'object') return;
    if (this.codex && this.codex.at > at) return;
    const list = [];
    for (const k of ['primary', 'secondary']) {
      const w = rl[k];
      if (!w || w.used_percent == null) continue;
      const resetsAt = w.resets_at ? toMs(w.resets_at) : w.resets_in_seconds != null ? at + w.resets_in_seconds * 1000 : 0;
      list.push({ key: k, label: windowLabel(w.window_minutes) || (k === 'primary' ? '짧은 창' : '긴 창'), pct: pct(w.used_percent), resetsAt });
    }
    if (list.length) this.codex = { windows: list, at, source: 'log' };
  }

  credentials() {
    const f = path.join(claudeHome(), '.credentials.json');
    try {
      const j = JSON.parse(fs.readFileSync(f, 'utf8'));
      const o = j.claudeAiOauth || j;
      return o && o.accessToken ? o.accessToken : null;
    } catch { return null; }
  }

  /** 로그인 정보로 사용량 조회 (1분에 한 번) */
  refreshClaude() {
    if (Date.now() - this.lastFetch < 60 * 1000) return this.fetching || Promise.resolve();
    this.lastFetch = Date.now();
    const token = this.credentials();
    if (!token) return Promise.resolve();
    this.fetching = new Promise(resolve => {
      const u = new URL(this.url);
      const mod = u.protocol === 'http:' ? require('http') : https;
      const req = mod.get(u, {
        headers: { Authorization: 'Bearer ' + token, 'anthropic-beta': 'oauth-2025-04-20', 'User-Agent': 'agent-chat', Accept: 'application/json' },
        timeout: 8000,
      }, res => {
        let body = '';
        res.on('data', d => { body += d; });
        res.on('end', () => {
          try {
            if (res.statusCode === 200) this.fromClaudeUsage(JSON.parse(body));
          } catch { /* 형식이 바뀌었으면 무시 */ }
          resolve();
        });
      });
      req.on('timeout', () => req.destroy());
      req.on('error', () => resolve());
    }).finally(() => { this.fetching = null; });
    return this.fetching;
  }

  /** /api/oauth/usage 응답: {five_hour:{utilization(0~100), resets_at}, seven_day:{…}, …} */
  fromClaudeUsage(j) {
    if (!j || typeof j !== 'object') return;
    const list = [];
    for (const [k, w] of Object.entries(j)) {
      if (!w || typeof w !== 'object' || w.utilization == null || !LABEL[k]) continue;
      list.push({ key: k, label: LABEL[k], pct: pct(w.utilization), resetsAt: toMs(w.resets_at || w.resetsAt) });
    }
    if (list.length) this.claude = { windows: sortWins(list), at: Date.now(), source: 'account' };
  }

  snapshot() { return { claude: this.claude, codex: this.codex }; }
}

function sortWins(list) {
  const order = ['five_hour', 'seven_day', 'seven_day_opus', 'seven_day_sonnet'];
  return list.sort((a, b) => (order.indexOf(a.key) + 1 || 99) - (order.indexOf(b.key) + 1 || 99));
}

module.exports = { Usage, windowLabel };
