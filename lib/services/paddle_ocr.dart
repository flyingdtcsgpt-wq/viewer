import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter_onnxruntime/flutter_onnxruntime.dart';
import 'package:image/image.dart' as img;
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

/// 한국어 딥러닝 글자 인식 (PaddleOCR PP-OCRv5, ONNX) — 무료 · 오프라인
///
/// 스캔한 소설 PDF · 그림 속 한국어를 Windows 언어팩과 상관없이 읽는다.
/// 모델(약 20MB)은 원할 때 내려받거나 폴더에서 가져온다. ONNX Runtime 은 자연 음성과 같이 쓴다.
/// 처리: 글자 영역 찾기(DB) → 줄마다 잘라 글자 읽기(CTC) → 위에서 아래 순서로 잇기
class PaddleOcr {
  PaddleOcr._();
  static final instance = PaddleOcr._();

  static const repo = 'monkt/paddleocr-onnx';
  static const _api = 'https://huggingface.co/api/models/$repo/tree/main?recursive=true';
  static const _base = 'https://huggingface.co/$repo/resolve/main';

  static bool get supported => Platform.isWindows || Platform.isMacOS || Platform.isLinux || Platform.isAndroid;

  String? _dir;
  Future<String> dir() async => _dir ??= p.join((await getApplicationSupportDirectory()).path, 'models', 'paddleocr');

  Future<File> _f(String name) async => File(p.join(await dir(), name));

  Future<bool> installed() async {
    for (final n in ['det.onnx', 'rec.onnx', 'dict.txt']) {
      final f = await _f(n);
      if (!await f.exists() || await f.length() == 0) return false;
    }
    return true;
  }

  /// 저장소 파일 목록에서 한국어 모델을 골라 받는다 (경로가 바뀌어도 이름으로 찾음)
  Future<Map<String, String>> pickRemoteFiles() async {
    final client = HttpClient()..userAgent = 'ARARIFlex';
    try {
      final req = await client.getUrl(Uri.parse(_api));
      final res = await req.close();
      if (res.statusCode != 200) throw HttpException('목록 받기 실패 (${res.statusCode})');
      final list = (jsonDecode(await res.transform(utf8.decoder).join()) as List)
          .whereType<Map>()
          .where((e) => e['type'] == 'file')
          .map((e) => e['path'] as String)
          .toList();
      String? best(bool Function(String) ok, List<String> prefer) {
        final c = list.where(ok).toList();
        for (final w in prefer) {
          final hit = c.where((x) => x.toLowerCase().contains(w)).firstOrNull;
          if (hit != null) return hit;
        }
        return c.firstOrNull;
      }

      final det = best((x) => x.toLowerCase().endsWith('.onnx') && x.toLowerCase().contains('det'), ['v5/det', 'v5', 'det']);
      final rec = best((x) => x.toLowerCase().endsWith('.onnx') && x.toLowerCase().contains('korean'), ['v5', 'rec']);
      final dict = best((x) => x.toLowerCase().endsWith('.txt') && x.toLowerCase().contains('korean'), ['dict']);
      if (det == null || rec == null || dict == null) throw '저장소에서 한국어 모델을 찾지 못했습니다';
      return {'det.onnx': det, 'rec.onnx': rec, 'dict.txt': dict};
    } finally {
      client.close(force: true);
    }
  }

  Future<void> download({void Function(String file, int got, int total)? onProgress}) async {
    final files = await pickRemoteFiles();
    final d = Directory(await dir());
    await d.create(recursive: true);
    final client = HttpClient()..userAgent = 'ARARIFlex';
    try {
      for (final e in files.entries) {
        final dest = File(p.join(d.path, e.key));
        final req = await client.getUrl(Uri.parse('$_base/${e.value.split('/').map(Uri.encodeComponent).join('/')}'));
        final res = await req.close();
        if (res.statusCode != 200) throw HttpException('내려받기 실패 (${res.statusCode}): ${e.value}');
        final part = File('${dest.path}.part');
        final sink = part.openWrite();
        var got = 0;
        try {
          await for (final c in res) {
            sink.add(c);
            got += c.length;
            onProgress?.call(e.key, got, res.contentLength);
          }
        } finally {
          await sink.close();
        }
        await part.rename(dest.path);
      }
      await File(p.join(d.path, 'source.txt')).writeAsString(files.entries.map((e) => '${e.key} <- $repo/${e.value}').join('\n'));
    } finally {
      client.close(force: true);
    }
    await unload();
  }

