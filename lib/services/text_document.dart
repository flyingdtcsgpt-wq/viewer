import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:archive/archive_io.dart';
import 'package:cp949_codec/cp949_codec.dart';
import 'package:path/path.dart' as p;
import 'package:xml/xml.dart';

/// 텍스트 뷰어가 그리는 최소 단위 (문단 하나 / 제목 하나 / 그림 하나)
class TextBlock {
  final String? text;
  final int heading; // 0 = 본문, 1~6 = 제목 크기
  final bool quote;
  final Uint8List? image;
  const TextBlock.text(this.text, {this.heading = 0, this.quote = false}) : image = null;
  const TextBlock.image(this.image)
      : text = null,
        heading = 0,
        quote = false;
  bool get isImage => image != null;
}

class TocEntry {
  final String title;
  final int block; // 시작 블록 번호
  const TocEntry(this.title, this.block);
}

class TextDocument {
  final List<TextBlock> blocks;
  final List<TocEntry> toc;
  final String encoding;
  const TextDocument(this.blocks, this.toc, this.encoding);

  /// 무거운 작업이라 별도 isolate 에서 읽는다 (UI 멈춤 방지)
  static Future<TextDocument> load(String path) {
    final ext = p.extension(path).toLowerCase();
    return Isolate.run(() => ext == '.epub' ? _loadEpub(path) : _loadTxt(path));
  }
}

// ======================= TXT =======================

/// BOM → UTF-8 시도 → 실패하면 CP949(EUC-KR) 로 읽는다
(String, String) decodeText(Uint8List bytes) {
  if (bytes.length >= 3 && bytes[0] == 0xEF && bytes[1] == 0xBB && bytes[2] == 0xBF) {
    return (utf8.decode(bytes.sublist(3), allowMalformed: true), 'UTF-8');
  }
  if (bytes.length >= 2 && bytes[0] == 0xFF && bytes[1] == 0xFE) {
    return (_utf16(bytes.sublist(2), little: true), 'UTF-16LE');
  }
  if (bytes.length >= 2 && bytes[0] == 0xFE && bytes[1] == 0xFF) {
    return (_utf16(bytes.sublist(2), little: false), 'UTF-16BE');
  }
  try {
    return (utf8.decode(bytes), 'UTF-8');
  } on FormatException {
    return (cp949.decode(bytes, allowInvalid: true), 'CP949');
  }
}

String _utf16(Uint8List b, {required bool little}) {
  final units = <int>[];
  for (var i = 0; i + 1 < b.length; i += 2) {
    units.add(little ? b[i] | (b[i + 1] << 8) : (b[i] << 8) | b[i + 1]);
  }
  return String.fromCharCodes(units);
}

// ---- 목차(장 제목) 알아보기: TXT 뷰어 목차 · TXT → EPUB · PDF → 텍스트가 같이 쓴다 ----
//
// 한 줄이 아래를 모두 만족하면 장 제목으로 본다 (TXT 에는 목차 정보가 없어서 줄의 모양으로 짐작한다):
//  1. 앞뒤 빈칸을 뺀 길이가 40자 이하
//  2. 꾸밈 기호(【 】 [ ] ■ ◆ = - * 등)를 떼고 난 줄의 "맨 앞"이 다음 중 하나
//     - 제1장 · 제 12 화 · 제3권/부/편/막/회/절 (한자 숫자도)
//     - 1화 · 12장 · 2부 · 3권 · 5편 · 1막 · 3회 ("제" 없이 숫자로 시작)
//     - 1. 제목 · 1.
//     - #1 · # 12 제목
//     - Chapter 3 · Part 2 · Ep.1 · Episode 4 · Act 1 · Vol.2 · Book 1 (로마 숫자 iv 도)
//     - Prologue · Epilogue · Interlude · Afterword · Foreword · Preface · Introduction
//     - 프롤로그 · 에필로그 · 서장 · 종장 · 외전 · 번외 · 막간 · 후일담 · 특별편 · 후기 · 서문 · 머리말 · 맺음말 · 작가의 말 · 작가 후기 · 들어가며 · 나가며
//     - 第一章 · 第3話 (한자)
//  3. 그 뒤에 글자가 바로 붙어 있지 않다 ("1장의 사진", "서장훈은…", "외전이라고…" 는 제목이 아니다)
//  4. 문장으로 끝나지 않는다 ("3회 반복했다.", "1. 그리고 떠났다." 는 제목이 아니다)
// 숫자만 있는 줄("12", "- 12 -")은 쪽 번호일 수 있어 제목으로 보지 않는다.
final _decoStart = RegExp(r'^[\s\[\(【〔<《「『■□◆◇●○★☆※▶▷=\-–—~*·]+');
final _decoEnd = RegExp(r'[\s\]\)】〕>》」』■□◆◇●○★☆※◀◁=\-–—~*·:]+$');
const _end = '(?![0-9A-Za-z가-힣])'; // 뒤에 글자 · 숫자가 바로 붙지 않는다
const _wordEnd = '(?![A-Za-z가-힣])'; // 낱말 뒤 (숫자는 붙어도 된다: "외전2")
const _num = '[0-9一二三四五六七八九十百千]+';
final _chapterStart = RegExp(
  '^(?:'
  '제\\s*$_num\\s*(?:장|화|권|부|편|막|회|절)$_end'
  '|[0-9]+\\s*(?:장|화|권|부|편|막|회)$_end'
  r'|[0-9]+\.(?:\s+\S|$)'
  '|#\\s*[0-9]+$_end'
  '|(?:chapter|chap\\.?|ch\\.|part|episode|ep\\.?|act|volume|vol\\.?|book)\\s*(?:[0-9]+|[ivxlc]+)$_end'
  '|(?:prologue|epilogue|interlude|afterword|foreword|preface|introduction)$_wordEnd'
  '|(?:프롤로그|에필로그|서장|종장|외전|번외|막간|후일담|특별편|후기|서문|머리말|맺음말|작가의 말|작가 후기|들어가며|나가며)$_wordEnd'
  '|第\\s*$_num\\s*[章話话回巻卷部節节幕]'
  ')',
  caseSensitive: false,
);
final _proseEnd = RegExp(r'\s.*(?:[다요죠]\.|[a-z]{2}\.)$|[,，]$', caseSensitive: false);

