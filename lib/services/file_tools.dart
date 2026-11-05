import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:archive/archive_io.dart';
import 'package:image/image.dart' as img;
import 'package:path/path.dart' as p;
import 'package:pdfrx/pdfrx.dart';

import '../models/media_item.dart';
import 'archive_tools.dart';

/// 그림 줄이기 설정
class ShrinkOptions {
  final int maxSide; // 긴 변 최대 (px). 0 = 크기는 그대로
  final int quality; // JPEG 품질
  final bool toJpeg; // PNG · BMP · GIF 도 JPEG 로 (투명은 흰 바탕)
  const ShrinkOptions({this.maxSide = 1600, this.quality = 82, this.toJpeg = false});
}

/// 결과: 전 크기, 후 크기, 바꾼 그림 수
typedef ShrinkResult = ({int before, int after, int changed, int images});

/// 파일 도구 (그림 줄이기 · EPUB 최적화 · PDF 나누기/합치기)
class FileTools {
  FileTools._();

  static String _bak(String path) {
    var bak = '$path.bak';
    for (var n = 2; File(bak).existsSync(); n++) {
      bak = '$path.$n.bak';
    }
    return bak;
  }

  /// 다 만든 임시 파일로 원본을 바꾼다 (백업이면 원본은 .bak)
  static Future<void> _swap(String path, String tmp, bool backup) async {
    if (backup) {
      await File(path).rename(_bak(path));
    } else {
      await File(path).delete();
    }
    await File(tmp).rename(path);
  }

  /// 따로 도는 일꾼에서 [work] 를 돌리며 진행 상황을 받는다
  static Future<R> _withProgress<R>(R Function(void Function(int, int) report) work, void Function(int, int)? onProgress) async {
    final port = ReceivePort();
    final sub = port.listen((m) {
      if (m is (int, int)) onProgress?.call(m.$1, m.$2);
    });
    try {
      return await _run(work, port.sendPort);
    } finally {
      await sub.cancel();
      port.close();
    }
  }

  // 일꾼에 보내는 함수는 따로 만든다: 같은 자리의 onProgress(화면 객체를 붙잡음)가 함께 보내지지 않게
  static Future<R> _run<R>(R Function(void Function(int, int) report) work, SendPort send) =>
      Isolate.run(() => work((a, b) => send.send((a, b))));

  // ---------------- 그림 줄이기 ----------------

  /// 그림 하나 줄이기. 더 작아지지 않으면 null (원본 유지)
  /// 돌려줌: (새 데이터, 새 확장자)
  static (Uint8List, String)? shrinkBytes(Uint8List src, String ext, ShrinkOptions o) {
    final e = ext.toLowerCase();
    final isJpg = e == '.jpg' || e == '.jpeg';
    final isPng = e == '.png';
    // 다시 만들 수 있는 형식만 (WebP · AVIF 는 이 앱이 저장할 수 없어 그대로)
    if (!isJpg && !isPng && !(o.toJpeg && (e == '.bmp' || e == '.gif'))) return null;
    final im = img.decodeImage(src);
    if (im == null) return null;
    var out = im;
    final long = im.width > im.height ? im.width : im.height;
    final resize = o.maxSide > 0 && long > o.maxSide;
    if (resize) {
      out = im.width >= im.height
          ? img.copyResize(im, width: o.maxSide, interpolation: img.Interpolation.average)
          : img.copyResize(im, height: o.maxSide, interpolation: img.Interpolation.average);
    }
    final asJpg = isJpg || o.toJpeg;
    if (asJpg && out.hasAlpha) {
      final bg = img.Image(width: out.width, height: out.height);
      img.fill(bg, color: img.ColorRgb8(255, 255, 255));
      img.compositeImage(bg, out);
      out = bg;
    }
    final data = asJpg ? img.encodeJpg(out, quality: o.quality) : img.encodePng(out, level: 9);
    // 용량을 아끼는 도구이므로 더 작아질 때만 바꾼다
    if (data.length >= src.length) return null;
    return (data, asJpg && !isJpg ? '.jpg' : e);
  }