  /// 다른 PC 에서 받아 둔 폴더에서 가져오기: det*.onnx, *korean*rec*.onnx (또는 rec.onnx), *dict*.txt
  Future<int> importFrom(String folder) async {
    final d = Directory(await dir());
    await d.create(recursive: true);
    var n = 0;
    await for (final e in Directory(folder).list(recursive: true, followLinks: false).handleError((_) {})) {
      if (e is! File) continue;
      final name = p.basename(e.path).toLowerCase();
      final full = e.path.toLowerCase().replaceAll('\\', '/');
      String? as;
      if (name.endsWith('.onnx') && name.contains('det')) as = 'det.onnx';
      if (name.endsWith('.onnx') && (full.contains('korean') || name == 'rec.onnx') && !name.contains('det')) as = 'rec.onnx';
      if (name.endsWith('.txt') && name.contains('dict') && (full.contains('korean') || name == 'dict.txt')) as = 'dict.txt';
      if (as == null) continue;
      await e.copy(p.join(d.path, as));
      n++;
    }
    await unload();
    return n;
  }

  Future<void> remove() async {
    await unload();
    final d = Directory(await dir());
    if (await d.exists()) await d.delete(recursive: true);
  }

  // ---------------------------------------------------------------------

  OrtSession? _det, _rec;
  List<String>? _dict;
  Future<void> _queue = Future.value();

  Future<void> _load() async {
    if (_det != null) return;
    final ort = OnnxRuntime();
    final d = await dir();
    _det = await ort.createSession(p.join(d, 'det.onnx'));
    try {
      _rec = await ort.createSession(p.join(d, 'rec.onnx'));
    } catch (_) {
      await _det?.close();
      _det = null;
      rethrow;
    }
    // 사전: 한 줄에 글자 하나, 0번은 공백(blank), 끝에 띄어쓰기
    final lines = const LineSplitter().convert(await File(p.join(d, 'dict.txt')).readAsString());
    _dict = ['', ...lines, ' '];
  }

  Future<void> unload() {
    final c = Completer<void>();
    _queue = _queue.then((_) async {
      try {
        await _det?.close();
        await _rec?.close();
      } catch (_) {}
      _det = null;
      _rec = null;
      _dict = null;
      c.complete();
    });
    return c.future;
  }

  /// 그림 파일(PNG · JPG …) 하나의 글자. 줄마다 줄바꿈
  Future<String> recognizeFile(String path) {
    final c = Completer<String>();
    _queue = _queue.then((_) async {
      try {
        await _load();
        c.complete(await _run(await File(path).readAsBytes()));
      } catch (e, st) {
        c.completeError(e, st);
      }
    });
    return c.future;
  }

