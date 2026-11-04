import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

import '../app_state.dart';
import '../models/media_item.dart';
import '../models/series.dart';

/// 같은 Wi-Fi 의 다른 기기에서 라이브러리를 보는 서버
/// - Web : 브라우저로 둘러보기 · 검색 · 내려받기   http://PC주소:포트/
/// - OPDS: Panels, ComicGlass, KyBook 같은 리더 앱  http://PC주소:포트/opds
/// 숨김 항목은 내보내지 않는다. 앱 계정으로 로그인하면 그 계정의 접근 규칙(폴더·종류·묶음)을 따른다.
class ShareServer {
  final AppState app;
  ShareServer(this.app);

  HttpServer? _server;
  final logs = <String>[];
  final _logCtrl = StreamController<void>.broadcast();
  Stream<void> get changes => _logCtrl.stream;

  bool get running => _server != null;
  int get port => _server?.port ?? 0;

  String user = '';
  String password = '';

  /// 공용 아이디(또는 비밀번호 없이) 접속한 사람에게 적용할 앱 사용자의 접근 규칙. null = 숨김만 빼고 전부
  int? asUserId;

  void _log(String m) {
    final t = DateTime.now();
    logs.insert(0, '[${t.hour.toString().padLeft(2, '0')}:${t.minute.toString().padLeft(2, '0')}:${t.second.toString().padLeft(2, '0')}] $m');
    if (logs.length > 300) logs.removeLast();
    _logCtrl.add(null);
  }

  Future<void> start(int port) async {
    await stop();
    forgetLogins();
    _server = await HttpServer.bind(InternetAddress.anyIPv4, port);
    _log('서버 시작: 포트 $port');
    _server!.listen(_handle, onError: (e) => _log('오류: $e'));
    _logCtrl.add(null);
  }

  Future<void> stop() async {
    if (_server == null) return;
    await _server!.close(force: true);
    _server = null;
    _log('서버 중지');
  }

  /// 이 PC 의 내부 IP 주소들 (같은 Wi-Fi 에서 접속할 주소)
  static Future<List<String>> addresses() async {
    final out = <String>[];
    for (final ni in await NetworkInterface.list(type: InternetAddressType.IPv4)) {
      for (final a in ni.addresses) {
        if (!a.isLoopback) out.add('${ni.name} - ${a.address}');
      }
    }
    return out;
  }

  // ---------------- 보이는 것 (숨김 제외 + 접속한 사용자의 접근 규칙) ----------------
  bool _ok(MediaItem e, AccessView v) => !app.isHiddenItem(e) && !e.missing && v.item(e);
  bool _sOk(Series s, AccessView v) => !app.isHiddenSeries(s) && v.series(s) && _count(s, v) > 0;
  List<MediaItem> _items(AccessView v) => app.rawItems.where((e) => _ok(e, v)).toList();
  List<Series> _children(int? id, AccessView v) =>
      (app.rawTree.children[id] ?? const <Series>[]).where((s) => _sOk(s, v)).toList()..sort((a, b) => a.title.compareTo(b.title));
  List<MediaItem> _itemsIn(int? id, AccessView v) => (app.rawTree.items[id] ?? const <MediaItem>[]).where((e) => _ok(e, v)).toList()
    ..sort((a, b) => (a.volume ?? 0).compareTo(b.volume ?? 0) != 0 ? (a.volume ?? 0).compareTo(b.volume ?? 0) : a.title.compareTo(b.title));

  /// 묶음마다 이 사람이 볼 수 있는 권 수 (요청마다 한 번만 계산)
  final Expando<Map<int, int>> _counts = Expando();
  int _count(Series s, AccessView v) {
    final m = _counts[v] ??= () {
      final out = <int, int>{};
      for (final e in app.rawItems) {
        if (!_ok(e, v)) continue;
        var cur = e.seriesId;
        final seen = <int>{};
        while (cur != null && seen.add(cur)) {
          out[cur] = (out[cur] ?? 0) + 1;
          cur = app.seriesById(cur)?.parentId;
        }
      }
      return out;
    }();
    return m[s.id] ?? 0;
  }

  Series? _series(int? id, AccessView v) {
    final s = app.seriesById(id);
    return s != null && _sOk(s, v) ? s : null;
  }

  /// 확인된 로그인 (비밀번호 해시는 느려서 요청마다 다시 계산하지 않는다)
  final Map<String, int> _verified = {};
  final Set<String> _rejected = {};
  void forgetLogins() {
    _verified.clear();
    _rejected.clear();
  }

