import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:cp949_codec/cp949_codec.dart';
import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/painting.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../models/media_item.dart';
import 'archive_tools.dart';
import 'webdav_client.dart';

/// NAS 계정 하나 (주소의 앞부분 http(s)://주소:포트 마다). 비밀번호는 설정에 따로 (백업에는 넣지 않는다)
class NasAccount {
  const NasAccount({required this.origin, this.user = '', this.insecure = false});
  final String origin;
  final String user;
  final bool insecure;

  Map<String, Object> toJson() => {'origin': origin, 'user': user, 'insecure': insecure};
  static NasAccount fromJson(Map<String, dynamic> j) =>
      NasAccount(origin: '${j['origin']}', user: '${j['user'] ?? ''}', insecure: j['insecure'] == true || j['insecure'] == 'true');

  static List<NasAccount> decode(String? raw) {
    if (raw == null || raw.isEmpty) return const [];
    try {
      return [for (final e in jsonDecode(raw) as List) fromJson((e as Map).cast<String, dynamic>())];
    } catch (_) {
      return const [];
    }
  }

  static String encode(List<NasAccount> v) => jsonEncode([for (final e in v) e.toJson()]);
}

/// 서재에 연결한 NAS 폴더 (받지 않고 그 자리에서 본다)
class NasFolder {
  const NasFolder({required this.url, this.name = ''});

  /// 폴더 주소 (풀어 쓴 꼴, 끝에 / 없음): http://192.168.0.10:5005/home/만화
  final String url;
  final String name;

  String get label {
    if (name.isNotEmpty) return name;
    final last = url.split('/').where((s) => s.isNotEmpty).last;
    return last.contains(':') ? Uri.tryParse(url)?.host ?? url : last; // 서버 맨 위면 주소 이름
  }

  Map<String, String> toJson() => {'url': url, 'name': name};
  static NasFolder fromJson(Map<String, dynamic> j) => NasFolder(url: '${j['url']}', name: '${j['name'] ?? ''}');

  static List<NasFolder> decode(String? raw) {
    if (raw == null || raw.isEmpty) return const [];
    try {
      return [for (final e in jsonDecode(raw) as List) fromJson((e as Map).cast<String, dynamic>())];
    } catch (_) {
      return const [];
    }
  }

  static String encode(List<NasFolder> v) => jsonEncode([for (final e in v) e.toJson()]);
}

/// 이 서버는 "파일의 이 부분만" 요청(Range)을 받아 주지 않는다 → 통째로 받아서 본다
class RangeUnsupported implements Exception {
  const RangeUnsupported();
  @override
  String toString() => '이 서버는 나눠 받기를 지원하지 않습니다';
}

/// NAS(WebDAV) 의 파일을 받지 않고 읽기.
///
/// 서재에는 NAS 파일을 풀어 쓴 주소(http://192.168.0.10:5005/home/만화/코난 01.cbz)를 경로로 넣는다.
/// - 만화(ZIP): 맨 끝의 목차와 보는 쪽의 그림만 골라 받는다 ([RemoteZip])
/// - PDF: PDF 엔진이 달라는 부분만 받는다 ([RemoteReader])
/// - 영상: 재생기가 주소를 직접 연다 (끊어 받으며 재생)
/// - TXT · EPUB · 그 밖: 작으니 통째로 받아 임시 보관함에 두고 읽는다 ([cache])
class Remote {
  Remote._();

  static List<NasAccount> accounts = const [];
  static List<NasFolder> folders = const [];

  /// 주소 앞부분 → 비밀번호 (AppState 가 설정에서 읽어 넣는다)
  static String Function(String origin) password = (_) => '';

  static bool isRemote(String path) => path.startsWith('http://') || path.startsWith('https://');

  /// http://주소:포트
  static String originOf(String path) {
    final s = path.indexOf('://');
    final i = s < 0 ? -1 : path.indexOf('/', s + 3);
    return i < 0 ? path : path.substring(0, i);
  }

  /// 서버 안 경로 (/home/만화/a.cbz)
  static String serverPath(String path) {
    final o = originOf(path);
    final rest = path.substring(o.length);
    return rest.isEmpty ? '/' : rest;
  }

