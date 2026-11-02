import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:archive/archive_io.dart';
import 'package:path/path.dart' as p;

import 'text_document.dart' show decodeText, chapterRe;

/// TXT → EPUB 3 (EPUB 2 리더용 toc.ncx 도 함께)
/// - "제1장", "1화", "프롤로그" 같은 줄로 장을 나누고, 없으면 일정 길이로 나눈다
/// - 표지 그림이 있으면 넣는다
class EpubWriter {
  static String _esc(String s) => const HtmlEscape(HtmlEscapeMode.element).convert(s);

  /// 만든 EPUB 경로를 돌려준다 (같은 폴더, 같은 이름)
  static Future<String> fromTxt(String txtPath, {required String title, String? author, Uint8List? cover, bool autoChapters = true}) {
    return Isolate.run(() {
      final (text, _) = decodeText(File(txtPath).readAsBytesSync());
      final lines = const LineSplitter().convert(text);

      // ---- 장 나누기 ----
      final chapters = <(String, List<String>)>[];
      var curTitle = '시작';
      var cur = <String>[];
      for (final raw in lines) {
        final l = raw.trimRight();
        if (autoChapters && l.trim().isNotEmpty && l.trim().length <= 40 && chapterRe.hasMatch(l)) {
          if (cur.any((e) => e.trim().isNotEmpty)) chapters.add((curTitle, cur));
          curTitle = l.trim();
          cur = [];
        } else {
          cur.add(l);
        }
      }
      if (cur.any((e) => e.trim().isNotEmpty)) chapters.add((curTitle, cur));
      // 장이 하나뿐이고 너무 길면 3000줄씩 나눠 리더가 버벅이지 않게
      if (chapters.length == 1 && chapters.first.$2.length > 3000) {
        final all = chapters.first.$2;
        chapters.clear();
        for (var i = 0; i < all.length; i += 3000) {
          chapters.add(('${i ~/ 3000 + 1}부', all.sublist(i, (i + 3000).clamp(0, all.length))));
        }
      }

      // ---- 파일 만들기 ----
      final id = 'urn:uuid:${DateTime.now().microsecondsSinceEpoch.toRadixString(16)}-${txtPath.hashCode.toRadixString(16)}';
      final modified = '${DateTime.now().toUtc().toIso8601String().split('.').first}Z';
      final files = <String, List<int>>{};
      String page(String t, String body) => '<?xml version="1.0" encoding="UTF-8"?>\n'
          '<!DOCTYPE html>\n<html xmlns="http://www.w3.org/1999/xhtml" xmlns:epub="http://www.idpf.org/2007/ops" lang="ko" xml:lang="ko">'
          '<head><meta charset="UTF-8"/><title>${_esc(t)}</title><link rel="stylesheet" type="text/css" href="../style.css"/></head><body>$body</body></html>';

      for (var i = 0; i < chapters.length; i++) {
        final (t, ls) = chapters[i];
        final body = StringBuffer('<h2>${_esc(t)}</h2>\n');
        for (final l in ls) {
          body.write(l.trim().isEmpty ? '<p class="blank">&#160;</p>\n' : '<p>${_esc(l.trim())}</p>\n');
        }
        files['OEBPS/text/ch${(i + 1).toString().padLeft(3, '0')}.xhtml'] = utf8.encode(page(t, body.toString()));
      }
      files['OEBPS/style.css'] = utf8.encode('body{margin:0 5%;line-height:1.8;font-family:serif;word-break:keep-all}'
          'h2{margin:2em 0 1.5em;text-align:center;font-size:1.3em}p{margin:0;text-indent:1em}p.blank{text-indent:0;height:.8em}'
          '.cover{margin:0;padding:0;text-align:center}.cover img{max-width:100%;max-height:100vh}');

      final hasCover = cover != null && cover.length > 8;
      final png = hasCover && cover[0] == 0x89 && cover[1] == 0x50; // PNG 인지 JPG 인지
      final coverFile = png ? 'cover.png' : 'cover.jpg';
      if (hasCover) {
        files['OEBPS/images/$coverFile'] = cover;
        files['OEBPS/text/cover.xhtml'] = utf8.encode(page('표지', '<div class="cover"><img src="../images/$coverFile" alt="표지"/></div>'));
      }

      final navItems = StringBuffer();
      final ncxPoints = StringBuffer();
      for (var i = 0; i < chapters.length; i++) {
        final f = 'text/ch${(i + 1).toString().padLeft(3, '0')}.xhtml';
        navItems.write('<li><a href="$f">${_esc(chapters[i].$1)}</a></li>');
        ncxPoints.write('<navPoint id="n${i + 1}" playOrder="${i + 1}"><navLabel><text>${_esc(chapters[i].$1)}</text></navLabel><content src="$f"/></navPoint>');
      }
      files['OEBPS/nav.xhtml'] = utf8.encode('<?xml version="1.0" encoding="UTF-8"?>\n<!DOCTYPE html>\n'
          '<html xmlns="http://www.w3.org/1999/xhtml" xmlns:epub="http://www.idpf.org/2007/ops" lang="ko"><head><meta charset="UTF-8"/><title>목차</title></head>'
          '<body><nav epub:type="toc" id="toc"><h1>목차</h1><ol>$navItems</ol></nav></body></html>');
      files['OEBPS/toc.ncx'] = utf8.encode('<?xml version="1.0" encoding="UTF-8"?>\n'
          '<ncx xmlns="http://www.daisy.org/z3986/2005/ncx/" version="2005-1"><head><meta name="dtb:uid" content="$id"/></head>'
          '<docTitle><text>${_esc(title)}</text></docTitle><navMap>$ncxPoints</navMap></ncx>');

      final manifest = StringBuffer()
        ..write('<item id="nav" href="nav.xhtml" media-type="application/xhtml+xml" properties="nav"/>')
        ..write('<item id="ncx" href="toc.ncx" media-type="application/x-dtbncx+xml"/>')
        ..write('<item id="css" href="style.css" media-type="text/css"/>');
      final spine = StringBuffer();
      if (hasCover) {
        manifest
          ..write('<item id="cover-image" href="images/$coverFile" media-type="${png ? 'image/png' : 'image/jpeg'}" properties="cover-image"/>')
          ..write('<item id="cover" href="text/cover.xhtml" media-type="application/xhtml+xml"/>');
        spine.write('<itemref idref="cover"/>');
      }
      for (var i = 0; i < chapters.length; i++) {
        final n = (i + 1).toString().padLeft(3, '0');
        manifest.write('<item id="ch$n" href="text/ch$n.xhtml" media-type="application/xhtml+xml"/>');
        spine.write('<itemref idref="ch$n"/>');
      }
      files['OEBPS/content.opf'] = utf8.encode('<?xml version="1.0" encoding="UTF-8"?>\n'
          '<package xmlns="http://www.idpf.org/2007/opf" version="3.0" unique-identifier="bookid" xml:lang="ko">'
          '<metadata xmlns:dc="http://purl.org/dc/elements/1.1/"><dc:identifier id="bookid">$id</dc:identifier>'
          '<dc:title>${_esc(title)}</dc:title>${author != null && author.isNotEmpty ? '<dc:creator>${_esc(author)}</dc:creator>' : ''}'
          '<dc:language>ko</dc:language><meta property="dcterms:modified">$modified</meta>'
          '${hasCover ? '<meta name="cover" content="cover-image"/>' : ''}</metadata>'
          '<manifest>$manifest</manifest><spine toc="ncx">$spine</spine></package>');
      files['META-INF/container.xml'] = utf8.encode('<?xml version="1.0" encoding="UTF-8"?>\n'
          '<container version="1.0" xmlns="urn:oasis:names:tc:opendocument:xmlns:container">'
          '<rootfiles><rootfile full-path="OEBPS/content.opf" media-type="application/oebps-package+xml"/></rootfiles></container>');

      // ---- 저장: mimetype 은 맨 처음, 압축하지 않고 ----
      var out = p.setExtension(txtPath, '.epub');
      var n = 2;
      while (File(out).existsSync()) {
        out = '${p.withoutExtension(txtPath)} ($n).epub';
        n++;
      }
      final enc = ZipFileEncoder()..create(out);
      final mt = utf8.encode('application/epub+zip');
      enc.addArchiveFile(ArchiveFile.noCompress('mimetype', mt.length, mt));
      files.forEach((name, data) => enc.addArchiveFile(ArchiveFile.bytes(name, data)));
      enc.closeSync();
      return out;
    });
  }
}