  /// 누가 접속했는지 → 그 사람의 접근 규칙. 들어올 수 없으면 null
  Future<AccessView?> _viewer(HttpRequest req) async {
    String? name, pw;
    final h = req.headers.value(HttpHeaders.authorizationHeader) ?? '';
    if (h.startsWith('Basic ')) {
      try {
        final t = utf8.decode(base64.decode(h.substring(6)));
        final i = t.indexOf(':');
        if (i > 0) {
          name = t.substring(0, i);
          pw = t.substring(i + 1);
        }
      } catch (_) {}
    }
    // 공용 접속에 적용할 계정이 지워졌거나 관리자가 됐으면 막는다 (모두 열리지 않게)
    final asUser = app.users.where((u) => u.id == asUserId).firstOrNull;
    final asBroken = asUserId != null && (asUser == null || asUser.isAdmin);
    if (name != null) {
      if (user.isNotEmpty && name == user && pw == password) return asBroken ? null : app.accessFor(asUser);
      // 앱 계정으로 로그인하면 그 계정의 규칙
      final known = _verified[h];
      if (known != null) {
        final u = app.users.where((u) => u.id == known).firstOrNull;
        if (u != null) return app.accessFor(u);
      }
      if (!_rejected.contains(h)) {
        final u = app.users.where((u) => u.name == name).firstOrNull;
        if (u != null && u.hasPassword && u.check(pw ?? '')) {
          _verified[h] = u.id!;
          return app.accessFor(u);
        }
        if (_rejected.length > 200) _rejected.clear();
        _rejected.add(h);
      }
    }
    if (user.isEmpty) return asBroken ? null : app.accessFor(asUser);
    return null;
  }

  // ---------------- 요청 처리 ----------------
  Future<void> _handle(HttpRequest req) async {
    final res = req.response;
    try {
      final v = await _viewer(req);
      if (v == null) {
        res.statusCode = HttpStatus.unauthorized;
        res.headers.set('WWW-Authenticate', 'Basic realm="ARARIFlex"');
        await res.close();
        return;
      }
      final path = req.uri.path;
      final seg = req.uri.pathSegments;
      _log('${req.connectionInfo?.remoteAddress.address ?? '?'} ${req.method} $path');

      if (path == '/' || path.isEmpty) return await _html(res, _webPage(v, null, req.uri.queryParameters['q']));
      if (seg.length == 2 && seg[0] == 's') return await _html(res, _webPage(v, int.tryParse(seg[1]), null));
      if (seg.length == 2 && seg[0] == 'file') return await _file(res, v, int.tryParse(seg[1]), download: true);
      if (seg.length == 2 && seg[0] == 'cover') return await _cover(res, v, int.tryParse(seg[1]), series: false);
      if (seg.length == 2 && seg[0] == 'scover') return await _cover(res, v, int.tryParse(seg[1]), series: true);
      if (seg.isNotEmpty && seg[0] == 'opds') {
        if (seg.length == 1) return await _atom(res, _opdsFeed(v, null, req.uri.queryParameters['q']));
        if (seg.length == 3 && seg[1] == 's') return await _atom(res, _opdsFeed(v, int.tryParse(seg[2]), null));
        if (seg.length == 2 && seg[1] == 'search.xml') return await _atom(res, _openSearch(), type: 'application/opensearchdescription+xml');
      }
      res.statusCode = HttpStatus.notFound;
      res.write('Not found');
      await res.close();
    } catch (e) {
      _log('처리 실패: $e');
      try {
        res.statusCode = HttpStatus.internalServerError;
        await res.close();
      } catch (_) {}
    }
  }

  Future<void> _html(HttpResponse res, String body) async {
    res.headers.contentType = ContentType.html;
    res.write(body);
    await res.close();
  }

  Future<void> _atom(HttpResponse res, String body, {String type = 'application/atom+xml;profile=opds-catalog'}) async {
    res.headers.set(HttpHeaders.contentTypeHeader, '$type; charset=utf-8');
    res.write(body);
    await res.close();
  }

  MediaItem? _item(int? id, AccessView v) {
    final e = id == null ? null : app.rawItemById(id);
    return e != null && _ok(e, v) ? e : null;
  }

