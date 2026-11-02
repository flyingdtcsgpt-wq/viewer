import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive_io.dart';
import 'package:path/path.dart' as p;
import 'package:xml/xml.dart';

/// EPUB 을 풀지 않고 안의 파일을 꺼내 주는 도우미 (원본 스타일 보기용)
class EpubBook {
  final String path;
  final InputFileStream _input;
  final Archive _zip;
  final List<String> spine; // 읽는 순서대로 장 파일 경로
  final List<(String title, int spineIndex)> toc;

  EpubBook._(this.path, this._input, this._zip, this.spine, this.toc);

  static EpubBook open(String path) {
    final input = InputFileStream(path);
    final zip = ZipDecoder().decodeStream(input);
    String read(String n) => utf8.decode(zip.findFile(n)?.content ?? Uint8List(0), allowMalformed: true);
    final container = XmlDocument.parse(read('META-INF/container.xml'));
    final opfPath = container.findAllElements('rootfile', namespaceUri: '*').first.getAttribute('full-path')!;
    final opfDir = p.posix.dirname(opfPath);
    String resolve(String base, String href) => p.posix.normalize(p.posix.join(base == '.' ? '' : base, Uri.decodeFull(href.split('#').first)));
    final opf = XmlDocument.parse(read(opfPath));

    final manifest = <String, String>{};
    String? nav, ncx;
    for (final it in opf.findAllElements('item', namespaceUri: '*')) {
      final id = it.getAttribute('id'), href = it.getAttribute('href');
      if (id == null || href == null) continue;
      manifest[id] = resolve(opfDir, href);
      if ((it.getAttribute('properties') ?? '').contains('nav')) nav = manifest[id];
      if (it.getAttribute('media-type') == 'application/x-dtbncx+xml') ncx = manifest[id];
    }
    final spine = opf.findAllElements('itemref', namespaceUri: '*').map((e) => manifest[e.getAttribute('idref')]).whereType<String>().toList();

    // 목차: nav(EPUB3) → ncx(EPUB2) → 없으면 장 파일 이름
    final toc = <(String, int)>[];
    void add(String title, String href) {
      final i = spine.indexOf(href);
      if (i >= 0 && title.trim().isNotEmpty) toc.add((title.trim(), i));
    }

    try {
      if (nav != null) {
        final d = XmlDocument.parse(read(nav), entityMapping: const XmlDefaultEntityMapping.html5());
        for (final a in d.findAllElements('a', namespaceUri: '*')) {
          final h = a.getAttribute('href');
          if (h != null) add(a.innerText, resolve(p.posix.dirname(nav), h));
        }
      } else if (ncx != null) {
        final d = XmlDocument.parse(read(ncx));
        for (final np in d.findAllElements('navPoint', namespaceUri: '*')) {
          final t = np.findElements('navLabel', namespaceUri: '*').firstOrNull?.innerText ?? '';
          final src = np.findElements('content', namespaceUri: '*').firstOrNull?.getAttribute('src');
          if (src != null) add(t, resolve(p.posix.dirname(ncx), src));
        }
      }
    } catch (_) {}
    if (toc.isEmpty) {
      for (var i = 0; i < spine.length; i++) {
        toc.add((p.posix.basenameWithoutExtension(spine[i]), i));
      }
    }
    return EpubBook._(path, input, zip, spine, toc);
  }

  Uint8List? file(String name) => _zip.findFile(name)?.content;

  void close() => _input.closeSync();

  static String mime(String name) => switch (p.extension(name).toLowerCase()) {
        '.xhtml' || '.xml' => 'application/xhtml+xml; charset=utf-8',
        '.html' || '.htm' => 'text/html; charset=utf-8',
        '.css' => 'text/css; charset=utf-8',
        '.js' => 'text/javascript',
        '.jpg' || '.jpeg' => 'image/jpeg',
        '.png' => 'image/png',
        '.gif' => 'image/gif',
        '.webp' => 'image/webp',
        '.svg' => 'image/svg+xml',
        '.ttf' => 'font/ttf',
        '.otf' => 'font/otf',
        '.woff' => 'font/woff',
        '.woff2' => 'font/woff2',
        _ => 'application/octet-stream',
      };
}

/// 127.0.0.1 에서만 열리는 작은 서버: EPUB 안 파일을 WebView 에 그대로 준다 (압축 풀지 않음)
class EpubLocalServer {
  final EpubBook book;
  HttpServer? _server;
  EpubLocalServer(this.book);

  /// 장 파일에 끼워 넣을 스크립트: 스크롤 위치를 앱에 알려주고, 열 때 위치 복원
  static const _script = '''
<script><![CDATA[
(function(){
  var q = new URLSearchParams(location.search); var r = parseFloat(q.get('r') || '0');
  function total(){ return Math.max(1, document.documentElement.scrollHeight - window.innerHeight); }
  window.addEventListener('load', function(){ if (r > 0) window.scrollTo(0, total() * r); });
  var t = null;
  window.addEventListener('scroll', function(){
    if (t) clearTimeout(t);
    t = setTimeout(function(){ try { window.chrome.webview.postMessage(JSON.stringify({t:'scroll', r: window.scrollY / total()})); } catch(e){} }, 300);
  });
  document.addEventListener('keydown', function(e){
    try { window.chrome.webview.postMessage(JSON.stringify({t:'key', k: e.key})); } catch(x){}
  });
})();
]]></script>''';

  Future<int> start() async {
    _server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    _server!.listen((req) async {
      final res = req.response;
      final name = Uri.decodeComponent(req.uri.path.replaceFirst('/', ''));
      final data = book.file(name);
      if (data == null) {
        res.statusCode = HttpStatus.notFound;
        await res.close();
        return;
      }
      final type = EpubBook.mime(name);
      res.headers.set(HttpHeaders.contentTypeHeader, type);
      res.headers.set(HttpHeaders.cacheControlHeader, 'no-store');
      if (type.contains('html')) {
        var html = utf8.decode(data, allowMalformed: true);
        final at = html.toLowerCase().lastIndexOf('</body>');
        html = at >= 0 ? '${html.substring(0, at)}$_script${html.substring(at)}' : '$html$_script';
        res.add(utf8.encode(html));
      } else {
        res.add(data);
      }
      await res.close();
    });
    return _server!.port;
  }

  Future<void> stop() async => _server?.close(force: true);
}