  Future<String> _run(Uint8List bytes) async {
    // 1) 글자 영역 찾기 입력 (최대 960px, 32의 배수)
    final prep = await Isolate.run(() => _prepDet(bytes));
    if (prep == null) return '';
    final made = <OrtValue>[];
    try {
      final x = await OrtValue.fromList(prep.tensor, [1, 3, prep.h, prep.w]);
      made.add(x);
      final out = await _det!.run({_det!.inputNames.first: x});
      made.addAll(out.values);
      final probRaw = await out.values.first.asFlattenedList();
      final prob = Float32List.fromList([for (final v in probRaw) (v as num).toDouble()]);
      // 2) 영역 → 상자 (원본 좌표)
      final boxes = await Isolate.run(() => _boxes(prob, prep.w, prep.h, prep.scaleX, prep.scaleY, prep.origW, prep.origH));
      if (boxes.isEmpty) return '';
      // 3) 상자마다 잘라서 글자 읽기 입력
      final crops = await Isolate.run(() => _prepRec(bytes, boxes));
      final lines = <_Line>[];
      for (var i = 0; i < crops.length; i++) {
        final cr = crops[i];
        final t = await OrtValue.fromList(cr.tensor, [1, 3, 48, cr.w]);
        made.add(t);
        final r = await _rec!.run({_rec!.inputNames.first: t});
        made.addAll(r.values);
        final shape = r.values.first.shape;
        final flat = await r.values.first.asFlattenedList();
        final text = _ctc(flat, shape);
        if (text.trim().isNotEmpty) lines.add(_Line(boxes[i], text.trim()));
      }
      return _join(lines);
    } finally {
      for (final v in made) {
        try {
          await v.dispose();
        } catch (_) {}
      }
    }
  }

  /// CTC 탐욕 디코딩: 줄마다 가장 높은 글자, 같은 글자 반복과 blank(0) 제거
  String _ctc(List<dynamic> flat, List<int> shape) {
    final dict = _dict!;
    final t = shape.length >= 3 ? shape[1] : 1;
    final c = shape.length >= 3 ? shape[2] : flat.length;
    final b = StringBuffer();
    var prev = -1;
    for (var i = 0; i < t; i++) {
      var best = 0;
      var bv = -1e30;
      for (var k = 0; k < c; k++) {
        final v = (flat[i * c + k] as num).toDouble();
        if (v > bv) {
          bv = v;
          best = k;
        }
      }
      if (best != 0 && best != prev && best < dict.length) b.write(dict[best]);
      prev = best;
    }
    return b.toString();
  }

  /// 같은 줄(세로로 겹치는 상자)은 왼쪽부터 이어 붙이고, 줄은 위에서 아래로
  static String _join(List<_Line> lines) {
    lines.sort((a, b) => a.box.y0.compareTo(b.box.y0));
    final rows = <List<_Line>>[];
    for (final l in lines) {
      final row = rows.isEmpty ? null : rows.last;
      if (row != null) {
        final r = row.first.box;
        final overlap = math.min(r.y1, l.box.y1) - math.max(r.y0, l.box.y0);
        if (overlap > 0.5 * math.min(r.y1 - r.y0, l.box.y1 - l.box.y0)) {
          row.add(l);
          continue;
        }
      }
      rows.add([l]);
    }
    return rows.map((r) => (r..sort((a, b) => a.box.x0.compareTo(b.box.x0))).map((e) => e.text).join(' ')).join('\n');
  }
}

class _Line {
  final _Box box;
  final String text;
  _Line(this.box, this.text);
}

class _Box {
  final int x0, y0, x1, y1;
  const _Box(this.x0, this.y0, this.x1, this.y1);
}

class _DetPrep {
  final Float32List tensor;
  final int w, h, origW, origH;
  final double scaleX, scaleY;
  _DetPrep(this.tensor, this.w, this.h, this.origW, this.origH, this.scaleX, this.scaleY);
}

class _RecPrep {
  final Float32List tensor;
  final int w;
  _RecPrep(this.tensor, this.w);
}

const _mean = [0.485, 0.456, 0.406];
const _std = [0.229, 0.224, 0.225];

