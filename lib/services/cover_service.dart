import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:archive/archive_io.dart';
import 'package:crypto/crypto.dart';
import 'package:fc_native_video_thumbnail/fc_native_video_thumbnail.dart';
import 'package:http/http.dart' as http;
import 'package:image/image.dart' as img;
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:pdfrx/pdfrx.dart';
import 'package:xml/xml.dart';

import '../models/media_item.dart';
import 'ext_archive.dart';

/// EPUB 내부 메타데이터 (파일 자체에서 뽑아낸 정보)
class EmbeddedInfo {
  String? title;
  String? author;
  String? publisher;
  String? isbn;
  String? description;
}

/// 커버(썸네일)를 만들어 앱 캐시 폴더에 저장한다. 원본 파일은 건드리지 않는다.
class CoverService {
  late final Directory _dir;
  final _video = FcNativeVideoThumbnail();

  Future<void> init() async {
    final base = await getApplicationSupportDirectory();
    _dir = Directory(p.join(base.path, 'covers'));
    await _dir.create(recursive: true);
  }

  /// 항목을 지울 때 그 항목용으로 만든 표지 파일도 지운다 (원본 그림 자체는 건드리지 않음)
  void forget(MediaItem e) {
    final c = e.coverPath;
    if (c == null || c == e.path || !p.isWithin(_dir.path, c)) return;
    File(c).delete().catchError((_) => File(c));
  }

  String _target(String key, String ext) =>
      p.join(_dir.path, '${sha1.convert(utf8.encode(key)).toString()}$ext');

  /// 반환: 커버 이미지 경로 (없으면 null)
  Future<String?> generate(MediaItem item) async {
    try {
      switch (item.kind) {
        case MediaKind.image:
          // 큰 사진을 목록마다 다시 풀지 않게 작은 표지를 따로 만든다 (못 읽는 형식이면 원본)
          final small = await _thumbFile(item.path, () async => await File(item.path).readAsBytes());
          return small ?? item.path;
        case MediaKind.video:
          final out = _target(item.path, '.jpg');
          final ok = await _video.saveThumbnailToFile(
              srcFile: item.path, destFile: out, width: 480, height: 480, format: 'jpeg', quality: 85);
          return ok ? out : null;
        case MediaKind.book:
        case MediaKind.comic:
          return await switch (item.extension) {
            '.epub' => _epubCover(item.path),
            '.cbz' || '.zip' => _zipCover(item),
            '.pdf' => _pdfFirstPage(item.path),
            '.cbr' || '.rar' || '.cb7' || '.7z' when ExtArchive.supported => _extCover(item.path),
            _ => null, // TXT, RAR 등은 인터넷 검색 또는 수동 지정
          };
      }
    } catch (_) {
      return null;
    }
  }

  /// 쪽수: 만화 zip/cbz 는 이미지 수, PDF 는 페이지 수. 모르면 null
  Future<int?> pageCount(MediaItem item) async {
    try {
      switch (item.extension) {
        case '.cbz' || '.zip':
          final path = item.path;
          return (await Isolate.run(() => _zipProbe(path, cover: false))).pages;
        case '.cbr' || '.rar' || '.cb7' || '.7z' when ExtArchive.supported:
          return (await ExtArchive.listImages(item.path)).length;
        case '.pdf':
          final doc = await PdfDocument.openFile(item.path);
          try {
            return doc.pages.length;
          } finally {
            doc.dispose();
          }
      }
    } catch (_) {}
    return null;
  }

  /// 인터넷 커버 이미지를 내려받아 캐시에 저장
  Future<String?> download(String url, String key) async {
    final res = await http.get(Uri.parse(url));
    if (res.statusCode != 200 || res.bodyBytes.isEmpty) return null;
    final out = _target('$key|$url', '.jpg');
    await File(out).writeAsBytes(res.bodyBytes);
    return out;
  }

  /// 편집한 그림(바이트)을 커버로 저장
  Future<String> importBytes(List<int> bytes, String key) async {
    final out = _target('$key|edit|${DateTime.now().millisecondsSinceEpoch}', '.jpg');
    await File(out).writeAsBytes(bytes);
    return out;
  }

  /// 사용자가 고른 이미지 파일을 커버로 복사
  Future<String> importLocal(String imagePath, String key) async {
    final out = _target('$key|$imagePath', p.extension(imagePath));
    await File(imagePath).copy(out);
    return out;
  }

  // ---------- EPUB ----------
  Future<String?> _epubCover(String path) => _thumbFile(path, () => Isolate.run(() => _epubCoverBytes(path)));

  /// EPUB 의 OPF 에서 제목/저자 등 읽기 (화면이 멈추지 않게 따로)
  Future<EmbeddedInfo?> readEpubInfo(String path) => Isolate.run(() => _readEpubInfoSync(path));
}

EmbeddedInfo? _readEpubInfoSync(String path) {
    final input = InputFileStream(path);
    try {
      final zip = ZipDecoder().decodeStream(input);
      final opfPath = _opfPath(zip);
      if (opfPath == null) return null;
      final opf = XmlDocument.parse(utf8.decode(zip.findFile(opfPath)!.content, allowMalformed: true));
      String? dc(String name) =>
          opf.findAllElements(name, namespaceUri: '*').map((e) => e.innerText.trim()).where((s) => s.isNotEmpty).firstOrNull;
      final info = EmbeddedInfo()
        ..title = dc('title')
        ..author = dc('creator')
        ..publisher = dc('publisher')
        ..description = dc('description');
      final ids = opf.findAllElements('identifier', namespaceUri: '*').map((e) => e.innerText);
      info.isbn = ids
          .map((s) => s.replaceAll(RegExp(r'[^0-9Xx]'), ''))
          .where((s) => s.length == 13 || s.length == 10)
          .firstOrNull;
      return info;
    } catch (_) {
      return null;
    } finally {
      input.closeSync();
    }
}