  Future<void> _file(HttpResponse res, AccessView v, int? id, {required bool download}) async {
    final e = _item(id, v);
    if (e == null || !await File(e.path).exists()) {
      res.statusCode = HttpStatus.notFound;
      await res.close();
      return;
    }
    res.headers.set(HttpHeaders.contentTypeHeader, _mime(e.extension));
    res.headers.set(HttpHeaders.contentLengthHeader, (await File(e.path).length()).toString());
    if (download) {
      res.headers.set('Content-Disposition', "attachment; filename*=UTF-8''${Uri.encodeComponent(e.fileName)}");
    }
    await res.addStream(File(e.path).openRead());
    await res.close();
  }

  Future<void> _cover(HttpResponse res, AccessView v, int? id, {required bool series}) async {
    String? path;
    if (series) {
      final s = _series(id, v);
      // 묶음 표지가 없으면 이 사람이 볼 수 있는 권의 표지만 쓴다 (숨긴 권 표지가 새지 않게)
      if (s != null) path = s.coverPath ?? app.itemsUnderSeries(s.id!).where((e) => _ok(e, v) && e.coverPath != null).firstOrNull?.coverPath;
    } else {
      path = _item(id, v)?.coverPath;
    }
    if (path == null || !await File(path).exists()) {
      res.statusCode = HttpStatus.notFound;
      await res.close();
      return;
    }
    res.headers.set(HttpHeaders.contentTypeHeader, _mime(p.extension(path)));
    res.headers.set(HttpHeaders.cacheControlHeader, 'max-age=86400');
    await res.addStream(File(path).openRead());
    await res.close();
  }

  static String _mime(String ext) => switch (ext.toLowerCase()) {
        '.epub' => 'application/epub+zip',
        '.pdf' => 'application/pdf',
        '.cbz' || '.zip' => 'application/vnd.comicbook+zip',
        '.cbr' || '.rar' => 'application/vnd.comicbook-rar',
        '.txt' => 'text/plain; charset=utf-8',
        '.jpg' || '.jpeg' => 'image/jpeg',
        '.png' => 'image/png',
        '.webp' => 'image/webp',
        '.gif' => 'image/gif',
        '.mp4' || '.m4v' => 'video/mp4',
        '.mkv' => 'video/x-matroska',
        _ => 'application/octet-stream',
      };

  static String _esc(String s) => const HtmlEscape().convert(s);

  // ---------------- Web 페이지 ----------------
  String _webPage(AccessView v, int? seriesId, String? q) {
    final s = _series(seriesId, v);
    if (s == null) seriesId = null;
    final query = (q ?? '').trim().toLowerCase();
    final series = query.isNotEmpty ? <Series>[] : _children(seriesId, v);
    final items = query.isNotEmpty
        ? _items(v).where((e) => e.title.toLowerCase().contains(query) || e.fileName.toLowerCase().contains(query)).take(300).toList()
        : _itemsIn(seriesId, v);
    final crumbs = <String>['<a href="/">전체</a>'];
    var cur = s;
    final chain = <Series>[];
    while (cur != null) {
      chain.insert(0, cur);
      cur = _series(cur.parentId, v);
    }
    for (final c in chain) {
      crumbs.add('<a href="/s/${c.id}">${_esc(c.title)}</a>');
    }
    final cards = StringBuffer();
    for (final c in series) {
      final n = _count(c, v);
      cards.write('<a class="card" href="/s/${c.id}"><img loading="lazy" src="/scover/${c.id}" onerror="this.style.visibility=\'hidden\'">'
          '<div class="badge">📁 $n</div><div class="t">${_esc(c.title)}</div></a>');
    }
    for (final e in items) {
      cards.write('<a class="card" href="/file/${e.id}" title="${_esc(e.fileName)}"><img loading="lazy" src="/cover/${e.id}" onerror="this.style.visibility=\'hidden\'">'
          '<div class="badge">${e.extension.substring(1).toUpperCase()}</div><div class="t">${_esc(e.volumeLabel != null && e.seriesId != null ? '${e.volumeLabel} ${e.title}' : e.title)}</div></a>');
    }
    return '''<!doctype html><html lang="ko"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
<title>ARARIFlex${s != null ? ' - ${_esc(s.title)}' : ''}</title>
<style>
body{margin:0;background:#141414;color:#eee;font-family:system-ui,-apple-system,"Malgun Gothic",sans-serif}
header{display:flex;gap:16px;align-items:center;padding:14px 20px;background:#0b0b0b;position:sticky;top:0}
.logo{color:#fff;font-weight:900;font-size:22px;letter-spacing:1px;text-decoration:none}
form{margin-left:auto}input{background:#222;border:1px solid #444;color:#eee;padding:8px 12px;border-radius:6px;width:220px}
nav{padding:10px 20px;color:#aaa}nav a{color:#ddd;text-decoration:none}nav a+a:before{content:" › ";color:#666}
.grid{display:grid;grid-template-columns:repeat(auto-fill,minmax(140px,1fr));gap:16px;padding:12px 20px 40px}
.card{position:relative;display:block;aspect-ratio:2/3;border-radius:6px;overflow:hidden;background:#222;color:#fff;text-decoration:none;box-shadow:0 3px 8px #0008}
.card img{width:100%;height:100%;object-fit:cover}
.card .t{position:absolute;left:0;right:0;bottom:0;padding:28px 8px 8px;font-weight:700;font-size:13px;text-align:center;background:linear-gradient(transparent,#000d)}
.badge{position:absolute;top:6px;right:6px;background:#000b;padding:2px 6px;border-radius:5px;font-size:11px}
</style></head><body>
<header><a class="logo" href="/"><b style="color:#fff">ARARI</b> <i style="background:linear-gradient(90deg,#b20710,#ff4d5a);-webkit-background-clip:text;color:transparent">Flex</i></a><form action="/"><input name="q" placeholder="검색" value="${_esc(q ?? '')}"></form></header>
<nav>${crumbs.join('')}</nav>
<div class="grid">$cards</div>
${series.isEmpty && items.isEmpty ? '<p style="padding:20px;color:#888">항목이 없습니다.</p>' : ''}
</body></html>''';
  }

