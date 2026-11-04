import 'dart:io';
import 'dart:isolate';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:image/image.dart' as img;
import 'package:path/path.dart' as p;
import 'package:pdfrx/pdfrx.dart';

import 'ocr_service.dart';
import 'text_document.dart' show chapterRe;

/// PDF 를 글로: 글자가 든 쪽은 그대로, 스캔한 쪽(그림뿐)은 글자 인식
class PdfText {
  PdfText._();

  /// 이만큼 글자가 있으면 글자가 든 쪽으로 본다 (공백 빼고)
  static const _minChars = 15;
  static final _ws = RegExp(r'\s');

  /// 쪽을 그림으로 그려 PNG 로 (긴 변 2600px, 글자 인식용)
  static Future<Uint8List?> renderPng(PdfPage page) async {
    final scale = 2600 / math.max(page.width, page.height);
    final im = await page.render(fullWidth: page.width * scale, fullHeight: page.height * scale, backgroundColor: 0xffffffff);
    if (im == null) return null;
    try {
      final w = im.width, h = im.height;
      final px = Uint8List.fromList(im.pixels);
      return await Isolate.run(() => img.encodePng(
          img.Image.fromBytes(width: w, height: h, bytes: px.buffer, numChannels: 4, order: img.ChannelOrder.bgra),
          level: 1));
    } finally {
      im.dispose();
    }
  }

  /// 한 쪽의 글 (소리 내어 읽기용, 끊긴 줄을 이음)
  static Future<String> pageText(PdfPage page) async {
    final raw = (await page.loadText())?.fullText ?? '';
    if (raw.replaceAll(_ws, '').length >= _minChars || !OcrService.supported) return OcrService.tidy(raw);
    final png = await renderPng(page);
    if (png == null) return OcrService.tidy(raw);
    return OcrService.tidy(await OcrService.recognizeBytes(png));
  }

  /// PDF 전체 → 글 (TXT 로 저장할 꼴). 글자 인식은 몇 쪽씩 묶어서 (Windows 는 PowerShell 을 덜 띄움)
  static Future<PdfTextResult> convert(String path, {void Function(int done, int total)? onPage, bool Function()? cancelled}) async {
    final doc = await PdfDocument.openFile(path);
    final tmp = await Directory.systemTemp.createTemp('arari_pdftxt');
    try {
      final n = doc.pages.length;
      final pages = List<String>.filled(n, '');
      var done = 0, ocr = 0;
      final batch = <int, String>{}; // 쪽 → 그림 파일
      Future<void> flush() async {
        if (batch.isEmpty) return;
        final res = await OcrService.recognizeFiles(batch.values.toList());
        for (final e in batch.entries) {
          pages[e.key] = res[e.value] ?? '';
        }
        done += batch.length;
        ocr += batch.length;
        batch.clear();
        onPage?.call(done, n);
      }

      var stopped = false;
      for (var i = 0; i < n; i++) {
        if (cancelled?.call() ?? false) {
          stopped = true;
          break;
        }
        final page = doc.pages[i];
        final raw = (await page.loadText())?.fullText ?? '';
        if (raw.replaceAll(_ws, '').length >= _minChars || !OcrService.supported) {
          pages[i] = raw;
          onPage?.call(++done, n);
          continue;
        }
        final png = await renderPng(page);
        if (png == null) {
          onPage?.call(++done, n);
          continue;
        }
        final f = p.join(tmp.path, '$i.png');
        await File(f).writeAsBytes(png);
        batch[i] = f;
        if (batch.length >= 6) await flush();
      }
      if (!stopped) await flush();
      final text = joinPages(pages);
      return PdfTextResult(text, n, ocr, pages.where((t) => t.replaceAll(_ws, '').isEmpty).length, stopped);
    } finally {
      doc.dispose();
      try {
        await tmp.delete(recursive: true);
      } catch (_) {}
    }
  }

  static final _end = RegExp(r'[.!?。…」』"”’)\]]$');
  static final _pageNo = RegExp(r'^[-–—·\s(\[]*(\d{1,4}|[ivxlcdm]{1,7})(\s*/\s*\d{1,4})?[-–—·\s)\]]*$', caseSensitive: false);
  static String _norm(String l) => l.replaceAll(RegExp(r'\d+'), '#').replaceAll(_ws, '');

  /// 쪽마다 읽은 글을 하나로: 쪽 번호 · 되풀이되는 머리글/꼬리글을 빼고, 줄바꿈으로 끊긴 문장과 쪽 경계를 잇는다.
  /// "제1장" 같은 장 제목 줄은 따로 둔다 (TXT → EPUB 목차가 되게)
  static String joinPages(List<String> raw) {
    final pages = [
      for (final r in raw) r.split(RegExp(r'\r?\n')).map((l) => l.trim()).where((l) => l.isNotEmpty).toList(),
    ];
    // 여러 쪽 위·아래 끝에 되풀이되는 짧은 줄 (책 제목 · 장 제목 머리글 등, 숫자는 같게 봄)
    final count = <String, int>{};
    for (final pg in pages) {
      final edge = {...pg.take(2), ...pg.reversed.take(2)}.where((l) => l.length <= 40).map(_norm).toSet();
      for (final k in edge) {
        count[k] = (count[k] ?? 0) + 1;
      }
    }
    final filled = pages.where((x) => x.isNotEmpty).length;
    final running = {
      for (final e in count.entries)
        if (filled >= 4 && e.value >= 3 && e.value >= filled * 0.3) e.key,
    };

    final out = <String>[];
    var cur = '';
    void flush() {
      if (cur.isNotEmpty) out.add(cur);
      cur = '';
    }

    for (final pg in pages) {
      for (var k = 0; k < pg.length; k++) {
        final l = pg[k];
        final edge = k < 2 || k >= pg.length - 2;
        if (edge && (_pageNo.hasMatch(l) || running.contains(_norm(l)))) continue;
        if (l.length <= 40 && chapterRe.hasMatch(l)) {
          flush();
          out.add(l);
          continue;
        }
        if (cur.isEmpty) {
          cur = l;
        } else if (_end.hasMatch(cur)) {
          flush();
          cur = l;
        } else {
          cur = '$cur $l';
        }
      }
    }
    flush();
    return out.join('\n');
  }
}

class PdfTextResult {
  final String text;
  final int pages, ocrPages, emptyPages;
  final bool cancelled;
  const PdfTextResult(this.text, this.pages, this.ocrPages, this.emptyPages, this.cancelled);
}
