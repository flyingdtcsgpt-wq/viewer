'use strict';
// PC 브라우저에서만 열리는 연결 화면: 주소마다 QR 코드
(async () => {
  const box = document.getElementById('codes');
  let d;
  try { d = await (await fetch('/api/connect-info', { cache: 'no-store' })).json(); } catch (e) { box.textContent = '서버 정보를 못 읽었습니다: ' + e.message; return; }
  const show = (d.urls || []).filter(u => u.kind !== 'virtual');
  // 밖에서 쓰려면 Tailscale 이 있어야 한다: 주소가 없으면 설치 안내
  if (!(d.urls || []).some(u => u.kind === 'tailscale')) {
    const n = document.createElement('section');
    n.className = 'notice';
    n.innerHTML = '<b>Tailscale 이 이 PC 에서 꺼져 있거나 설치되어 있지 않습니다.</b><br>' +
      '지금은 같은 와이파이에서만 연결됩니다. 밖(LTE)에서도 쓰려면:<br>' +
      '1. 이 PC 에 <a href="https://tailscale.com/download/windows" target="_blank" rel="noopener">Tailscale</a> 설치 → 로그인<br>' +
      '2. 휴대폰에 Tailscale 앱 설치 → <b>같은 계정</b>으로 로그인<br>' +
      '3. 이 화면을 새로 고침 → <b>Tailscale 주소</b>로 숫자 코드 또는 QR 연결';
    document.querySelector('.pair').before(n);
  }
  const rest = (d.urls || []).filter(u => u.kind === 'virtual');
  if (!show.length) box.textContent = '네트워크 주소가 없습니다. 와이파이/유선 연결을 확인하세요.';
  for (const u of show.concat(rest)) {
    const card = document.createElement('section');
    card.className = 'code' + (u.kind === 'virtual' ? ' dim' : '');
    const h = document.createElement('h2'); h.textContent = u.label; card.append(h);
    const qr = qrcode(0, 'M'); qr.addData(u.url); qr.make();
    const img = document.createElement('img'); img.alt = u.url; img.src = qr.createDataURL(6, 2); card.append(img);
    const p = document.createElement('p'); p.className = 'muted'; p.textContent = `${u.name} · ${u.url.replace(/#t=.*/, '')}`; card.append(p);
    const b = document.createElement('button'); b.textContent = '주소 복사 (토큰 포함)';
    b.onclick = async () => { try { await navigator.clipboard.writeText(u.url); b.textContent = '복사됨'; } catch { prompt('복사하세요', u.url); } };
    card.append(b);
    box.append(card);
  }
  // 숫자 코드: 몇 초마다 새로 읽는다 (쓰이면 새 코드로 바뀜)
  const $ = id => document.getElementById(id);
  const port = d.port;
  const showPair = info => {
    const addrs = (info.addresses || []).map(a => `${a.address}${port === 8790 ? '' : ':' + port}  — ${a.label}`);
    $('pairAddr').textContent = addrs.length ? addrs.join('\n') : '(네트워크 주소 없음)';
    $('pairCode').textContent = info.pairCode.slice(0, 3) + ' ' + info.pairCode.slice(3);
    const left = Math.max(0, Math.round((info.pairExp - Date.now()) / 60000));
    $('pairExp').textContent = `${left}분 동안 · 한 번만 쓸 수 있음`;
    if (info.lastPaired && Date.now() - info.lastPaired < 5 * 60 * 1000) {
      $('paired').hidden = false;
      $('paired').textContent = '✓ 휴대폰이 연결되었습니다 (' + new Date(info.lastPaired).toLocaleTimeString() + '). 다른 휴대폰은 새 코드를 쓰세요.';
    }
  };
  showPair(d);

  // API 키 (이 PC 에서만)
  const showKeys = info => {
    const k = info.keys || {};
    $('kA').textContent = k.anthropic ? '저장됨 ' + k.anthropicMasked : '없음';
    $('kO').textContent = k.openai ? '저장됨 ' + k.openaiMasked : '없음';
    const ps = info.apiProjects || [];
    $('apiProj').textContent = ps.length ? 'API 로 돌리는 프로젝트: ' + ps.join(', ') : 'API 로 돌리는 프로젝트: 없음 (모두 구독)';
  };
  showKeys(d);
  const saveKeys = async body => {
    $('keyMsg').textContent = '';
    try {
      const r = await fetch('/api/local/keys', { method: 'POST', headers: { 'Content-Type': 'application/json' }, body: JSON.stringify(body) });
      const j = await r.json().catch(() => ({}));
      if (!r.ok) { $('keyMsg').textContent = j.error || ('오류 ' + r.status); return; }
      $('keyA').value = ''; $('keyO').value = '';
      $('keyMsg').textContent = '저장했습니다';
      showKeys(await (await fetch('/api/connect-info', { cache: 'no-store' })).json());
    } catch (e) { $('keyMsg').textContent = e.message; }
  };
  $('keySave').onclick = () => saveKeys({ anthropic: $('keyA').value.trim() || null, openai: $('keyO').value.trim() || null });
  $('keyDel').onclick = () => { if (confirm('저장된 API 키를 모두 지울까요? API 로 정한 프로젝트는 키를 다시 넣을 때까지 실행되지 않습니다.')) saveKeys({ anthropic: '', openai: '' }); };
  setInterval(async () => { try { showPair(await (await fetch('/api/connect-info', { cache: 'no-store' })).json()); } catch { /* 서버 꺼짐 */ } }, 3000);
  document.getElementById('foot').textContent = `PC: ${d.host} · 포트 ${d.port} · QR 에는 접속 토큰이 들어 있으니 남에게 보여 주지 마세요.`;
})();