  /// 실제로 요청할 주소 (한글 · 빈칸을 주소 꼴로)
  static Uri uri(String path) {
    final segs = serverPath(path).split('/').where((s) => s.isNotEmpty).toList();
    return Uri.parse(originOf(path)).replace(pathSegments: segs);
  }

  static NasAccount? account(String path) {
    final o = originOf(path);
    for (final a in accounts) {
      if (a.origin == o) return a;
    }
    return null;
  }

  static NasFolder? folderOf(String path) {
    for (final f in folders) {
      if (path == f.url || path.startsWith('${f.url}/')) return f;
    }
    return null;
  }

  static Map<String, String> headers(String path) {
    final a = account(path);
    final pw = password(originOf(path));
    if (a == null || (a.user.isEmpty && pw.isEmpty)) return const {};
    return {HttpHeaders.authorizationHeader: 'Basic ${base64.encode(utf8.encode('${a.user}:$pw'))}'};
  }

  /// 목록 보기 · 훑기용 WebDAV 연결
  static WebDavClient client(String path) {
    final a = account(path);
    return WebDavClient('${originOf(path)}/', user: a?.user ?? '', password: password(originOf(path)), insecure: a?.insecure ?? false);
  }

  // 주소마다 연결 하나를 돌려 쓴다 (쪽을 넘길 때마다 새로 연결하지 않게)
  static final _clients = <String, HttpClient>{};
  static HttpClient _client(String path) {
    final insecure = account(path)?.insecure ?? false;
    return _clients.putIfAbsent('${originOf(path)}|$insecure', () {
      final c = HttpClient()
        ..connectionTimeout = const Duration(seconds: 8)
        ..idleTimeout = const Duration(seconds: 20)
        ..maxConnectionsPerHost = 4;
      if (insecure) c.badCertificateCallback = (_, _, _) => true;
      return c;
    });
  }

  /// 계정을 바꾸면 열어 둔 연결을 버린다
  static void reset() {
    for (final c in _clients.values) {
      c.close(force: true);
    }
    _clients.clear();
  }

  static Future<HttpClientResponse> _send(String method, String path, {Map<String, String>? extra, Duration wait = const Duration(seconds: 30)}) async {
    final req = await _client(path).openUrl(method, uri(path)).timeout(wait);
    headers(path).forEach(req.headers.set);
    extra?.forEach(req.headers.set);
    final res = await req.close().timeout(wait);
    if (res.statusCode == 401) {
      _drop(res);
      throw const WebDavError('NAS 아이디 · 비밀번호가 맞지 않습니다. NAS 연결 화면에서 다시 넣어 주세요');
    }
    return res;
  }

  /// 받던 것을 그만둔다 (남은 내용을 다 받지 않고 연결을 끊는다)
  static void _drop(HttpClientResponse res) {
    try {
      res.listen(null).cancel();
    } catch (_) {}
  }

  static Future<Uint8List> _body(Stream<List<int>> s) async {
    final b = BytesBuilder(copy: false);
    await for (final c in s) {
      b.add(c);
    }
    return b.takeBytes();
  }

  /// [start] 부터 [length] 바이트
  static Future<Uint8List> range(String path, int start, int length) async {
    if (length <= 0) return Uint8List(0);
    final res = await _send('GET', path, extra: {HttpHeaders.rangeHeader: 'bytes=$start-${start + length - 1}'});
    if (res.statusCode == 206) return _body(res);
    _drop(res);
    if (res.statusCode == 200) throw const RangeUnsupported();
    if (res.statusCode == 404) throw const WebDavError('NAS 에 그 파일이 없습니다 (옮겼거나 지웠을 수 있습니다)');
    throw WebDavError('NAS 가 읽기를 거절했습니다 (${res.statusCode})');
  }

  /// 파일 크기 (모르면 null)
  static Future<int?> size(String path) async {
    try {
      final res = await _send('HEAD', path, wait: const Duration(seconds: 10));
      _drop(res);
      return res.statusCode == 200 && res.contentLength > 0 ? res.contentLength : null;
    } on WebDavError {
      rethrow;
    } catch (_) {
      return null;
    }
  }

