'use strict';
// 크롬 기반 IDE(VS Code · Antigravity IDE · Cursor …)의 창 안을 디버깅 포트로 들여다보고 조작한다.
// IDE 를 --remote-debugging-port=<포트> 로 띄우면 127.0.0.1:<포트> 에 Chrome DevTools Protocol 이 열린다.
//   GET /json/list            → 창(page) · 웹뷰(iframe/webview) 목록과 각자의 webSocketDebuggerUrl
//   ws  Runtime.evaluate      → 그 창 안에서 스크립트를 돌려 글을 읽는다
//       Input.insertText 등   → 입력 칸에 글을 넣고 Enter
// 화면을 그리는 창을 앞으로 가져올 필요가 없어서, 화면이 잠겼거나 원격 데스크톱을 끊은 상태에서도 된다.
//
// 딸린 모듈 없이 쓰려고 WebSocket 클라이언트를 작게 직접 구현했다 (ws:// · 이 PC 안에서만).
const http = require('http');
const net = require('net');
const crypto = require('crypto');
const { EventEmitter } = require('events');

function getJson(port, path, timeoutMs = 1500, host = '127.0.0.1') {
  return new Promise((resolve, reject) => {
    const req = http.get({ host, port, path, timeout: timeoutMs }, res => {
      let body = '';
      res.setEncoding('utf8');
      res.on('data', d => { body += d; });
      res.on('end', () => { try { resolve(JSON.parse(body)); } catch (e) { reject(new Error('디버깅 포트의 응답을 읽지 못했습니다')); } });
    });
    req.on('timeout', () => req.destroy(new Error('디버깅 포트가 응답하지 않습니다')));
    req.on('error', reject);
  });
}

/** 아주 작은 WebSocket 클라이언트 (글 프레임만, 조각난 프레임 · 긴 길이 · ping 처리) */
class Ws extends EventEmitter {
  constructor(url) { super(); this.url = new URL(url); this.buf = Buffer.alloc(0); this.parts = []; this.open = false; this.closed = false; }
  connect(timeoutMs = 5000) {
    return new Promise((resolve, reject) => {
      const u = this.url;
      if (u.protocol !== 'ws:') { reject(new Error('ws:// 만 지원합니다')); return; }
      const key = crypto.randomBytes(16).toString('base64');
      const s = this.sock = net.connect({ host: u.hostname, port: Number(u.port) || 80 });
      const tm = setTimeout(() => { s.destroy(); reject(new Error('디버깅 포트 연결 시간 초과')); }, timeoutMs);
      let head = Buffer.alloc(0);
      const onHead = d => {
        head = Buffer.concat([head, d]);
        const i = head.indexOf('\r\n\r\n');
        if (i < 0) return;
        s.off('data', onHead);
        clearTimeout(tm);
        if (!/^HTTP\/1\.1 101/.test(head.toString('latin1', 0, i))) { s.destroy(); reject(new Error('디버깅 포트가 연결을 받지 않았습니다')); return; }
        this.open = true;
        s.on('data', x => this.feed(x));
        const rest = head.subarray(i + 4);
        if (rest.length) this.feed(rest);
        resolve(this);
      };
      s.on('data', onHead);
      s.on('error', e => { clearTimeout(tm); if (!this.open) reject(e); this.end(); });
      s.on('close', () => this.end());
      s.on('connect', () => s.write(`GET ${u.pathname}${u.search} HTTP/1.1\r\nHost: ${u.host}\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Key: ${key}\r\nSec-WebSocket-Version: 13\r\n\r\n`));
    });
  }
  end() { if (this.closed) return; this.closed = true; this.open = false; try { this.sock.destroy(); } catch { /* 이미 */ } this.emit('close'); }
  feed(d) {
    this.buf = this.buf.length ? Buffer.concat([this.buf, d]) : d;
    for (;;) {
      const b = this.buf;
      if (b.length < 2) return;
      const fin = !!(b[0] & 0x80), op = b[0] & 0x0f, masked = !!(b[1] & 0x80);
      let len = b[1] & 0x7f, off = 2;
      if (len === 126) { if (b.length < 4) return; len = b.readUInt16BE(2); off = 4; }
      else if (len === 127) { if (b.length < 10) return; len = Number(b.readBigUInt64BE(2)); off = 10; }
      const need = off + (masked ? 4 : 0) + len;
      if (b.length < need) return;
      let payload = b.subarray(off + (masked ? 4 : 0), need);
      if (masked) { const m = b.subarray(off, off + 4); payload = Buffer.from(payload); for (let i = 0; i < payload.length; i++) payload[i] ^= m[i & 3]; }
      this.buf = b.subarray(need);
      if (op === 8) { this.end(); return; }
      if (op === 9) { this.frame(10, payload); continue; }
      if (op === 10) continue;
      this.parts.push(payload);
      if (fin) { const text = Buffer.concat(this.parts).toString('utf8'); this.parts = []; this.emit('message', text); }
    }
  }
  frame(op, payload) {
    if (this.closed) return;
    const n = payload.length;
    const head = n < 126 ? Buffer.from([0x80 | op, 0x80 | n]) : n < 65536 ? Buffer.from([0x80 | op, 0x80 | 126, n >> 8, n & 255]) : (() => { const h = Buffer.alloc(10); h[0] = 0x80 | op; h[1] = 0x80 | 127; h.writeBigUInt64BE(BigInt(n), 2); return h; })();
    const mask = crypto.randomBytes(4);
    const body = Buffer.from(payload);
    for (let i = 0; i < n; i++) body[i] ^= mask[i & 3];
    this.sock.write(Buffer.concat([head, mask, body]));
  }
  send(text) { this.frame(1, Buffer.from(text, 'utf8')); }
  close() { try { this.frame(8, Buffer.alloc(0)); } catch { /* 이미 */ } setTimeout(() => this.end(), 200).unref(); }
}