  // ---------------- OPDS ----------------
  String _opdsFeed(AccessView v, int? seriesId, String? q) {
    final s = _series(seriesId, v);
    if (s == null) seriesId = null;
    final now = DateTime.now().toUtc().toIso8601String();
    final query = (q ?? '').trim().toLowerCase();
    final b = StringBuffer()
      ..write('<?xml version="1.0" encoding="UTF-8"?>\n'
          '<feed xmlns="http://www.w3.org/2005/Atom" xmlns:opds="http://opds-spec.org/2010/catalog" xmlns:dc="http://purl.org/dc/terms/">'
          '<id>urn:mediashelf:${seriesId ?? 'root'}</id><title>${_esc(s?.title ?? 'ARARIFlex')}</title><updated>$now</updated>'
          '<link rel="start" href="/opds" type="application/atom+xml;profile=opds-catalog;kind=navigation"/>'
          '<link rel="search" href="/opds/search.xml" type="application/opensearchdescription+xml"/>');
    if (query.isEmpty) {
      for (final c in _children(seriesId, v)) {
        b.write('<entry><title>${_esc(c.title)}</title><id>urn:mediashelf:s:${c.id}</id><updated>$now</updated>'
            '<content type="text">${_count(c, v)}권</content>'
            '<link rel="subsection" href="/opds/s/${c.id}" type="application/atom+xml;profile=opds-catalog;kind=acquisition"/>'
            '<link rel="http://opds-spec.org/image/thumbnail" href="/scover/${c.id}" type="image/jpeg"/></entry>');
      }
    }
    final items = query.isNotEmpty ? _items(v).where((e) => e.title.toLowerCase().contains(query)).take(200) : _itemsIn(seriesId, v);
    for (final e in items) {
      b.write('<entry><title>${_esc(e.title)}</title><id>urn:mediashelf:i:${e.id}</id><updated>$now</updated>'
          '${e.author != null ? '<author><name>${_esc(e.author!)}</name></author>' : ''}'
          '${e.description != null ? '<summary>${_esc(e.description!)}</summary>' : ''}'
          '<link rel="http://opds-spec.org/acquisition" href="/file/${e.id}" type="${_mime(e.extension)}"/>'
          '<link rel="http://opds-spec.org/image" href="/cover/${e.id}" type="image/jpeg"/>'
          '<link rel="http://opds-spec.org/image/thumbnail" href="/cover/${e.id}" type="image/jpeg"/></entry>');
    }
    b.write('</feed>');
    return b.toString();
  }

  String _openSearch() => '<?xml version="1.0" encoding="UTF-8"?>'
      '<OpenSearchDescription xmlns="http://a9.com/-/spec/opensearch/1.1/"><ShortName>ARARIFlex</ShortName>'
      '<Url type="application/atom+xml;profile=opds-catalog" template="/opds?q={searchTerms}"/></OpenSearchDescription>';
}
