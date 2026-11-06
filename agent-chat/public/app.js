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
  let info = { modes: { claude: ['acceptEdits', 'auto', 'bypassPermissions', 'plan'], codex: ['workspace-write', 'read-only', 'danger-full-access'] } };
  let filter = store.get('ac_filter', 'all');
  let hideTools = store.get('ac_hideTools', '0') === '1';
  let timer = null;

  // 주소의 #t=토큰 을 받아 저장하고 주소에서는 지운다
  const hm = location.hash.match(/(?:^#|&)t=([^&]+)/);
  if (hm) { token = decodeURIComponent(hm[1]); store.set('ac_token', token); history.replaceState(null, '', location.pathname); }

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

  function show(id) { for (const v of ['login', 'list', 'chat']) $(v).hidden = v !== id; }
  function showLogin(msg) { stopTimer(); show('login'); $('loginErr').textContent = msg || ''; }
  $('tokenSave').onclick = () => { token = $('tokenInput').value.trim(); store.set('ac_token', token); route(); };

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
      top.append(el('span', 'badge ' + s.agent, s.agent === 'claude' ? 'Claude' : 'Codex'), el('span', '', s.project || ''), el('span', 'grow'));
      if (s.running || s.active) top.append(el('span', 'dot'));
      top.append(el('span', '', ago(s.mtime)));
      b.append(top, el('div', 'name', s.title), el('div', 'pv', (s.lastRole === 'user' ? '나: ' : '') + (s.preview || '')));
      b.onclick = () => { location.hash = `#/s/${s.agent}/${s.id}`; };
      return b;
    }));
  }
  for (const c of $('filters').children) {
    c.classList.toggle('on', c.dataset.f === filter);
    c.onclick = () => {
      filter = c.dataset.f; store.set('ac_filter', filter);
      for (const x of $('filters').children) x.classList.toggle('on', x === c);
      renderList();
    };
  }

  // ---------- 채팅 ----------
  let cur = null; // {agent, id, stamp, epoch, rendered: Map(n→{json, el}), limit, pending}
  function fillModes(sel, agent) {
    const modes = info.modes[agent] || [];
    const saved = store.get('ac_mode_' + agent, modes[0]);
    sel.replaceChildren(...modes.map(m => { const o = el('option', '', MODE_LABEL[m] || m); o.value = m; return o; }));
    sel.value = modes.includes(saved) ? saved : modes[0];
  }
  function openChat(agent, id) {
    cur = { agent, id, stamp: '', epoch: -1, rendered: new Map(), limit: 300, pending: null, first: true };
    show('chat');
    $('msgs').replaceChildren();
    $('msgs').classList.toggle('hide-tools', hideTools);
    $('toolsToggle').classList.toggle('on', !hideTools);
    $('chatTitle').textContent = '불러오는 중…';
    $('chatSub').textContent = agent === 'claude' ? 'Claude' : 'Codex';
    fillModes($('mode'), agent);
    $('status').hidden = true;
    loadChat();
  }
  $('toolsToggle').onclick = () => {
    hideTools = !hideTools; store.set('ac_hideTools', hideTools ? '1' : '0');
    $('msgs').classList.toggle('hide-tools', hideTools);
    $('toolsToggle').classList.toggle('on', !hideTools);
  };
  $('mode').onchange = () => cur && store.set('ac_mode_' + cur.agent, $('mode').value);
  $('back').onclick = () => { location.hash = '#/'; };

  async function loadChat() {
    const c = cur;
    if (!c) return;
    let d;
    try {
      d = await api(`/api/messages?agent=${c.agent}&id=${encodeURIComponent(c.id)}&limit=${c.limit}&stamp=${encodeURIComponent(c.stamp)}`);
    } catch (e) {
      if (e.message === '401' || c !== cur) return;
      setStatus('연결 오류: ' + e.message, true);
      schedule(loadChat, 5000);
      return;
    }
    if (c !== cur) return;
    const running = d.same ? c.running : !!(d.job && d.job.running);
    if (!d.same) {
      c.stamp = d.stamp;
      c.running = running;
      renderChat(d);
    }
    schedule(loadChat, running || (d.active && !d.same) || d.pending ? 1500 : 4000);
  }

  function renderChat(d) {
    const c = cur;
    const box = $('msgs');
    const nearBottom = c.first || box.scrollHeight - box.scrollTop - box.clientHeight < 120;
    if (d.title) $('chatTitle').textContent = d.title;
    if (d.cwd) $('chatSub').textContent = (c.agent === 'claude' ? 'Claude · ' : 'Codex · ') + d.cwd;
    if (d.epoch !== c.epoch || d.from !== c.from) { c.rendered.clear(); box.replaceChildren(); c.epoch = d.epoch; c.from = d.from; }
    if (d.from > 0 && !box.querySelector('.more')) {
      const more = el('button', 'more', `이전 메시지 ${d.from}개 더 보기`);
      more.onclick = () => { c.limit += 300; c.stamp = ''; loadChat(); };
      box.prepend(more);
    }
    for (const it of d.items || []) {
      const j = JSON.stringify(it);
      const old = c.rendered.get(it.n);
      if (old && old.json === j) continue;
      const node = renderItem(it, old && old.el);
      if (old) old.el.replaceWith(node); else box.append(node);
      c.rendered.set(it.n, { json: j, el: node });
    }
    // 보낸 말이 기록에 나타나면 임시 말풍선을 지운다
    if (c.pending && (d.items || []).some(it => it.role === 'user' && it.n >= c.pending.after)) { c.pending.el.remove(); c.pending = null; }
    if (c.pending) box.append(c.pending.el);
    const job = d.job;
    if (job && job.running) setStatus('작업 중…', false, true);
    else if (job && job.error) setStatus(job.error, true);
    else if (d.active && !job) setStatus('PC 에서 작업 중인 것 같습니다 (VS Code)', false);
    else $('status').hidden = true;
    if (nearBottom) box.scrollTop = box.scrollHeight;
    c.first = false;
  }

  function setStatus(text, isErr, canStop) {
    const s = $('status');
    s.hidden = false;
    s.className = 'status' + (isErr ? ' error' : '');
    s.replaceChildren();
    if (!isErr) s.append(el('span', 'dot'));
    s.append(el('span', '', text));
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

  // ---------- 보내기 ----------
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
      await api('/api/send', { agent: c.agent, id: c.id, prompt: text, mode: $('mode').value });
      input.value = ''; grow();
      const p = el('div', 'msg user pending'); p.append(el('div', 'bubble', text));
      c.pending = { el: p, after: c.rendered.size ? Math.max(...c.rendered.keys()) + 1 : 0 };
      $('msgs').append(p);
      $('msgs').scrollTop = $('msgs').scrollHeight;
      c.stamp = ''; c.running = true;
      setStatus('작업 중…', false, true);
      schedule(loadChat, 800);
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
      sel.replaceChildren(...d.projects.map(p => { const o = el('option', '', p.name + '  —  ' + p.path); o.value = p.path; return o; }));
      if (!d.projects.length) sel.replaceChildren(el('option', '', '(최근 폴더 없음: 아래에 경로 입력)'));
      if (d.projects.some(p => p.path === last)) sel.value = last;
    } catch (e) { $('newErr').textContent = e.message; }
    $('newPrompt').focus();
  };
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
      const r = await api('/api/new', { agent: newAgent, cwd, prompt, mode: $('newMode').value });
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
      if (refresh && cur && cur.agent === m[1] && cur.id === m[2]) { show('chat'); loadChat(); return; }
      openChat(m[1], m[2]);
    } else {
      cur = null;
      show('list');
      loadList(true);
    }
  }
  window.addEventListener('hashchange', () => route());
  api('/api/info').then(d => { if (d.modes) info.modes = d.modes; }).catch(() => {}).finally(() => route());

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