  /// 지금 열 수 있는가 (NAS 가 꺼졌거나 다른 네트워크면 false)
  static Future<bool> exists(String path) async {
    try {
      final res = await _send('HEAD', path, wait: const Duration(seconds: 6));
      _drop(res);
      return res.statusCode >= 200 && res.statusCode < 300;
    } catch (_) {
      return false;
    }
  }

  /// NAS 의 파일 지우기 (읽기 전용 서버면 false)
  static Future<bool> delete(String path) async {
    try {
      final res = await _send('DELETE', path);
      _drop(res);
      return res.statusCode == 200 || res.statusCode == 204;
    } catch (_) {
      return false;
    }
  }

  // ---------- 임시 보관함: 통째로 받아야 하는 것 (TXT · EPUB · RAR · 그림 · 다른 앱으로 열기) ----------
  static final _caching = <String, Future<String>>{};

  /// 통째로 받아 임시 보관함에 둔 파일 경로. 이미 받은 것이면 바로
  static Future<String> cache(String path, {int? size}) {
    final busy = _caching[path];
    if (busy != null) return busy;
    final f = _cache(path, size).whenComplete(() => _caching.remove(path));
    return _caching[path] = f;
  }

  static Future<String> _cache(String path, int? size) async {
    final dir = Directory(p.join((await getTemporaryDirectory()).path, 'nas_cache'));
    await dir.create(recursive: true);
    final key = sha1.convert(utf8.encode(path)).toString().substring(0, 24);
    final out = File(p.join(dir.path, '$key${p.extension(path).toLowerCase()}'));
    if (await out.exists() && (size == null || size <= 0 || await out.length() == size)) {
      try {
        await out.setLastModified(DateTime.now()); // 최근에 쓴 것은 남긴다
      } catch (_) {}
      return out.path;
    }
    final part = File('${out.path}.part');
    final res = await _send('GET', path);
    if (res.statusCode != 200) {
      _drop(res);
      throw WebDavError(res.statusCode == 404 ? 'NAS 에 그 파일이 없습니다' : 'NAS 에서 받지 못했습니다 (${res.statusCode})');
    }
    try {
      await res.pipe(part.openWrite());
      if (await out.exists()) await out.delete();
      await part.rename(out.path);
    } catch (_) {
      if (await part.exists()) await part.delete();
      rethrow;
    }
    unawaited(_trim(dir));
    return out.path;
  }

  /// 임시 보관함이 너무 커지면 오래 안 쓴 것부터 지운다
  static Future<void> _trim(Directory dir, {int max = 2 * 1024 * 1024 * 1024}) async {
    try {
      final files = <(File, FileStat)>[
        await for (final e in dir.list(followLinks: false))
          if (e is File && !e.path.endsWith('.part')) (e, await e.stat()),
      ]..sort((a, b) => b.$2.modified.compareTo(a.$2.modified));
      var total = 0;
      for (final (f, st) in files) {
        total += st.size;
        if (total > max) await f.delete();
      }
    } catch (_) {}
  }
}

/// NAS 파일을 덩어리(기본 256KB)로 받아 기억해 두고 읽는다 — PDF 엔진처럼 작게 여러 번 읽는 쪽에 쓴다
class RemoteReader {
  RemoteReader(this.path, this.length, {this.block = 256 * 1024, this.keep = 48});

  final String path;
  final int length;
  final int block;
  final int keep;
  final _blocks = LinkedHashMap<int, Future<Uint8List>>();

  Future<int> read(Uint8List into, int position, int size) async {
    var done = 0;
    while (done < size && position + done < length) {
      final at = position + done;
      final bi = at ~/ block;
      final b = await _block(bi);
      final off = at - bi * block;
      final n = math.min(size - done, b.length - off);
      if (n <= 0) break;
      into.setRange(done, done + n, b, off);
      done += n;
    }
    return done;
  }

  Future<Uint8List> _block(int i) {
    final hit = _blocks.remove(i);
    if (hit != null) return _blocks[i] = hit; // 최근에 쓴 것으로
    final start = i * block;
    final f = Remote.range(path, start, math.min(block, length - start));
    _blocks[i] = f;
    f.catchError((_) {
      _blocks.remove(i); // 실패한 덩어리는 다음에 다시 받는다
      return Uint8List(0);
    });
    while (_blocks.length > keep) {
      _blocks.remove(_blocks.keys.first);
    }
    return f;
  }
}