/// 그림 → [1,3,H,W] (BGR 순서, ImageNet 평균/표준편차로 정규화). 긴 변 960 이하, 32의 배수
_DetPrep? _prepDet(Uint8List bytes) {
  final src = img.decodeImage(bytes);
  if (src == null) return null;
  final ow = src.width, oh = src.height;
  final scale = math.min(1.0, 960 / math.max(ow, oh));
  int r32(double v) => math.max(32, (v / 32).round() * 32);
  final w = r32(ow * scale), h = r32(oh * scale);
  final im = img.copyResize(src, width: w, height: h, interpolation: img.Interpolation.linear);
  final t = Float32List(3 * w * h);
  for (var y = 0; y < h; y++) {
    for (var x = 0; x < w; x++) {
      final px = im.getPixel(x, y);
      final bgr = [px.b / 255.0, px.g / 255.0, px.r / 255.0];
      for (var c = 0; c < 3; c++) {
        t[c * w * h + y * w + x] = (bgr[c] - _mean[c]) / _std[c];
      }
    }
  }
  return _DetPrep(t, w, h, ow, oh, ow / w, oh / h);
}

/// 확률 지도 → 글자 상자 (연결된 영역의 바깥 상자를 조금 넓힘)
List<_Box> _boxes(Float32List prob, int w, int h, double sx, double sy, int ow, int oh) {
  const thresh = 0.3, boxThresh = 0.6, unclip = 1.6;
  final seen = Uint8List(w * h);
  final out = <_Box>[];
  final stack = <int>[];
  for (var i = 0; i < w * h; i++) {
    if (seen[i] == 1 || prob[i] <= thresh) continue;
    var minX = w, minY = h, maxX = 0, maxY = 0, n = 0;
    var sum = 0.0;
    stack
      ..clear()
      ..add(i);
    seen[i] = 1;
    while (stack.isNotEmpty) {
      final k = stack.removeLast();
      final x = k % w, y = k ~/ w;
      n++;
      sum += prob[k];
      if (x < minX) minX = x;
      if (x > maxX) maxX = x;
      if (y < minY) minY = y;
      if (y > maxY) maxY = y;
      for (final nb in [k - 1, k + 1, k - w, k + w]) {
        if (nb < 0 || nb >= w * h) continue;
        if ((nb == k - 1 && x == 0) || (nb == k + 1 && x == w - 1)) continue;
        if (seen[nb] == 0 && prob[nb] > thresh) {
          seen[nb] = 1;
          stack.add(nb);
        }
      }
    }
    final bw = maxX - minX + 1, bh = maxY - minY + 1;
    if (bw < 3 || bh < 3 || sum / n < boxThresh) continue;
    // 상자 넓히기: 넓이 × 비율 / 둘레
    final d = bw * bh * unclip / (2 * (bw + bh));
    final x0 = ((minX - d) * sx).floor().clamp(0, ow - 1);
    final y0 = ((minY - d) * sy).floor().clamp(0, oh - 1);
    final x1 = ((maxX + 1 + d) * sx).ceil().clamp(1, ow);
    final y1 = ((maxY + 1 + d) * sy).ceil().clamp(1, oh);
    if (x1 - x0 < 4 || y1 - y0 < 4) continue;
    out.add(_Box(x0, y0, x1, y1));
  }
  return out;
}

/// 상자마다 잘라 높이 48 로 맞춘 [1,3,48,W] (값 -1~1, BGR)
List<_RecPrep> _prepRec(Uint8List bytes, List<_Box> boxes) {
  final src = img.decodeImage(bytes)!;
  final out = <_RecPrep>[];
  for (final b in boxes) {
    final crop = img.copyCrop(src, x: b.x0, y: b.y0, width: b.x1 - b.x0, height: b.y1 - b.y0);
    final w = math.max(16, math.min(2000, (48 * crop.width / crop.height).ceil()));
    final im = img.copyResize(crop, width: w, height: 48, interpolation: img.Interpolation.linear);
    final t = Float32List(3 * 48 * w);
    for (var y = 0; y < 48; y++) {
      for (var x = 0; x < w; x++) {
        final px = im.getPixel(x, y);
        final bgr = [px.b / 255.0, px.g / 255.0, px.r / 255.0];
        for (var c = 0; c < 3; c++) {
          t[c * 48 * w + y * w + x] = (bgr[c] - 0.5) / 0.5;
        }
      }
    }
    out.add(_RecPrep(t, w));
  }
  return out;
}
