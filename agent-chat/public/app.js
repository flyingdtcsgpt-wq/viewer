'use strict';
// Agent Chat 휴대폰 화면: 대화 목록 → 채팅. 서버는 PC 의 기록 파일을 읽어 준다.
(() => {
  const $ = id => document.getElementById(id);
  const store = {
    get(k, d) { try { const v = localStorage.getItem(k); return v == null ? d : v; } catch { return d; } },
    set(k, v) { try { localStorage.setItem(k, v); } catch { /* 저장 불가 */ } },
  };
  const MODE_LABEL = {
    acceptEdits: '편집 허용', auto: '자동', bypassPermissions: '전부 허용', plan: '계획만',
    'workspace-write': '폴더 쓰기', 'read-only': '읽기만', 'danger-full-access': '전부 허용',
  };
  let token = store.get('ac_token', '');
  let info = {
    modes: { claude: ['acceptEdits', 'auto', 'bypassPermissions', 'plan'], codex: ['workspace-write', 'read-only', 'danger-full-access'] },
    models: { claude: ['fable', 'opus', 'sonnet', 'haiku'], codex: [] },
    efforts: { claude: ['low', 'medium', 'high', 'xhigh', 'max'], codex: ['minimal', 'low', 'medium', 'high', 'xhigh'] },
  };
  let filter = store.get('ac_filter', 'all');
  let hideTools = store.get('ac_hideTools', '0') === '1';
  let timer = null;

  // 주소의 #t=토큰 을 받아 저장하고 주소에서는 지운다
  const hm = location.hash.match(/(?:^#|&)t=([^&]+)/);
  if (hm) {
    token = decodeURIComponent(hm[1]); store.set('ac_token', token);
    // 앱의 알림을 눌러 들어온 경우 &go=#/s/... 로 그 대화를 바로 연다
    const go = location.hash.match(/&go=([^&]+)/);
    history.replaceState(null, '', location.pathname + (go ? decodeURIComponent(go[1]) : ''));
  }
  // 안드로이드 앱 안에서 열렸으면 앱 기능(작업 끝 알림 · PC 바꾸기)을 쓴다
  const native = window.AgentChatApp || null;
  function watchInApp(c, title) {
    if (!native || !c) return;
    try { native.watch(c.agent, c.id, title || $('chatTitle').textContent || ''); } catch { /* 앱이 아님 */ }
  }

  async function api(path, body) {
    const res = await fetch(path, {
      method: body ? 'POST' : 'GET',
      headers: { Authorization: 'Bearer ' + token, ...(body ? { 'Content-Type': 'application/json' } : {}) },
      body: body ? JSON.stringify(body) : undefined,
    });
    let data = {};
    try { data = await res.json(); } catch { /* 빈 응답 */ }
    if (res.status === 401) { showLogin('토큰이 맞지 않습니다'); throw new Error('401'); }
    if (!res.ok) throw new Error(data.error || ('오류 ' + res.status));
    return data;
  }

  function show(id) {
    for (const v of ['login', 'list', 'chat']) $(v).hidden = v !== id;
    // 사용량 막대를 지금 화면의 맨 아래(대화 화면은 입력창 위)로 옮긴다
    const bar = $('usageBar');
    if (id === 'chat') $('chat').insertBefore(bar, $('composer'));
    else if (id === 'list') $('list').append(bar);
    bar.hidden = id === 'login';
    if (id !== 'login') loadUsage();
  }

  // ---------- 남은 사용량 ----------
  let usageAt = 0;
  function remain(p) { return Math.max(0, Math.round(100 - p)); }
  function lvl(r) { return r <= 10 ? 'bad' : r <= 30 ? 'warn' : 'ok'; }
  function when(ms) {
    if (!ms) return '';
    const d = new Date(ms), now = new Date();
    const hm = d.toLocaleTimeString('ko-KR', { hour: '2-digit', minute: '2-digit', hour12: false });
    if (d.toDateString() === now.toDateString()) return '오늘 ' + hm;
    return `${d.getMonth() + 1}/${d.getDate()}(${'일월화수목금토'[d.getDay()]}) ${hm}`;
  }
  function renderUsage(u) {
    const line = $('usageLine'), more = $('usageMore');
    line.replaceChildren(); more.replaceChildren();
    const add = (name, info) => {
      const g = el('span', 'ugroup');
      g.append(el('span', 'uname', name));
      if (!info || !info.windows || !info.windows.length) { g.append(el('span', 'unone', '정보 없음')); line.append(g); return; }
      for (const w of info.windows.slice(0, 2)) {
        const r = remain(w.pct);
        const s = el('span', 'uwin');
        s.append(el('span', '', w.label + ' '), el('b', 'u-' + lvl(r), r + '%'));
        g.append(s);
      }
      line.append(g);
      const d = el('div', 'udetail');
      d.append(el('b', '', name + ' '), document.createTextNode(info.windows.map(w => `${w.label} ${Math.round(w.pct)}% 사용${w.resetsAt ? ' · ' + when(w.resetsAt) + ' 초기화' : ''}`).join('  /  ')));
      const age = Math.round((Date.now() - info.at) / 60000);
      d.append(el('span', 'uage', `  (${age < 1 ? '방금' : age + '분 전'} 기준${info.source === 'log' ? ', 마지막 Codex 작업' : info.source === 'run' ? ', 마지막 작업' : ''})`));
      more.append(d);
    };
    line.append(el('span', 'ulabel', '남은 사용량'));
    add('Claude', u.claude);
    add('Codex', u.codex);
  }
  async function loadUsage(force) {
    if (!force && Date.now() - usageAt < 30000) return;
    usageAt = Date.now();
    try { renderUsage(await api('/api/usage')); } catch (e) { if (e.message !== '401') $('usageLine').textContent = '사용량을 못 읽었습니다'; }
  }
  $('usageBar').onclick = () => { $('usageMore').hidden = !$('usageMore').hidden; };
  setInterval(() => { if (!document.hidden && token) loadUsage(); }, 60000);
  function showLogin(msg) { stopTimer(); show('login'); $('loginErr').textContent = msg || ''; }
  $('tokenSave').onclick = () => { token = $('tokenInput').value.trim(); store.set('ac_token', token); route(); };
  $('codeSave').onclick = async () => {
    const code = $('codeInput').value.replace(/\D/g, '');
    if (code.length !== 6) { $('loginErr').textContent = '숫자 6자리를 넣으세요'; return; }
    try {
      const r = await fetch('/api/pair', { method: 'POST', headers: { 'Content-Type': 'application/json' }, body: JSON.stringify({ code }) });
      const d = await r.json().catch(() => ({}));
      if (!r.ok) { $('loginErr').textContent = d.error || ('오류 ' + r.status); return; }
      token = d.token; store.set('ac_token', token); $('codeInput').value = ''; route();
    } catch (e) { $('loginErr').textContent = e.message; }
  };

  function stopTimer() { if (timer) { clearTimeout(timer); timer = null; } }
  function schedule(fn, ms) { stopTimer(); timer = setTimeout(fn, ms); }
  document.addEventListener('visibilitychange', () => { if (!document.hidden) route(true); });

  function ago(ms) {
    const s = (Date.now() - ms) / 1000;
    if (s < 60) return '방금';
    if (s < 3600) return Math.floor(s / 60) + '분 전';
    if (s < 86400) return Math.floor(s / 3600) + '시간 전';
    const d = new Date(ms);
    return (d.getMonth() + 1) + '/' + d.getDate();
  }
  function el(tag, cls, text) { const e = document.createElement(tag); if (cls) e.className = cls; if (text != null) e.textContent = text; return e; }

  // ---------- 목록 ----------
  let sessions = [];
  async function loadList(again) {
    try {
      const d = await api('/api/sessions');
      sessions = d.sessions;
      renderList();
    } catch (e) {
      if (e.message === '401') return;
      if (!sessions.length) $('sessions').replaceChildren(el('div', 'empty', '서버에 연결하지 못했습니다\n' + e.message));
    }
    if (again && location.hash.startsWith('#/s/') === false) schedule(() => loadList(true), 5000);
  }
  function renderList() {
    const box = $('sessions');
    const list = sessions.filter(s => filter === 'all' || s.agent === filter);
    if (!list.length) { box.replaceChildren(el('div', 'empty', '대화가 없습니다. ＋ 로 새로 시작하세요.')); return; }
    box.replaceChildren(...list.map(s => {
      const b = el('button', 'sess');
      const top = el('div', 'top');
      top.append(el('span', 'badge ' + s.agent, s.agent === 'claude' ? 'Claude' : 'Codex'), el('span', '', s.project || ''));
      if (s.auth === 'api') top.append(el('span', 'badge api', 'API'));
      if (s.live) top.append(el('span', 'badge vsc', 'VS Code'));
      top.append(el('span', 'grow'));
      if (s.busy ?? (s.running || s.active)) top.append(el('span', 'dot'));
      top.append(el('span', '', ago(s.mtime)));
      b.append(top, el('div', 'name', s.title), el('div', 'pv', (s.lastRole === 'user' ? '나: ' : '') + (s.preview || '')));
      b.onclick = () => { location.hash = `#/s/${s.agent}/${s.id}`; };
      return b;
    }));
  }
  if (native) { $('pcBtn').hidden = false; $('pcBtn').onclick = () => native.servers(); }
  for (const c of $('filters').children) {
    c.classList.toggle('on', c.dataset.f === filter);
    c.onclick = () => {
      filter = c.dataset.f; store.set('ac_filter', filter);
      for (const x of $('filters').children) x.classList.toggle('on', x === c);
      renderList();
    };
  }

  // ---------- 채팅 ----------
  let cur = null; // {agent, id, rendered: Map(n→{json, el}), limit, pending, job, ctrl}
  // ---------- 보낼 때 설정: 권한 · 모델 · 추론 강도 · 생각 ----------
  const LABEL = {
    low: '낮음', medium: '보통', high: '높음', xhigh: '매우 높음', max: '최대', minimal: '최소',
    fable: 'Fable', opus: 'Opus', sonnet: 'Sonnet', haiku: 'Haiku',
  };
  function getOpts(agent) {
    try { const o = JSON.parse(store.get('ac_opts_' + agent, '{}')); return o && typeof o === 'object' ? o : {}; } catch { return {}; }
  }
  function setOpts(agent, o) { store.set('ac_opts_' + agent, JSON.stringify(o)); }
  function shortModel(m) { return String(m || '').replace(/^claude-/, ''); }
  function optSummary(agent, withMode) {
    const o = getOpts(agent);
    const parts = [];
    if (withMode) parts.push(MODE_LABEL[store.get('ac_mode_' + agent, (info.modes[agent] || [])[0])] || '');
    parts.push(o.model ? (LABEL[o.model] || shortModel(o.model)) : '기본 모델');
    if (o.effort) parts.push(LABEL[o.effort] || o.effort);
    if (o.thinking) parts.push(o.thinking === 'on' ? '생각 켬' : '생각 끔');
    return parts.filter(Boolean).join(' · ');
  }
  function showOptSummary() {
    if (cur) $('optSum').textContent = optSummary(cur.agent, true);
    $('newOptSum').textContent = optSummary(newAgent, false);
  }
  let optCtx = null; // {agent, withMode}
  function openOpts(agent, withMode) {
    optCtx = { agent, withMode };
    const o = getOpts(agent);
    $('optTitle').textContent = (agent === 'claude' ? 'Claude' : 'Codex') + ' · 보낼 때 설정';
    $('optModeRow').hidden = !withMode;
    if (withMode) fillModes($('optMode'), agent);
    const models = (info.models && info.models[agent]) || [];
    const sel = $('optModel');
    const opts = [['', '기본 (PC 설정)'], ...models.map(m => [m, LABEL[m] ? `${LABEL[m]} (최신)` : m])];
    if (o.model && !models.includes(o.model)) opts.push([o.model, o.model]);
    opts.push(['__custom', '직접 입력…']);
    sel.replaceChildren(...opts.map(([v, t]) => { const x = el('option', '', t); x.value = v; return x; }));
    sel.value = o.model || '';
    $('optModelCustom').hidden = true; $('optModelCustom').value = '';
    const efforts = (info.efforts && info.efforts[agent]) || [];
    $('optEffort').replaceChildren(...[['', '기본 (PC 설정)'], ...efforts.map(e => [e, `${LABEL[e] || e} (${e})`])].map(([v, t]) => { const x = el('option', '', t); x.value = v; return x; }));
    $('optEffort').value = o.effort || '';
    $('optThinkRow').hidden = agent !== 'claude';
    $('optThinking').value = o.thinking || '';
    let now = cur && cur.agent === agent && cur.model ? `지금 이 대화가 쓰는 모델: ${cur.model}${cur.effort ? ' · 추론 ' + (LABEL[cur.effort] || cur.effort) : ''}` : '';
    if (cur && cur.agent === agent && cur.live) now = '이 대화는 VS Code 에 열려 있어 그쪽 Claude 가 처리합니다. 모델 · 추론 · 생각 · 권한은 VS Code 의 설정을 따르고, 여기 고른 값은 VS Code 를 닫았을 때만 쓰입니다.' + (now ? '\n' + now : '');
    $('optNow').textContent = now; $('optNow').hidden = !now;
    $('optSheet').hidden = false;
  }
  $('optModel').onchange = () => { const c = $('optModel').value === '__custom'; $('optModelCustom').hidden = !c; if (c) $('optModelCustom').focus(); };
  $('optReset').onclick = () => { $('optModel').value = ''; $('optModelCustom').hidden = true; $('optEffort').value = ''; $('optThinking').value = ''; };
  $('optSheet').onclick = e => { if (e.target === $('optSheet')) $('optForm').requestSubmit(); };
  $('optForm').onsubmit = e => {
    e.preventDefault();
    if (!optCtx) return;
    const { agent, withMode } = optCtx;
    let model = $('optModel').value;
    if (model === '__custom') model = $('optModelCustom').value.trim();
    if (model && !/^[A-Za-z0-9][A-Za-z0-9._:\-\[\]]{0,79}$/.test(model)) { alert('모델 이름에 쓸 수 없는 글자가 있습니다'); return; }
    const o = {};
    if (model) o.model = model;
    if ($('optEffort').value) o.effort = $('optEffort').value;
    if (agent === 'claude' && $('optThinking').value) o.thinking = $('optThinking').value;
    setOpts(agent, o);
    if (withMode) { store.set('ac_mode_' + agent, $('optMode').value); $('mode').value = $('optMode').value; }
    $('optSheet').hidden = true;
    showOptSummary();
  };
  $('optBtn').onclick = () => cur && openOpts(cur.agent, true);
  $('newOptBtn').onclick = () => openOpts(newAgent, false);

  function fillModes(sel, agent) {
    const modes = info.modes[agent] || [];
    const saved = store.get('ac_mode_' + agent, modes[0]);
    sel.replaceChildren(...modes.map(m => { const o = el('option', '', MODE_LABEL[m] || m); o.value = m; return o; }));
    sel.value = modes.includes(saved) ? saved : modes[0];
  }
  function closeChat() { if (cur && cur.ctrl) cur.ctrl.abort(); cur = null; }
  function openChat(agent, id) {
    closeChat();
    cur = { agent, id, rendered: new Map(), limit: 300, pending: [], first: true, job: null, active: false, from: -1, epoch: -1 };
    show('chat');
    $('msgs').replaceChildren();
    $('msgs').classList.toggle('hide-tools', hideTools);
    $('toolsToggle').classList.toggle('on', !hideTools);
    $('chatTitle').textContent = '불러오는 중…';
    $('chatSub').textContent = agent === 'claude' ? 'Claude' : 'Codex';
    fillModes($('mode'), agent);
    cur.model = ''; cur.effort = '';
    showOptSummary();
    $('status').hidden = true;
    $('authChip').hidden = true;
    connect();
  }
  // 프로젝트별 구독 / API
  function showAuth(c) {
    const b = $('authChip');
    b.hidden = !c.cwd;
    b.textContent = c.auth === 'api' ? 'API' : '구독';
    b.classList.toggle('api', c.auth === 'api');
  }
  $('authChip').onclick = async () => {
    const c = cur;
    if (!c || !c.cwd) return;
    const next = c.auth === 'api' ? 'sub' : 'api';
    const name = c.cwd.split(/[\\/]/).filter(Boolean).pop();
    const msg = `"${name}" 프로젝트를 ${next === 'api' ? 'API 키' : '구독(OAuth 로그인)'} 로 바꿀까요?\n\n` +
      '• Claude: 이 폴더의 VS Code 창도 같이 바뀝니다 (VS Code 에서는 새 대화부터 적용)\n' +
      '• Codex: 휴대폰에서 시키는 작업만 바뀝니다 (VS Code 의 Codex 는 PC 로그인 그대로)';
    if (!confirm(msg)) return;
    try {
      const r = await api('/api/project-auth', { cwd: c.cwd, mode: next });
      c.auth = r.mode; showAuth(c);
    } catch (e) { if (e.message !== '401') alert(e.message); }
  };
  $('toolsToggle').onclick = () => {
    hideTools = !hideTools; store.set('ac_hideTools', hideTools ? '1' : '0');
    $('msgs').classList.toggle('hide-tools', hideTools);
    $('toolsToggle').classList.toggle('on', !hideTools);
  };
  $('mode').onchange = () => cur && store.set('ac_mode_' + cur.agent, $('mode').value);
  $('back').onclick = () => { location.hash = '#/'; };

  // 실시간 연결: 서버가 바뀐 것만 바로바로 보내 준다. 끊기면 2초 뒤 다시.
  async function connect() {
    const c = cur;
    if (!c) return;
    if (c.ctrl) c.ctrl.abort();
    const ctrl = new AbortController();
    c.ctrl = ctrl;
    try {
      const res = await fetch(`/api/stream?agent=${c.agent}&id=${encodeURIComponent(c.id)}&limit=${c.limit}`, {
        headers: { Authorization: 'Bearer ' + token }, signal: ctrl.signal, cache: 'no-store',
      });
      if (res.status === 401) { showLogin('토큰이 맞지 않습니다'); return; }
      if (!res.ok) throw new Error('오류 ' + res.status);
      c.from = -1; // 다시 연결하면 처음부터 받는다
      if (c.offline) { c.offline = false; updateStatus(); }
      const reader = res.body.getReader();
      const dec = new TextDecoder();
      let buf = '';
      for (;;) {
        const { value, done } = await reader.read();
        if (done) break;
        buf += dec.decode(value, { stream: true });
        let i;
        while ((i = buf.indexOf('\n\n')) !== -1) {
          const block = buf.slice(0, i); buf = buf.slice(i + 2);
          let ev = 'message', data = '';
          for (const line of block.split('\n')) {
            if (line.startsWith('event: ')) ev = line.slice(7);
            else if (line.startsWith('data: ')) data += line.slice(6);
          }
          if (!data || c !== cur) continue;
          const d = JSON.parse(data);
          if (ev === 'msgs') onMsgs(d);
          else if (ev === 'job') { c.job = d; updateStatus(); updateSub(c); }
          else if (ev === 'live') { c.live = d; updateStatus(); updateSub(c); }
        }
      }
    } catch (e) {
      if (ctrl.signal.aborted || c !== cur) return;
      c.offline = true; updateStatus();
    }
    if (c === cur && !ctrl.signal.aborted) setTimeout(() => { if (c === cur && c.ctrl === ctrl) connect(); }, 2000);
  }

  function onMsgs(d) {
    const c = cur;
    const box = $('msgs');
    const nearBottom = c.first || box.scrollHeight - box.scrollTop - box.clientHeight < 150;
    if (d.title) $('chatTitle').textContent = d.title;
    // 폰 화면은 좁으니 폴더 이름만 (전체 경로는 길게 누르면 보이는 title 로)
    if (d.model) { c.model = d.model; c.effort = d.effort || ''; }
    if (d.cwd) { c.cwdShown = d.cwd; updateSub(c); }
    c.active = d.active;
    if (d.cwd) { c.cwd = d.cwd; c.auth = d.auth || 'sub'; showAuth(c); }
    if (d.full) {
      // 다시 받은 전체 목록: 이미 그린 것은 그대로 두고 바뀐 것만 고친다
      if (d.epoch !== c.epoch || d.from !== c.from) { c.rendered.clear(); box.replaceChildren(); }
      c.epoch = d.epoch; c.from = d.from;
      const om = box.querySelector('.more'); if (om) om.remove();
      if (d.from > 0) {
        const more = el('button', 'more', `이전 메시지 ${d.from}개 더 보기`);
        more.onclick = () => { c.limit += 300; connect(); };
        box.prepend(more);
      }
    }
    const liveEl = $('live');
    for (const it of d.items || []) {
      const j = JSON.stringify(it);
      const old = c.rendered.get(it.n);
      if (old && old.json === j) continue;
      const node = renderItem(it, old && old.el);
      if (old) old.el.replaceWith(node);
      else if (liveEl && liveEl.parentNode === box) box.insertBefore(node, liveEl);
      else box.append(node);
      c.rendered.set(it.n, { json: j, el: node });
      // 보낸 말이 기록에 나타나면 임시 말풍선을 지운다
      if (it.role === 'user') {
        const k = c.pending.findIndex(p => p.text.trim() === it.text.trim());
        if (k >= 0) { c.pending[k].el.remove(); c.pending.splice(k, 1); }
      }
    }
    for (const p of c.pending) box.append(p.el);
    updateStatus(nearBottom);
    c.first = false;
  }

  // 머리말 아래 줄: 에이전트 · 폴더 · 모델 · (이 대화의 Claude 가 켜져 있으면) 연결 유지
  function updateSub(c) {
    if (!c || !c.cwdShown) return;
    const parts = [c.agent === 'claude' ? 'Claude' : 'Codex', c.cwdShown.split(/[\\/]/).filter(Boolean).pop()];
    if (c.model) parts.push(shortModel(c.model));
    if (c.live) parts.push('● VS Code 연결');
    else if (c.job && c.job.pid) parts.push('● 연결 유지');
    $('chatSub').textContent = parts.join(' · ');
    $('chatSub').title = c.cwdShown + (c.job && c.job.pid ? `\n이 대화의 Claude 프로세스(${c.job.pid})가 켜져 있어 다음 메시지도 같은 프로세스로 이어집니다. 30분 동안 조용하면 닫힙니다.` : '');
  }

  // 아래 상태 줄 + 지금 쓰고 있는 답변(실시간 말풍선)
  function updateStatus(stick) {
    const c = cur;
    if (!c) return;
    const box = $('msgs');
    if (stick === undefined) stick = box.scrollHeight - box.scrollTop - box.clientHeight < 150;
    const j = c.job;
    if (c.wasRunning && !(j && j.running)) setTimeout(() => loadUsage(true), 1500);
    c.wasRunning = !!(j && j.running);
    const busyNow = !!((j && j.running) || (c.active && !(j && j.endedAt)));
    if (busyNow && !c.watched && !document.hidden) { c.watched = true; watchInApp(c); }
    if (!busyNow) c.watched = false;
    let live = $('live');
    if (j && j.running && j.live) {
      if (!live) { live = el('div', 'msg assistant live'); live.id = 'live'; live.append(el('div', 'bubble')); }
      const h = md(j.live), caret = '<span class="caret"></span>';
      live.firstChild.innerHTML = h.endsWith('</p>') ? h.slice(0, -4) + caret + '</p>' : h + caret;
      box.append(live);
    } else if (live) live.remove();
    for (const p of c.pending) box.append(p.el);

    if (c.offline) setStatus('연결이 끊겼습니다. 다시 연결하는 중…', true);
    else if (c.live && !(j && j.running)) {
      if (j && j.error) setStatus(j.error, true);
      else if (c.live.status === 'busy') setStatus('VS Code 의 Claude 가 작업 중 (이 창에서 보낸 말도 그쪽으로 들어갑니다)', false);
      else $('status').hidden = true;
    } else if (j && j.running) {
      let t = j.tool ? '실행 중: ' + j.tool : j.live ? '답하는 중…' : '생각하는 중…';
      if (j.queued) t += ` (대기 ${j.queued}개)`;
      setStatus(t, false, true);
    } else if (j && j.error) setStatus(j.error, true);
    else if (c.active && !(j && j.endedAt)) setStatus('PC 에서 작업 중인 것 같습니다 (VS Code)', false);
    else $('status').hidden = true;
    if (stick) box.scrollTop = box.scrollHeight;
  }

  function setStatus(text, isErr, canStop) {
    const s = $('status');
    s.hidden = false;
    s.className = 'status' + (isErr ? ' error' : '');
    s.replaceChildren();
    if (!isErr) s.append(el('span', 'dot'));
    s.append(el('span', 'stxt', text));
    if (canStop) {
      const b = el('button', '', '중지');
      b.onclick = async () => { try { await api('/api/stop', { agent: cur.agent, id: cur.id }); } catch (e) { alert(e.message); } };
      s.append(b);
    }
  }

  function renderItem(it, old) {
    if (it.role === 'tool') {
      const wrap = el('div', 'tool' + (it.status === 'error' ? ' error' : ''));
      const det = el('details');
      if (old) { const od = old.querySelector('details'); if (od && od.open) det.open = true; }
      const sum = el('summary');
      sum.append(el('span', 'tn', it.name || 'tool'), el('span', 'ts', it.summary || ''),
        el('span', 'st', it.status === 'run' ? '…' : it.status === 'error' ? '✕' : '✓'));
      det.append(sum);
      if (it.input) det.append(el('pre', '', it.input));
      if (it.output) det.append(el('pre', '', it.output));
      wrap.append(det);
      return wrap;
    }
    const row = el('div', 'msg ' + it.role + (it.error ? ' error' : ''));
    const b = el('div', 'bubble');
    if (it.role === 'assistant') b.innerHTML = md(it.text);
    else b.textContent = it.text;
    row.append(b);
    return row;
  }

  // ---------- 보내기 (작업 중이어도 보내면 줄 세웠다가 이어서) ----------
  const input = $('input');
  function grow() { input.style.height = 'auto'; input.style.height = Math.min(input.scrollHeight, 160) + 'px'; }
  input.addEventListener('input', grow);
  input.addEventListener('keydown', e => {
    // PC 키보드: Enter 보내기, Shift+Enter 줄바꿈. 휴대폰은 보내기 버튼.
    if (e.key === 'Enter' && !e.shiftKey && !e.isComposing && matchMedia('(pointer: fine)').matches) { e.preventDefault(); $('composer').requestSubmit(); }
  });
  $('composer').onsubmit = async e => {
    e.preventDefault();
    const text = input.value.trim();
    if (!text || !cur) return;
    const c = cur;
    $('sendBtn').disabled = true;
    try {
      const r = await api('/api/send', { agent: c.agent, id: c.id, prompt: text, mode: $('mode').value, opts: getOpts(c.agent) });
      input.value = ''; grow();
      const p = el('div', 'msg user pending'); p.append(el('div', 'bubble', text));
      if (r.queued) p.firstChild.append(el('div', 'qtag', '대기 중'));
      if (r.relayed) p.firstChild.append(el('div', 'qtag', 'VS Code 로 전달됨'));
      c.pending.push({ el: p, text });
      c.watched = true; watchInApp(c);
      $('msgs').append(p);
      $('msgs').scrollTop = $('msgs').scrollHeight;
    } catch (err) {
      if (err.message !== '401') setStatus(err.message, true);
    } finally { $('sendBtn').disabled = false; }
  };

  // ---------- 새 대화 ----------
  let newAgent = store.get('ac_newAgent', 'claude');
  function setNewAgent(a) {
    newAgent = a; store.set('ac_newAgent', a);
    for (const b of $('newAgent').children) b.classList.toggle('on', b.dataset.a === a);
    fillModes($('newMode'), a);
    showOptSummary();
  }
  for (const b of $('newAgent').children) b.onclick = () => setNewAgent(b.dataset.a);
  $('newMode').onchange = () => store.set('ac_mode_' + newAgent, $('newMode').value);
  $('newBtn').onclick = async () => {
    $('sheet').hidden = false; $('newErr').textContent = '';
    setNewAgent(newAgent);
    const sel = $('newProject');
    sel.replaceChildren(el('option', '', '불러오는 중…'));
    try {
      const d = await api('/api/projects');
      const last = store.get('ac_lastProject', '');
      projAuth = new Map(d.projects.map(p => [p.path, p.auth || 'sub']));
      sel.replaceChildren(...d.projects.map(p => { const o = el('option', '', (p.auth === 'api' ? '[API] ' : '') + p.name + '  —  ' + p.path); o.value = p.path; return o; }));
      if (!d.projects.length) sel.replaceChildren(el('option', '', '(최근 폴더 없음: 아래에 경로 입력)'));
      if (d.projects.some(p => p.path === last)) sel.value = last;
      $('newAuth').value = projAuth.get(sel.value) || 'sub';
    } catch (e) { $('newErr').textContent = e.message; }
    $('newPrompt').focus();
  };
  let projAuth = new Map();
  $('newProject').onchange = () => { $('newAuth').value = projAuth.get($('newProject').value) || 'sub'; };
  $('newPath').oninput = () => { const v = $('newPath').value.trim(); $('newAuth').value = projAuth.get(v || $('newProject').value) || 'sub'; };
  $('newCancel').onclick = () => { $('sheet').hidden = true; };
  $('sheet').onclick = e => { if (e.target === $('sheet')) $('sheet').hidden = true; };
  $('newForm').onsubmit = async e => {
    e.preventDefault();
    const cwd = $('newPath').value.trim() || $('newProject').value;
    const prompt = $('newPrompt').value.trim();
    if (!prompt) { $('newErr').textContent = '할 일을 적어 주세요'; return; }
    const btn = e.submitter || $('newForm').querySelector('.primary');
    btn.disabled = true; $('newErr').textContent = '시작하는 중…';
    try {
      const r = await api('/api/new', { agent: newAgent, cwd, prompt, mode: $('newMode').value, auth: $('newAuth').value, opts: getOpts(newAgent) });
      store.set('ac_lastProject', cwd);
      $('newPrompt').value = ''; $('newPath').value = '';
      $('sheet').hidden = true;
      location.hash = `#/s/${newAgent}/${r.id}`;
    } catch (err) { $('newErr').textContent = err.message; } finally { btn.disabled = false; }
  };

  // ---------- 화면 이동 ----------
  function route(refresh) {
    if (!token) { showLogin(); return; }
    const m = location.hash.match(/^#\/s\/(claude|codex)\/([0-9A-Za-z-]+)$/);
    if (m) {
      if (refresh && cur && cur.agent === m[1] && cur.id === m[2]) { show('chat'); connect(); return; }
      openChat(m[1], m[2]);
    } else {
      closeChat();
      show('list');
      loadList(true);
    }
  }
  window.addEventListener('hashchange', () => route());
  api('/api/info').then(d => {
    if (d.modes) info.modes = d.modes;
    if (d.models) info.models = d.models;
    if (d.efforts) info.efforts = d.efforts;
  }).catch(() => {}).finally(() => route());

  // ---------- 아주 작은 마크다운 (HTML 은 모두 이스케이프) ----------
  function esc(s) { return s.replace(/[&<>"']/g, c => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[c])); }
  function inline(s) {
    const codes = [];
    s = s.replace(/`([^`\n]+)`/g, (_, x) => { codes.push(x); return '\u0000' + (codes.length - 1) + '\u0000'; });
    s = esc(s)
      .replace(/\*\*([^*\n]+)\*\*/g, '<strong>$1</strong>')
      .replace(/(^|[^*\w])\*([^*\n]+)\*(?!\w)/g, '$1<em>$2</em>')
      .replace(/\[([^\]\n]+)\]\((https?:\/\/[^\s)]+)\)/g, '<a href="$2" target="_blank" rel="noopener noreferrer">$1</a>');
    return s.replace(/\u0000(\d+)\u0000/g, (_, i) => '<code>' + esc(codes[+i]) + '</code>');
  }
  function md(src) {
    const lines = String(src || '').replace(/\r\n/g, '\n').split('\n');
    const out = [];
    let i = 0;
    const isTableRow = l => /^\s*\|.*\|\s*$/.test(l);
    const cells = l => l.trim().replace(/^\||\|$/g, '').split('|').map(x => x.trim());
    while (i < lines.length) {
      const l = lines[i];
      const fence = l.match(/^\s*(```|~~~)/);
      if (fence) {
        const buf = []; i++;
        while (i < lines.length && !lines[i].trim().startsWith(fence[1])) buf.push(lines[i++]);
        i++;
        out.push('<pre><code>' + esc(buf.join('\n')) + '</code></pre>');
        continue;
      }
      if (!l.trim()) { i++; continue; }
      const h = l.match(/^(#{1,6})\s+(.*)$/);
      if (h) { const n = Math.min(h[1].length + 1, 4); out.push(`<h${n}>${inline(h[2])}</h${n}>`); i++; continue; }
      if (isTableRow(l) && i + 1 < lines.length && /^\s*\|?\s*:?-{2,}/.test(lines[i + 1])) {
        const head = cells(l); i += 2;
        const rows = [];
        while (i < lines.length && isTableRow(lines[i])) rows.push(cells(lines[i++]));
        out.push('<table><thead><tr>' + head.map(c => '<th>' + inline(c) + '</th>').join('') + '</tr></thead><tbody>' +
          rows.map(r => '<tr>' + r.map(c => '<td>' + inline(c) + '</td>').join('') + '</tr>').join('') + '</tbody></table>');
        continue;
      }
      if (/^\s*([-*+]|\d+[.)])\s+/.test(l)) {
        const ordered = /^\s*\d/.test(l);
        const items = [];
        while (i < lines.length && /^\s*([-*+]|\d+[.)])\s+/.test(lines[i])) {
          let item = lines[i].replace(/^\s*([-*+]|\d+[.)])\s+/, ''); i++;
          while (i < lines.length && /^\s{2,}\S/.test(lines[i]) && !/^\s*([-*+]|\d+[.)])\s+/.test(lines[i])) item += '\n' + lines[i++].trim();
          items.push('<li>' + inline(item).replace(/\n/g, '<br>') + '</li>');
        }
        out.push(ordered ? '<ol>' + items.join('') + '</ol>' : '<ul>' + items.join('') + '</ul>');
        continue;
      }
      if (/^\s*>/.test(l)) {
        const buf = [];
        while (i < lines.length && /^\s*>/.test(lines[i])) buf.push(lines[i++].replace(/^\s*>\s?/, ''));
        out.push('<blockquote>' + inline(buf.join('\n')).replace(/\n/g, '<br>') + '</blockquote>');
        continue;
      }
      const buf = [];
      while (i < lines.length && lines[i].trim() && !/^\s*(```|~~~|#{1,6}\s|>|([-*+]|\d+[.)])\s+)/.test(lines[i]) &&
        !(isTableRow(lines[i]) && i + 1 < lines.length && /^\s*\|?\s*:?-{2,}/.test(lines[i + 1]))) buf.push(lines[i++]);
      if (!buf.length) { buf.push(lines[i++]); }
      out.push('<p>' + inline(buf.join('\n')).replace(/\n/g, '<br>') + '</p>');
    }
    return out.join('');
  }
})();