/// ZIP 안의 파일 하나 (목차에 적힌 것)
class RemoteZipEntry {
  const RemoteZipEntry(this.name, this.method, this.flags, this.compSize, this.size, this.offset, this.nameLen, this.extraLen);
  final String name;
  final int method, flags, compSize, size, offset, nameLen, extraLen;
  bool get isDir => name.endsWith('/');
}

/// ZIP 을 통째로 받지 않고 읽기: 맨 끝의 목차를 먼저 읽고, 필요한 파일만 그 자리를 골라 받는다.
/// [read] 는 (시작, 길이) 를 받아 그 부분을 돌려준다 — NAS 면 [Remote.range].
class RemoteZip {
  RemoteZip._(this.entries, this._read, this.length);

  final List<RemoteZipEntry> entries;
  final Future<Uint8List> Function(int start, int length) _read;
  final int length;

  /// NAS 의 ZIP
  static Future<RemoteZip> openPath(String path, {int? size}) async {
    final len = (size != null && size > 0) ? size : await Remote.size(path);
    if (len == null || len <= 0) throw const WebDavError('NAS 에서 파일 크기를 알 수 없습니다');
    return open((s, n) => Remote.range(path, s, n), len);
  }

  static Future<RemoteZip> open(Future<Uint8List> Function(int start, int length) read, int length) async {
    // 1) 맨 끝의 "목차 끝" 표시 (그 뒤에 설명이 최대 64KB 붙을 수 있다)
    final tailLen = math.min(length, 22 + 65535);
    final tailStart = length - tailLen;
    final tail = await read(tailStart, tailLen);
    final t = ByteData.sublistView(tail);
    var eocd = -1;
    for (var i = tail.length - 22; i >= 0; i--) {
      if (t.getUint32(i, Endian.little) == 0x06054b50) {
        eocd = i;
        break;
      }
    }
    if (eocd < 0) throw const FormatException('ZIP 파일이 아닙니다');
    var count = t.getUint16(eocd + 10, Endian.little);
    var cdSize = t.getUint32(eocd + 12, Endian.little);
    var cdOffset = t.getUint32(eocd + 16, Endian.little);
    // 4GB 가 넘는 ZIP(ZIP64)
    if ((count == 0xFFFF || cdSize == 0xFFFFFFFF || cdOffset == 0xFFFFFFFF) && eocd >= 20 && t.getUint32(eocd - 20, Endian.little) == 0x07064b50) {
      final at = t.getUint64(eocd - 20 + 8, Endian.little);
      final rec = ByteData.sublistView(await read(at, 56));
      if (rec.getUint32(0, Endian.little) == 0x06064b50) {
        count = rec.getUint64(32, Endian.little);
        cdSize = rec.getUint64(40, Endian.little);
        cdOffset = rec.getUint64(48, Endian.little);
      }
    }
    if (cdOffset + cdSize > length) throw const FormatException('ZIP 목차가 깨졌습니다');
    // 2) 목차 (끝부분에 이미 받아 둔 것이면 다시 받지 않는다)
    final Uint8List cd =
        cdOffset >= tailStart ? Uint8List.sublistView(tail, cdOffset - tailStart, cdOffset - tailStart + cdSize) : await read(cdOffset, cdSize);
    final c = ByteData.sublistView(cd);
    final out = <RemoteZipEntry>[];
    var i = 0;
    while (i + 46 <= cd.length && c.getUint32(i, Endian.little) == 0x02014b50 && out.length < 200000) {
      final flags = c.getUint16(i + 8, Endian.little);
      final method = c.getUint16(i + 10, Endian.little);
      var comp = c.getUint32(i + 20, Endian.little);
      var size = c.getUint32(i + 24, Endian.little);
      final nLen = c.getUint16(i + 28, Endian.little);
      final xLen = c.getUint16(i + 30, Endian.little);
      final cLen = c.getUint16(i + 32, Endian.little);
      var off = c.getUint32(i + 42, Endian.little);
      if (i + 46 + nLen + xLen > cd.length) break;
      final name = _name(Uint8List.sublistView(cd, i + 46, i + 46 + nLen), (flags & 0x800) != 0);
      // ZIP64 덧붙임: 크기 · 자리가 0xFFFFFFFF 이면 여기에 진짜 값
      var x = i + 46 + nLen;
      final xEnd = x + xLen;
      while (x + 4 <= xEnd) {
        final id = c.getUint16(x, Endian.little);
        final len = c.getUint16(x + 2, Endian.little);
        if (id == 1) {
          var q = x + 4;
          if (size == 0xFFFFFFFF && q + 8 <= xEnd) {
            size = c.getUint64(q, Endian.little);
            q += 8;
          }
          if (comp == 0xFFFFFFFF && q + 8 <= xEnd) {
            comp = c.getUint64(q, Endian.little);
            q += 8;
          }
          if (off == 0xFFFFFFFF && q + 8 <= xEnd) off = c.getUint64(q, Endian.little);
        }
        x += 4 + len;
      }
      out.add(RemoteZipEntry(name, method, flags, comp, size, off, nLen, xLen));
      i += 46 + nLen + xLen + cLen;
    }
    return RemoteZip._(out, read, length);
  }