  /// 만화 압축 파일(CBZ · ZIP) 안 그림을 줄여 다시 쓴다
  static Future<ShrinkResult> shrinkZip(String path, ShrinkOptions o, {bool backup = true, void Function(int, int)? onProgress}) async {
    final tmp = '$path.tmp';
    final before = await File(path).length();
    final r = await _withProgress((report) {
      final input = InputFileStream(path);
      final enc = ZipFileEncoder()..create(tmp, level: 6);
      var changed = 0, images = 0;
      try {
        final zip = ZipDecoder().decodeStream(input);
        final files = zip.files.where((f) => f.isFile).toList();
        final used = {for (final f in files) f.name.toLowerCase()};
        for (var i = 0; i < files.length; i++) {
          final f = files[i];
          final ext = p.extension(f.name).toLowerCase();
          if (imageExts.contains(ext) && !ArchiveTools.isJunk(f.name)) {
            images++;
            final out = OutputMemoryStream();
            f.writeContent(out); // 풀어 둔 데이터를 바로 버림
            final src = out.getBytes();
            final s = shrinkBytes(src, ext, o);
            if (s != null) {
              var name = f.name;
              if (s.$2 != ext) {
                // 확장자가 바뀌면 이름이 겹치지 않게
                final stem = p.posix.withoutExtension(f.name);
                name = '$stem${s.$2}';
                for (var n = 2; used.contains(name.toLowerCase()); n++) {
                  name = '${stem}_$n${s.$2}';
                }
                used.add(name.toLowerCase());
              }
              enc.addArchiveFile(ArchiveFile.noCompress(name, s.$1.length, s.$1));
              changed++;
            } else {
              enc.addArchiveFile(ArchiveFile.noCompress(f.name, src.length, src));
            }
          } else {
            enc.addArchiveFile(f); // 그대로 (압축된 채로 옮김)
          }
          report(i + 1, files.length);
        }
      } finally {
        enc.closeSync();
        input.closeSync();
      }
      return (changed, images);
    }, onProgress);
    final after = await File(tmp).length();
    if (r.$1 == 0 || after >= before) {
      await File(tmp).delete();
      return (before: before, after: before, changed: 0, images: r.$2);
    }
    await _swap(path, tmp, backup);
    return (before: before, after: after, changed: r.$1, images: r.$2);
  }

  /// 그림 파일 하나 줄이기 (JPEG · PNG 만, 형식은 그대로 — 파일 이름이 바뀌지 않게)
  static Future<ShrinkResult> shrinkImageFile(String path, ShrinkOptions o, {bool backup = true}) async {
    final before = await File(path).length();
    final ext = p.extension(path);
    final keep = ShrinkOptions(maxSide: o.maxSide, quality: o.quality, toJpeg: false);
    final s = await Isolate.run(() => shrinkBytes(File(path).readAsBytesSync(), ext, keep));
    if (s == null) return (before: before, after: before, changed: 0, images: 1);
    final tmp = '$path.tmp';
    await File(tmp).writeAsBytes(s.$1);
    await _swap(path, tmp, backup);
    return (before: before, after: s.$1.length, changed: 1, images: 1);
  }

  /// EPUB 용량 줄이기: 안의 큰 그림을 줄이고 다시 압축한다 (그림 이름은 그대로라 본문 링크가 깨지지 않음)
  static Future<ShrinkResult> optimizeEpub(String path, ShrinkOptions o, {bool backup = true, void Function(int, int)? onProgress}) async {
    final tmp = '$path.tmp';
    final before = await File(path).length();
    // EPUB 은 확장자를 바꾸면 본문의 그림 주소가 깨지므로 JPEG 바꾸기는 하지 않는다
    final keep = ShrinkOptions(maxSide: o.maxSide, quality: o.quality, toJpeg: false);
    final r = await _withProgress((report) {
      final input = InputFileStream(path);
      final enc = ZipFileEncoder()..create(tmp, level: 9);
      var changed = 0, images = 0;
      try {
        final zip = ZipDecoder().decodeStream(input);
        final files = zip.files.where((f) => f.isFile).toList();
        // mimetype 은 맨 앞, 압축하지 않음 (EPUB 규칙)
        final mt = files.where((f) => f.name == 'mimetype').firstOrNull;
        enc.addArchiveFile(ArchiveFile.noCompress('mimetype', 20, 'application/epub+zip'.codeUnits));
        for (var i = 0; i < files.length; i++) {
          final f = files[i];
          if (identical(f, mt) || ArchiveTools.isJunk(f.name)) continue;
          final ext = p.extension(f.name).toLowerCase();
          if (ext == '.jpg' || ext == '.jpeg' || ext == '.png') {
            images++;
            final out = OutputMemoryStream();
            f.writeContent(out);
            final src = out.getBytes();
            final s = shrinkBytes(src, ext, keep);
            if (s != null) {
              enc.addArchiveFile(ArchiveFile.noCompress(f.name, s.$1.length, s.$1));
              changed++;
            } else {
              enc.addArchiveFile(ArchiveFile.noCompress(f.name, src.length, src));
            }
          } else {
            // 글 · 스타일 · 글꼴은 가장 세게 다시 압축
            final out = OutputMemoryStream();
            f.writeContent(out);
            final data = out.getBytes();
            enc.addArchiveFile(ArchiveFile.bytes(f.name, data)..compressionLevel = 9);
          }
          report(i + 1, files.length);
        }
      } finally {
        enc.closeSync();
        input.closeSync();
      }
      return (changed, images);
    }, onProgress);
    final after = await File(tmp).length();
    if (after >= before) {
      await File(tmp).delete();
      return (before: before, after: before, changed: 0, images: r.$2);
    }
    await _swap(path, tmp, backup);
    return (before: before, after: after, changed: r.$1, images: r.$2);
  }

