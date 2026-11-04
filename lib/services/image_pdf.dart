import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:image/image.dart' as img;

/// 그림을 쪽마다 한 장씩 넣은 PDF 만들기 (외부 라이브러리 없이)
///
/// JPEG 는 다시 압축하지 않고 그대로 넣는다 (화질 그대로 · 빠름). PNG · WebP · GIF · BMP 는 JPEG 로 바꿔 넣는다.
/// 쪽 너비는 A4 너비(595pt), 높이는 그림 비율대로. 파일에 바로 써 나가므로 큰 만화도 메모리를 적게 쓴다.
class ImagePdf {
  ImagePdf._();

  /// 만든 쪽 수를 돌려준다. [imageAt] 이 null 을 주거나 못 읽는 그림은 건너뛴다
  static Future<int> write(
    String outPath,
    int count,
    Future<Uint8List?> Function(int i) imageAt, {
    String title = '',
    int jpegQuality = 90,
    void Function(int done, int total)? onPage,
    bool Function()? cancelled,
  }) async {
    final w = _Writer(File(outPath).openWrite());
    final kids = <int>[];
    try {
      w.raw('%PDF-1.4\n%\xE2\xE3\xCF\xD3\n');
      w.obj(1, '<< /Type /Catalog /Pages 2 0 R >>');
      w.obj(3, '<< /Producer (ARARIFlex)${title.isEmpty ? '' : ' /Title ${_utf16(title)}'} >>');
      var next = 4;
      for (var i = 0; i < count; i++) {
        if (cancelled?.call() ?? false) break;
        final src = await imageAt(i);
        final jpg = src == null ? null : await toJpeg(src, quality: jpegQuality);
        onPage?.call(i + 1, count);
        if (jpg == null) continue;
        final (iw, ih, comps, data) = jpg;
        final pageNo = next, contentNo = next + 1, imageNo = next + 2;
        next += 3;
        const pw = 595.0;
        final ph = (pw * ih / iw);
        final pws = pw.toStringAsFixed(2), phs = ph.toStringAsFixed(2);
        w.obj(pageNo,
            '<< /Type /Page /Parent 2 0 R /MediaBox [0 0 $pws $phs] /Resources << /XObject << /Im0 $imageNo 0 R >> >> /Contents $contentNo 0 R >>');
        final draw = latin1.encode('q $pws 0 0 $phs 0 0 cm /Im0 Do Q');
        w.stream(contentNo, '<< /Length ${draw.length} >>', draw);
        w.stream(
            imageNo,
            '<< /Type /XObject /Subtype /Image /Width $iw /Height $ih /ColorSpace ${comps == 1 ? '/DeviceGray' : '/DeviceRGB'} '
            '/BitsPerComponent 8 /Filter /DCTDecode /Length ${data.length} >>',
            data);
        kids.add(pageNo);
        await w.drain(); // 쪽마다 내보내 메모리를 비운다
      }
      w.obj(2, '<< /Type /Pages /Kids [${kids.map((k) => '$k 0 R').join(' ')}] /Count ${kids.length} >>');
      w.finish();
    } finally {
      await w.close();
    }
    return kids.length;
  }

  /// 그림 → (너비, 높이, 성분 수, JPEG). 회색조 · RGB JPEG 는 그대로, 나머지는 JPEG 로 바꿈 (투명은 흰 바탕)
  static Future<(int, int, int, Uint8List)?> toJpeg(Uint8List src, {int quality = 90}) async {
    final info = jpegInfo(src);
    if (info != null && (info.$3 == 1 || info.$3 == 3)) return (info.$1, info.$2, info.$3, src);
    return Isolate.run(() {
      final im = img.decodeImage(src);
      if (im == null) return null;
      var rgb = im;
      if (im.hasAlpha) {
        rgb = img.Image(width: im.width, height: im.height);
        img.fill(rgb, color: img.ColorRgb8(255, 255, 255));
        img.compositeImage(rgb, im);
      }
      return (rgb.width, rgb.height, 3, img.encodeJpg(rgb, quality: quality));
    });
  }

  /// JPEG 머리에서 (너비, 높이, 성분 수). JPEG 가 아니면 null
  static (int, int, int)? jpegInfo(Uint8List b) {
    if (b.length < 4 || b[0] != 0xFF || b[1] != 0xD8) return null;
    var i = 2;
    while (i + 9 < b.length) {
      if (b[i] != 0xFF) {
        i++;
        continue;
      }
      final m = b[i + 1];
      if (m == 0xFF) {
        i++;
        continue;
      }
      if (m == 0xD8 || m == 0x01 || (m >= 0xD0 && m <= 0xD7)) {
        i += 2;
        continue;
      }
      final len = b[i + 2] << 8 | b[i + 3];
      if (m >= 0xC0 && m <= 0xCF && m != 0xC4 && m != 0xC8 && m != 0xCC) {
        final h = b[i + 5] << 8 | b[i + 6], w = b[i + 7] << 8 | b[i + 8], c = b[i + 9];
        if (w == 0 || h == 0) return null;
        return (w, h, c);
      }
      i += 2 + len;
    }
    return null;
  }

  /// PDF 글자열: UTF-16BE 16진 (<FEFF…>) — 한글 제목도 깨지지 않게
  static String _utf16(String s) {
    final sb = StringBuffer('<FEFF');
    for (final u in s.codeUnits) {
      sb.write(u.toRadixString(16).padLeft(4, '0').toUpperCase());
    }
    sb.write('>');
    return sb.toString();
  }
}

class _Writer {
  _Writer(this._out);
  final IOSink _out;
  int _pos = 0;
  final _offsets = <int, int>{};

  void raw(String s) => bytes(latin1.encode(s));
  void bytes(List<int> b) {
    _out.add(b);
    _pos += b.length;
  }

  void obj(int n, String body) {
    _offsets[n] = _pos;
    raw('$n 0 obj\n$body\nendobj\n');
  }

  void stream(int n, String dict, List<int> data) {
    _offsets[n] = _pos;
    raw('$n 0 obj\n$dict\nstream\n');
    bytes(data);
    raw('\nendstream\nendobj\n');
  }

  Future<void> drain() => _out.flush();

  void finish() {
    final size = (_offsets.keys.fold(0, (a, b) => a > b ? a : b)) + 1;
    final xref = _pos;
    final sb = StringBuffer('xref\n0 $size\n0000000000 65535 f \n');
    for (var n = 1; n < size; n++) {
      final o = _offsets[n];
      sb.write(o == null ? '0000000000 65535 f \n' : '${o.toString().padLeft(10, '0')} 00000 n \n');
    }
    sb.write('trailer\n<< /Size $size /Root 1 0 R /Info 3 0 R >>\nstartxref\n$xref\n%%EOF\n');
    raw(sb.toString());
  }

  Future<void> close() => _out.close();
}