  /// 파일 이름: UTF-8 표시가 있으면 UTF-8, 없으면 UTF-8 로 읽어 보고 안 되면 CP949 (한국 윈도우에서 묶은 ZIP)
  static String _name(Uint8List b, bool utf8Flag) {
    if (utf8Flag) return utf8.decode(b, allowMalformed: true);
    try {
      return utf8.decode(b);
    } catch (_) {
      return cp949.decode(b, allowInvalid: true);
    }
  }

  /// 그림들 (쪽 순서)
  List<RemoteZipEntry> get images => entries.where((e) => !e.isDir && imageExts.contains(p.extension(e.name).toLowerCase())).toList()
    ..sort((a, b) => ArchiveTools.natural(a.name, b.name));

  /// 파일 하나 풀기
  Future<Uint8List> read(RemoteZipEntry e) async {
    if ((e.flags & 1) != 0) throw UnsupportedError('암호가 걸린 압축 파일은 열 수 없습니다');
    // 파일 머리(30바이트 + 이름 + 덧붙임)와 내용을 한 번에 받는다 (머리의 덧붙임이 목차와 다르면 한 번 더)
    final guess = math.min(30 + e.nameLen + e.extraLen + 64 + e.compSize, length - e.offset);
    final buf = await _read(e.offset, guess);
    final h = ByteData.sublistView(buf);
    if (buf.length < 30 || h.getUint32(0, Endian.little) != 0x04034b50) throw const FormatException('ZIP 파일이 깨졌습니다');
    final ds = 30 + h.getUint16(26, Endian.little) + h.getUint16(28, Endian.little);
    final data = ds + e.compSize <= buf.length ? Uint8List.sublistView(buf, ds, ds + e.compSize) : await _read(e.offset + ds, e.compSize);
    switch (e.method) {
      case 0: // 압축 안 함 (만화 CBZ 는 대개 이것)
        return data;
      case 8: // 일반 압축
        final r = ZLibDecoder(raw: true).convert(data);
        return r is Uint8List ? r : Uint8List.fromList(r);
      default:
        throw UnsupportedError('이 압축 방식(${e.method})은 바로 볼 수 없습니다');
    }
  }
}

/// NAS 의 그림 (그림 보기): 임시 보관함에 받아 두고 그린다
@immutable
class RemoteImage extends ImageProvider<RemoteImage> {
  const RemoteImage(this.path);
  final String path;

  @override
  Future<RemoteImage> obtainKey(ImageConfiguration configuration) => SynchronousFuture(this);

  @override
  ImageStreamCompleter loadImage(RemoteImage key, ImageDecoderCallback decode) =>
      MultiFrameImageStreamCompleter(codec: _load(decode), scale: 1, debugLabel: path);

  Future<ui.Codec> _load(ImageDecoderCallback decode) async {
    final f = await Remote.cache(path);
    return decode(await ui.ImmutableBuffer.fromFilePath(f));
  }

  @override
  bool operator ==(Object other) => other is RemoteImage && other.path == path;
  @override
  int get hashCode => path.hashCode;
}