/** 한 대상(창 · 웹뷰)과의 CDP 연결 */
class Page {
  constructor(wsUrl) { this.ws = new Ws(wsUrl); this.id = 0; this.pend = new Map(); }
  async open() {
    await this.ws.connect();
    this.ws.on('message', t => {
      let m; try { m = JSON.parse(t); } catch { return; }
      const p = m.id != null && this.pend.get(m.id);
      if (!p) return;
      this.pend.delete(m.id);
      if (m.error) p.reject(new Error(m.error.message || 'CDP 오류')); else p.resolve(m.result || {});
    });
    this.ws.on('close', () => { for (const p of this.pend.values()) p.reject(new Error('디버깅 연결이 끊겼습니다')); this.pend.clear(); });
    return this;
  }
  call(method, params = {}, timeoutMs = 10000) {
    return new Promise((resolve, reject) => {
      const id = ++this.id;
      const tm = setTimeout(() => { this.pend.delete(id); reject(new Error(method + ' 시간 초과')); }, timeoutMs);
      this.pend.set(id, { resolve: v => { clearTimeout(tm); resolve(v); }, reject: e => { clearTimeout(tm); reject(e); } });
      try { this.ws.send(JSON.stringify({ id, method, params })); } catch (e) { this.pend.delete(id); clearTimeout(tm); reject(e); }
    });
  }
  /** 그 창 안에서 식을 계산해 값(JSON 으로 옮길 수 있는 것)을 돌려받는다 */
  async evaluate(expression, timeoutMs) {
    const r = await this.call('Runtime.evaluate', { expression, returnByValue: true, awaitPromise: true }, timeoutMs);
    if (r.exceptionDetails) throw new Error('창 안 스크립트 오류: ' + ((r.exceptionDetails.exception && r.exceptionDetails.exception.description) || r.exceptionDetails.text || '').split('\n')[0]);
    return r.result ? r.result.value : undefined;
  }
  /** 지금 포커스가 있는 곳에 글을 넣는다 (사람이 붙여넣은 것처럼 input 이벤트가 난다) */
  insertText(text) { return this.call('Input.insertText', { text }); }
  async pressEnter() {
    const k = { key: 'Enter', code: 'Enter', windowsVirtualKeyCode: 13, nativeVirtualKeyCode: 13 };
    await this.call('Input.dispatchKeyEvent', { type: 'keyDown', text: '\r', unmodifiedText: '\r', ...k });
    await this.call('Input.dispatchKeyEvent', { type: 'keyUp', ...k });
  }
  close() { this.ws.close(); }
}

async function targets(port) {
  const list = await getJson(port, '/json/list');
  return Array.isArray(list) ? list : [];
}

async function withPage(wsUrl, fn) {
  const p = await new Page(wsUrl).open();
  try { return await fn(p); } finally { p.close(); }
}

module.exports = { getJson, Ws, Page, targets, withPage };