/// 이 줄이 장 제목(목차에 올릴 줄)인가. 규칙은 위 설명 참고
bool isChapterTitle(String line) {
  final t = line.trim();
  if (t.isEmpty || t.length > 40) return false;
  final core = t.replaceFirst(_decoStart, '').replaceFirst(_decoEnd, '');
  if (core.isEmpty) return false;
  return _chapterStart.hasMatch(core) && !_proseEnd.hasMatch(core);
}

TextDocument _loadTxt(String path) {
  final (text, enc) = decodeText(File(path).readAsBytesSync());
  final blocks = <TextBlock>[];
  final toc = <TocEntry>[];
  for (var line in const LineSplitter().convert(text)) {
    line = line.trimRight();
    // 한 줄이 너무 길면 (줄바꿈 없는 파일) 적당히 자른다
    while (line.length > 1200) {
      final cut = line.lastIndexOf(RegExp(r'[.!?。 ]'), 1200);
      final at = cut > 600 ? cut + 1 : 1200;
      blocks.add(TextBlock.text(line.substring(0, at)));
      line = line.substring(at);
    }
    if (isChapterTitle(line)) {
      toc.add(TocEntry(line.trim(), blocks.length));
      blocks.add(TextBlock.text(line.trim(), heading: 3));
    } else {
      blocks.add(TextBlock.text(line));
    }
  }
  return TextDocument(blocks, toc, enc);
}

// ======================= EPUB =======================

TextDocument _loadEpub(String path) {
  final input = InputFileStream(path);
  try {
    final zip = ZipDecoder().decodeStream(input);
    String read(String name) => utf8.decode(zip.findFile(name)?.content ?? Uint8List(0), allowMalformed: true);

    final container = XmlDocument.parse(read('META-INF/container.xml'));
    final opfPath = container.findAllElements('rootfile', namespaceUri: '*').first.getAttribute('full-path')!;
    final opfDir = p.posix.dirname(opfPath);
    final opf = XmlDocument.parse(read(opfPath));
    String resolve(String base, String href) =>
        p.posix.normalize(p.posix.join(base == '.' ? '' : base, Uri.decodeFull(href.split('#').first)));

    final manifest = <String, String>{}; // id → 경로
    String? navPath, ncxPath;
    for (final it in opf.findAllElements('item', namespaceUri: '*')) {
      final href = it.getAttribute('href');
      final id = it.getAttribute('id');
      if (href == null || id == null) continue;
      manifest[id] = resolve(opfDir, href);
      if ((it.getAttribute('properties') ?? '').contains('nav')) navPath = manifest[id];
      if (it.getAttribute('media-type') == 'application/x-dtbncx+xml') ncxPath = manifest[id];
    }
    final spine = opf
        .findAllElements('itemref', namespaceUri: '*')
        .map((e) => manifest[e.getAttribute('idref')])
        .whereType<String>()
        .toList();

    final tocTitles = _readTocTitles(zip, read, navPath, ncxPath, resolve);

    final blocks = <TextBlock>[];
    final toc = <TocEntry>[];
    for (final chapter in spine) {
      final start = blocks.length;
      final html = read(chapter);
      if (html.isEmpty) continue;
      XmlDocument doc;
      try {
        doc = XmlDocument.parse(html, entityMapping: const XmlDefaultEntityMapping.html5());
      } catch (_) {
        // 문법이 깨진 XHTML → 태그만 지운 텍스트로
        final plain = html.replaceAll(RegExp(r'<[^>]+>'), '\n');
        for (final l in plain.split('\n').map((e) => e.trim()).where((e) => e.isNotEmpty)) {
          blocks.add(TextBlock.text(l));
        }
        continue;
      }
      final body = doc.findAllElements('body', namespaceUri: '*').firstOrNull ?? doc.rootElement;
      _HtmlWalker(blocks, (src) => zip.findFile(resolve(p.posix.dirname(chapter), src))?.content).walk(body);
      if (blocks.length == start) continue;

      final title = tocTitles[chapter] ??
          blocks.skip(start).where((b) => b.heading > 0).map((b) => b.text).firstOrNull ??
          blocks.skip(start).where((b) => !b.isImage && (b.text ?? '').trim().isNotEmpty).map((b) => b.text!).firstOrNull;
      if (title != null) {
        toc.add(TocEntry(title.length > 40 ? '${title.substring(0, 40)}…' : title, start));
      }
    }
    return TextDocument(blocks, toc, 'EPUB');
  } finally {
    input.closeSync();
  }
}

