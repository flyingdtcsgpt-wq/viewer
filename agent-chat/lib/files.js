'use strict';
// 휴대폰에서 올린 첨부 파일.
// 대화의 프로젝트 폴더 안 .agent-chat-uploads 에 둔다. 프로젝트 밖에 두면 VS Code 의 Claude 가
// 읽을 때 PC 에서 허락을 물어 (아무도 없는 PC 에서) 멈출 수 있어서다.
// 폴더 안에 "*" 만 적힌 .gitignore 를 두어 git 에는 안 올라가게 한다 (사용자의 .gitignore 는 건드리지 않음).
const fs = require('fs');
const path = require('path');
const crypto = require('crypto');

const DIR = '.agent-chat-uploads';
const MAX = 25 * 1024 * 1024;
const HEAD = '[첨부 파일]';
const IMAGE = { '.png': 'image/png', '.jpg': 'image/jpeg', '.jpeg': 'image/jpeg', '.gif': 'image/gif', '.webp': 'image/webp', '.heic': 'image/heic' };

function dirOf(cwd) { return path.join(cwd, DIR); }

function safeName(name) {
  let n = path.basename(String(name || 'file')).normalize('NFC');
  n = n.replace(/[\u0000-\u001f<>:"/\\|?*\u007f]/g, '_').replace(/^\.+/, '').replace(/\s+/g, ' ').trim();
  if (!n) n = 'file';
  if (n.length > 80) { const ext = path.extname(n).slice(0, 12); n = n.slice(0, 80 - ext.length) + ext; }
  return n;
}

function stamp(d = new Date()) {
  const p = x => String(x).padStart(2, '0');
  return `${d.getFullYear()}${p(d.getMonth() + 1)}${p(d.getDate())}-${p(d.getHours())}${p(d.getMinutes())}${p(d.getSeconds())}`;
}

/** 저장하고 {path, name, size, image} */
function save(cwd, name, buf) {
  const dir = dirOf(cwd);
  fs.mkdirSync(dir, { recursive: true });
  const gi = path.join(dir, '.gitignore');
  if (!fs.existsSync(gi)) fs.writeFileSync(gi, '# Agent Chat 첨부 파일 (git 에 올리지 않음)\n*\n');
  const n = safeName(name);
  const file = path.join(dir, `${stamp()}-${crypto.randomBytes(2).toString('hex')}-${n}`);
  fs.writeFileSync(file, buf, { flag: 'wx' });
  return { path: file, name: n, size: buf.length, image: !!IMAGE[path.extname(n).toLowerCase()] };
}

/** p 가 이 프로젝트의 첨부 폴더 안 파일인가 */
function inside(cwd, p) {
  if (!cwd || typeof p !== 'string' || !p) return false;
  const base = path.resolve(dirOf(cwd)) + path.sep;
  const r = path.resolve(p);
  if (!r.startsWith(base) || r.slice(base.length).includes(path.sep)) return false;
  try { return fs.statSync(r).isFile(); } catch { return false; }
}

/** 보낼 글 끝에 첨부 목록을 붙인다 (에이전트는 경로의 파일을 열어 본다) */
function withFiles(prompt, files) {
  if (!files.length) return prompt;
  const text = String(prompt || '').trim() || '첨부한 파일을 봐 주세요.';
  return `${text}\n\n${HEAD}\n${files.map(f => '- ' + f).join('\n')}`;
}

function contentType(p) {
  return IMAGE[path.extname(p).toLowerCase()] || 'application/octet-stream';
}

module.exports = { save, inside, withFiles, contentType, MAX, DIR, HEAD };
