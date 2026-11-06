'use strict';
// PC 브라우저에서만 열리는 연결 화면: 주소마다 QR 코드
(async () => {
  const box = document.getElementById('codes');
  let d;
  try { d = await (await fetch('/api/connect-info', { cache: 'no-store' })).json(); } catch (e) { box.textContent = '서버 정보를 못 읽었습니다: ' + e.message; return; }
  const show = (d.urls || []).filter(u => u.kind !== 'virtual');
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
  document.getElementById('foot').textContent = `PC: ${d.host} · 포트 ${d.port} · QR 에는 접속 토큰이 들어 있으니 남에게 보여 주지 마세요.`;
})();