  // ---------------- PDF 나누기 · 합치기 ----------------

  /// "1-10, 15, 20-" 같은 쪽 범위 → 쪽 번호(1부터) 묶음들. 잘못되면 null
  static List<List<int>>? parseRanges(String spec, int pages) {
    final out = <List<int>>[];
    // "1 - 10" 처럼 대시 양옆에 띄어쓰기를 해도 한 묶음으로
    final tidy = spec.replaceAllMapped(RegExp(r'\s*([-~])\s*'), (m) => m[1]!);
    for (final raw in tidy.split(RegExp(r'[,;\s]+'))) {
      final t = raw.trim();
      if (t.isEmpty) continue;
      final m = RegExp(r'^(\d*)\s*[-~]\s*(\d*)$').firstMatch(t);
      int a, z;
      if (m != null) {
        a = m.group(1)!.isEmpty ? 1 : int.parse(m.group(1)!);
        z = m.group(2)!.isEmpty ? pages : int.parse(m.group(2)!);
      } else {
        final n = int.tryParse(t);
        if (n == null) return null;
        a = z = n;
      }
      if (a < 1 || z > pages || a > z) return null;
      out.add([for (var i = a; i <= z; i++) i]);
    }
    return out.isEmpty ? null : out;
  }

  /// [every] 쪽마다 나누기
  static List<List<int>> everyN(int every, int pages) => [
        for (var a = 1; a <= pages; a += every) [for (var i = a; i < a + every && i <= pages; i++) i],
      ];

  /// PDF 를 쪽 묶음마다 새 PDF 로. 만든 파일 경로들
  static Future<List<String>> splitPdf(String path, List<List<int>> groups, {void Function(int, int)? onProgress}) async {
    final src = await PdfDocument.openFile(path);
    final made = <String>[];
    try {
      final stem = p.withoutExtension(path);
      for (var g = 0; g < groups.length; g++) {
        final pages = groups[g];
        final doc = await PdfDocument.createNew(sourceName: 'split-$g');
        try {
          doc.pages = [for (final n in pages) src.pages[n - 1]];
          final bytes = await doc.encodePdf();
          var out = '$stem (${pages.first == pages.last ? '${pages.first}' : '${pages.first}-${pages.last}'}).pdf';
          for (var k = 2; await File(out).exists(); k++) {
            out = '$stem (${pages.first}-${pages.last}) $k.pdf';
          }
          await File(out).writeAsBytes(bytes);
          made.add(out);
        } finally {
          doc.dispose();
        }
        onProgress?.call(g + 1, groups.length);
      }
    } finally {
      src.dispose();
    }
    return made;
  }

  /// 여러 PDF 를 차례대로 하나로
  static Future<int> mergePdf(List<String> paths, String outPath) async {
    final docs = <PdfDocument>[];
    try {
      for (final x in paths) {
        docs.add(await PdfDocument.openFile(x));
      }
      final doc = await PdfDocument.createNew(sourceName: 'merged');
      try {
        doc.pages = [for (final d in docs) ...d.pages];
        final bytes = await doc.encodePdf();
        await File(outPath).writeAsBytes(bytes);
        return doc.pages.length;
      } finally {
        doc.dispose();
      }
    } finally {
      for (final d in docs) {
        d.dispose();
      }
    }
  }
}