String? _opfPath(Archive zip) {
  final container = zip.findFile('META-INF/container.xml');
  if (container == null) return null;
  final doc = XmlDocument.parse(utf8.decode(container.content, allowMalformed: true));
  return doc.findAllElements('rootfile', namespaceUri: '*').firstOrNull?.getAttribute('full-path');
}

/// EPUB 표지 그림 데이터 (별도 isolate 에서)
Uint8List? _epubCoverBytes(String path) {
  final input = InputFileStream(path);
  try {
    final zip = ZipDecoder().decodeStream(input);
    final opfPath = _opfPath(zip);
    if (opfPath == null) return null;
    final opf = XmlDocument.parse(utf8.decode(zip.findFile(opfPath)!.content, allowMalformed: true));
    final items = opf.findAllElements('item', namespaceUri: '*').toList();
    // EPUB3: properties="cover-image" / EPUB2: <meta name="cover" content="id">
    XmlElement? coverItem = items.where((e) => (e.getAttribute('properties') ?? '').contains('cover-image')).firstOrNull;
    if (coverItem == null) {
      final id = opf
          .findAllElements('meta', namespaceUri: '*')
          .where((e) => e.getAttribute('name') == 'cover')
          .map((e) => e.getAttribute('content'))
          .firstOrNull;
      coverItem = items.where((e) => e.getAttribute('id') == id).firstOrNull;
    }
    coverItem ??= items
        .where((e) => (e.getAttribute('media-type') ?? '').startsWith('image/') && (e.getAttribute('href') ?? '').toLowerCase().contains('cover'))
        .firstOrNull;
    final href = coverItem?.getAttribute('href');
    if (href == null) return null;
    final full = p.posix.normalize(p.posix.join(p.posix.dirname(opfPath), Uri.decodeFull(href)));
    return zip.findFile(full)?.content;
  } catch (_) {
    return null;
  } finally {
    input.closeSync();
  }
}

/// 압축 만화 한 번 열어서: 그림 수 + 첫 그림 (별도 isolate 에서)
({int pages, Uint8List? first}) _zipProbe(String path, {bool cover = true}) {
  final input = InputFileStream(path);
  try {
    final zip = ZipDecoder().decodeStream(input);
    final images = zip.files.where((f) => f.isFile && imageExts.contains(p.extension(f.name).toLowerCase())).toList()
      ..sort((a, b) => _naturalCompare(a.name, b.name));
    return (pages: images.length, first: cover && images.isNotEmpty ? images.first.content : null);
  } finally {
    input.closeSync();
  }
}

/// 그림 → 폭 480 이하 JPEG (표지용, 별도 isolate 에서)
Uint8List? _thumbBytes(Uint8List bytes) {
  final im = img.decodeImage(bytes);
  if (im == null) return null;
  final small = im.width > 480 ? img.copyResize(im, width: 480, interpolation: img.Interpolation.average) : im;
  return img.encodeJpg(small, quality: 82);
}

extension _CoverMore on CoverService {
  /// 그림 데이터를 작은 표지 파일로 저장 (실패하면 null)
  Future<String?> _thumbFile(String key, Future<Uint8List?> Function() bytes) async {
    final b = await bytes();
    if (b == null) return null;
    final t = await Isolate.run(() => _thumbBytes(b));
    if (t == null) return null;
    final out = _target(key, '.jpg');
    await File(out).writeAsBytes(t);
    return out;
  }

  // ---------- CBZ / ZIP: 한 번 열어 쪽수와 표지를 같이 ----------
  Future<String?> _zipCover(MediaItem item) async {
    final path = item.path;
    final r = await Isolate.run(() => _zipProbe(path));
    item.pages ??= r.pages;
    final first = r.first;
    if (first == null) return null;
    return _thumbFile(path, () async => first);
  }

  // ---------- RAR / 7Z (Windows 내장 tar) ----------
  Future<String?> _extCover(String path) async {
    final names = await ExtArchive.listImages(path);
    if (names.isEmpty) return null;
    return _thumbFile(path, () => ExtArchive.readOne(path, names.first));
  }

  // ---------- PDF ----------
  Future<String?> _pdfFirstPage(String path) async {
    final doc = await PdfDocument.openFile(path);
    try {
      if (doc.pages.isEmpty) return null;
      final page = doc.pages.first;
      const targetW = 480.0;
      final h = targetW * page.height / page.width;
      final img = await page.renderForDisplay(
        width: targetW.round(),
        height: h.round(),
        fullWidth: targetW,
        fullHeight: h,
        backgroundColor: 0xffffffff,
      );
      if (img == null) return null;
      final ByteData? png = await img.toByteData(format: ui.ImageByteFormat.png);
      img.dispose();
      if (png == null) return null;
      final out = _target(path, '.png');
      await File(out).writeAsBytes(png.buffer.asUint8List());
      return out;
    } finally {
      doc.dispose();
    }
  }
}

/// "page2.jpg" < "page10.jpg" 처럼 숫자를 숫자로 비교
int _naturalCompare(String a, String b) {
  final re = RegExp(r'(\d+)|(\D+)');
  final ma = re.allMatches(a.toLowerCase()).toList();
  final mb = re.allMatches(b.toLowerCase()).toList();
  for (var i = 0; i < ma.length && i < mb.length; i++) {
    final x = ma[i].group(0)!, y = mb[i].group(0)!;
    final nx = int.tryParse(x), ny = int.tryParse(y);
    final c = (nx != null && ny != null) ? nx.compareTo(ny) : x.compareTo(y);
    if (c != 0) return c;
  }
  return ma.length.compareTo(mb.length);
}