/// nav.xhtml(EPUB3) 또는 toc.ncx(EPUB2) 에서 "파일 → 목차 제목"
Map<String, String> _readTocTitles(
  Archive zip,
  String Function(String) read,
  String? navPath,
  String? ncxPath,
  String Function(String, String) resolve,
) {
  final map = <String, String>{};
  try {
    if (navPath != null) {
      final nav = XmlDocument.parse(read(navPath), entityMapping: const XmlDefaultEntityMapping.html5());
      for (final a in nav.findAllElements('a', namespaceUri: '*')) {
        final href = a.getAttribute('href');
        final t = a.innerText.trim();
        if (href != null && t.isNotEmpty) map.putIfAbsent(resolve(p.posix.dirname(navPath), href), () => t);
      }
    } else if (ncxPath != null) {
      final ncx = XmlDocument.parse(read(ncxPath));
      for (final np in ncx.findAllElements('navPoint', namespaceUri: '*')) {
        final t = np.findElements('navLabel', namespaceUri: '*').firstOrNull?.innerText.trim();
        final src = np.findElements('content', namespaceUri: '*').firstOrNull?.getAttribute('src');
        if (t != null && t.isNotEmpty && src != null) map.putIfAbsent(resolve(p.posix.dirname(ncxPath), src), () => t);
      }
    }
  } catch (_) {}
  return map;
}

/// XHTML 을 문단/제목/그림 블록으로 펼친다
class _HtmlWalker {
  final List<TextBlock> out;
  final Uint8List? Function(String src) loadImage;
  _HtmlWalker(this.out, this.loadImage);

  static const _blockTags = {
    'p', 'div', 'section', 'article', 'li', 'tr', 'dt', 'dd', 'figure', 'figcaption', 'pre', 'table', 'ul', 'ol', 'header', 'footer'
  };
  final _buf = StringBuffer();
  int _heading = 0;
  bool _quote = false;

  void walk(XmlElement root) {
    _visit(root);
    _flush();
  }

  void _flush() {
    final t = _buf.toString().replaceAll(RegExp(r'[ \t\r\n]+'), ' ').trim();
    if (t.isNotEmpty) out.add(TextBlock.text(t, heading: _heading, quote: _quote));
    _buf.clear();
  }

  void _visit(XmlNode node) {
    if (node is XmlText || node is XmlCDATA) {
      _buf.write(node.value);
      return;
    }
    if (node is! XmlElement) return;
    final tag = node.localName.toLowerCase();
    switch (tag) {
      case 'script' || 'style' || 'head':
        return;
      case 'br':
        _flush();
        return;
      case 'img' || 'image':
        _flush();
        final src = node.getAttribute('src') ?? node.getAttribute('href', namespaceUri: '*') ?? node.getAttribute('xlink:href');
        final bytes = src == null ? null : loadImage(src);
        if (bytes != null) out.add(TextBlock.image(bytes));
        return;
      case 'h1' || 'h2' || 'h3' || 'h4' || 'h5' || 'h6':
        _flush();
        _heading = int.parse(tag.substring(1));
        node.children.forEach(_visit);
        _flush();
        _heading = 0;
        return;
      case 'blockquote':
        _flush();
        _quote = true;
        node.children.forEach(_visit);
        _flush();
        _quote = false;
        return;
    }
    final isBlock = _blockTags.contains(tag);
    if (isBlock) _flush();
    node.children.forEach(_visit);
    if (isBlock) _flush();
  }
}
