'use strict';
// 테스트용 가짜 디버깅 포트(Chrome DevTools Protocol). 진짜처럼 /json/list 와 WebSocket 을 연다.
//   pages: [{ id, type, title, url, handle(method, params) → result | throw }]
const http = require('http');
const crypto = require('crypto');

function frame(text, { split } = {}) {
  const one = (op, fin, payload) => {
    const n = payload.length;
    const head = n < 126 ? Buffer.from([(fin ? 0x80 : 0) | op, n]) : n < 65536 ? Buffer.from([(fin ? 0x80 : 0) | op, 126, n >> 8, n & 255]) : (() => { const h = Buffer.alloc(10); h[0] = (fin ? 0x80 : 0) | op; h[1] = 127; h.writeBigUInt64BE(BigInt(n), 2); return h; })();
    return Buffer.concat([head, payload]);
  };
  const p = Buffer.from(text, 'utf8');
  if (!split || p.length < 4) return one(1, true, p);
  const k = Math.floor(p.length / 2); // 조각난 프레임 (글자 중간에서 잘릴 수도 있다)
  return Buffer.concat([one(1, false, p.subarray(0, k)), one(0, true, p.subarray(k))]);
}

function start(pages) {
  return new Promise(resolve => {
    const srv = http.createServer((req, res) => {
      const port = srv.address().port;
      if (req.url === '/json/list' || req.url === '/json') { res.setHeader('Content-Type', 'application/json'); res.end(JSON.stringify(pages.map(p => ({ id: p.id, type: p.type || 'page', title: p.title, url: p.url || 'vscode-file://vscode-app/workbench.html', webSocketDebuggerUrl: `ws://127.0.0.1:${port}/devtools/page/${p.id}` })))); return; }
      res.statusCode = 404; res.end('{}');
    });
    srv.on('upgrade', (req, sock) => {
      const page = pages.find(p => req.url.endsWith('/' + p.id));
      const accept = crypto.createHash('sha1').update(req.headers['sec-websocket-key'] + '258EAFA5-E914-47DA-95CA-C5AB0DC85B11').digest('base64');
      sock.write(`HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Accept: ${accept}\r\n\r\n`);
      let buf = Buffer.alloc(0), n = 0;
      sock.on('data', d => {
        buf = Buffer.concat([buf, d]);
        for (;;) {
          if (buf.length < 2) return;
          let len = buf[1] & 0x7f, off = 2;
          if (len === 126) { if (buf.length < 4) return; len = buf.readUInt16BE(2); off = 4; } else if (len === 127) { if (buf.length < 10) return; len = Number(buf.readBigUInt64BE(2)); off = 10; }
          if (buf.length < off + 4 + len) return;
          const op = buf[0] & 0x0f, mask = buf.subarray(off, off + 4), body = Buffer.from(buf.subarray(off + 4, off + 4 + len));
          buf = buf.subarray(off + 4 + len);
          if (op === 8) { sock.end(); return; }
          for (let i = 0; i < body.length; i++) body[i] ^= mask[i & 3];
          let m; try { m = JSON.parse(body.toString('utf8')); } catch { continue; }
          let out;
          try { out = { id: m.id, result: (page && page.handle(m.method, m.params || {})) || {} }; } catch (e) { out = { id: m.id, error: { message: e.message } }; }
          sock.write(frame(JSON.stringify(out), { split: ++n % 2 === 0 }));
        }
      });
      sock.on('error', () => {});
    });
    srv.listen(0, '127.0.0.1', () => resolve({ port: srv.address().port, close: () => new Promise(r => { srv.closeAllConnections && srv.closeAllConnections(); srv.close(r); }) }));
  });
}

module.exports = { start, frame };
