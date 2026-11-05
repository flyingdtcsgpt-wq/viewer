import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:xml/xml.dart';

/// WebDAV 목록 한 줄
class DavEntry {
  final String path; // 서버 안 경로 (/books/a.epub), 폴더는 / 로 끝남
  final String name;
  final bool dir;
  final int size;
  const DavEntry(this.path, this.name, this.dir, this.size);
}

/// NAS(시놀로지 · 큐냅 · 아이피타임) · 클라우드 · 다른 ARARIFlex 의 WebDAV 폴더를 둘러보고 파일을 받는다
class WebDavClient {
  WebDavClient(String url, {this.user = '', this.password = '', this.insecure = false})
      : base = Uri.parse(url.trim().endsWith('/') ? url.trim() : '${url.trim()}/');

  final Uri base;
  final String user, password;

  /// 자체 서명 인증서(NAS · ARARIFlex HTTPS)도 받아들일까
  final bool insecure;

  HttpClient _client() {
    final c = HttpClient()..connectionTimeout = const Duration(seconds: 15);
    if (insecure) c.badCertificateCallback = (_, _, _) => true;
    return c;
  }

  void _auth(HttpClientRequest r) {
    if (user.isNotEmpty || password.isNotEmpty) {
      r.headers.set(HttpHeaders.authorizationHeader, 'Basic ${base64.encode(utf8.encode('$user:$password'))}');
    }
  }

  /// 서버 안 경로 → 전체 주소
  Uri uriOf(String path) => base.replace(path: path.startsWith('/') ? path : '${base.path}$path');

  /// 폴더 안 목록 (폴더 먼저, 이름 순)
  Future<List<DavEntry>> list(String path) async {
    final c = _client();
    try {
      final req = await c.openUrl('PROPFIND', uriOf(path));
      _auth(req);
      req.headers.set('Depth', '1');
      req.headers.contentType = ContentType('application', 'xml', charset: 'utf-8');
      req.add(utf8.encode('<?xml version="1.0" encoding="utf-8"?><D:propfind xmlns:D="DAV:"><D:prop>'
          '<D:displayname/><D:resourcetype/><D:getcontentlength/></D:prop></D:propfind>'));
      final res = await req.close().timeout(const Duration(seconds: 30));
      final body = await res.transform(utf8.decoder).join();
      if (res.statusCode == 401) throw const WebDavError('아이디 또는 비밀번호가 틀렸습니다');
      if (res.statusCode == 404) throw const WebDavError('그 폴더가 없습니다');
      if (res.statusCode != 207 && res.statusCode != 200) throw WebDavError('서버가 거절했습니다 (${res.statusCode})');
      return parse(body, uriOf(path).path);
    } on HandshakeException {
      throw const WebDavError('인증서를 믿을 수 없습니다. NAS 가 직접 만든 인증서라면 "인증서 확인 안 함" 을 켜세요');
    } on SocketException catch (e) {
      throw WebDavError('연결하지 못했습니다: ${e.message}');
    } on TimeoutException {
      throw const WebDavError('응답이 없습니다 (주소 · 포트를 확인하세요)');
    } finally {
      c.close(force: true);
    }
  }

  /// PROPFIND 응답(XML) → 목록. 자기 자신([selfPath])은 뺀다
  static List<DavEntry> parse(String xml, String selfPath) {
    final doc = XmlDocument.parse(xml);
    String norm(String s) => Uri.decodeFull(s).replaceAll(RegExp(r'/+$'), '');
    final self = norm(selfPath);
    final out = <DavEntry>[];
    for (final r in doc.findAllElements('response', namespaceUri: '*')) {
      final href = r.findElements('href', namespaceUri: '*').firstOrNull?.innerText.trim();
      if (href == null || href.isEmpty) continue;
      // 전체 주소로 오는 서버도 있다
      final path = href.startsWith('http') ? Uri.parse(href).path : href;
      if (norm(path) == self) continue;
      final dir = r.findAllElements('collection', namespaceUri: '*').isNotEmpty;
      final shown = r.findAllElements('displayname', namespaceUri: '*').firstOrNull?.innerText.trim() ?? '';
      final last = Uri.decodeFull(path.replaceAll(RegExp(r'/+$'), '').split('/').last);
      final size = int.tryParse(r.findAllElements('getcontentlength', namespaceUri: '*').firstOrNull?.innerText.trim() ?? '') ?? 0;
      final full = Uri.decodeFull(path);
      out.add(DavEntry(dir && !full.endsWith('/') ? '$full/' : full, shown.isNotEmpty ? shown : last, dir, size));
    }
    out.sort((a, b) => a.dir != b.dir ? (a.dir ? -1 : 1) : a.name.toLowerCase().compareTo(b.name.toLowerCase()));
    return out;
  }

  /// 폴더 아래 모든 파일 (하위 폴더까지, [want] 로 거름)
  Future<List<DavEntry>> walk(String path, bool Function(DavEntry) want, {bool Function()? cancelled}) async {
    final out = <DavEntry>[];
    final todo = [path];
    // 이미 연 폴더는 다시 열지 않는다 (자기 자신을 다른 꼴의 주소로 돌려주는 서버에서 끝없이 돌지 않게)
    String key(String x) => Uri.decodeFull(x).replaceAll(RegExp(r'/+'), '/').replaceAll(RegExp(r'/$'), '').toLowerCase();
    final seen = {key(path)};
    final files = <String>{};
    while (todo.isNotEmpty && !(cancelled?.call() ?? false)) {
      for (final e in await list(todo.removeLast())) {
        if (e.dir) {
          if (seen.add(key(e.path))) todo.add(e.path);
        } else if (want(e) && files.add(key(e.path))) {
          out.add(e);
        }
      }
    }
    return out;
  }

  /// 파일 받기 ([to] 경로로, 받는 중엔 .part)
  Future<void> download(DavEntry e, String to, {void Function(int got, int total)? onProgress, bool Function()? cancelled}) async {
    final c = _client();
    final part = File('$to.part');
    try {
      await Directory(p.dirname(to)).create(recursive: true);
      final req = await c.getUrl(uriOf(e.path));
      _auth(req);
      final res = await req.close();
      if (res.statusCode != 200) throw WebDavError('받지 못했습니다 (${res.statusCode})');
      final total = res.contentLength > 0 ? res.contentLength : e.size;
      final sink = part.openWrite();
      var got = 0;
      try {
        await for (final chunk in res) {
          if (cancelled?.call() ?? false) throw const WebDavError('멈춤');
          sink.add(chunk);
          got += chunk.length;
          onProgress?.call(got, total);
        }
      } finally {
        await sink.close();
      }
      if (await File(to).exists()) await File(to).delete();
      await part.rename(to);
    } catch (_) {
      if (await part.exists()) await part.delete();
      rethrow;
    } finally {
      c.close(force: true);
    }
  }
}

class WebDavError implements Exception {
  final String message;
  const WebDavError(this.message);
  @override
  String toString() => message;
}
