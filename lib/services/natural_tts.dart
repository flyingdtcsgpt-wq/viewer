import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter_onnxruntime/flutter_onnxruntime.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

/// 자연스러운 음성 (오프라인, 무료)
///
/// Supertone 이 공개한 Supertonic 3 음성 합성 모델을 ONNX Runtime 으로 기기에서 직접 돌린다.
/// 모델(약 수백 MB)은 앱에 넣지 않고, 원할 때 설정에서 내려받거나 폴더에서 가져온다.
/// 추론 코드는 Supertonic 공식 Flutter 예제(MIT)를 옮겨 다듬은 것이다.
/// 모델 라이선스: OpenRAIL-M (THIRD_PARTY_NOTICES.txt 참고)
class NaturalTts {
  NaturalTts._();
  static final instance = NaturalTts._();

  /// 고정된 모델 판 (보관본)
  static const revision = 'aafc6e32416a594460b32413efc49d7fe4ce6d46';
  static const repo = 'supertone-oss-archive/supertonic-3';
  static const _base = 'https://huggingface.co/$repo/resolve/$revision';
  static const onnxFiles = [
    'tts.json',
    'unicode_indexer.json',
    'duration_predictor.onnx',
    'text_encoder.onnx',
    'vector_estimator.onnx',
    'vocoder.onnx',
  ];
  static const voiceIds = ['F1', 'F2', 'F3', 'F4', 'F5', 'M1', 'M2', 'M3', 'M4', 'M5'];

  /// 음성 선택 목록에 쓰는 이름 ("st:F1")
  static const prefix = 'st:';
  static bool isNatural(String voice) => voice.startsWith(prefix);
  static String label(String voice) {
    final id = voice.startsWith(prefix) ? voice.substring(prefix.length) : voice;
    if (id.length < 2) return voice;
    return '자연 음성 · ${id[0] == 'F' ? '여성' : '남성'} ${id.substring(1)}';
  }

  /// 플랫폼 지원 (ONNX Runtime 플러그인이 있는 곳)
  static bool get supported => Platform.isWindows || Platform.isAndroid || Platform.isMacOS || Platform.isLinux;

  String? _dir;
  Future<String> dir() async {
    if (_dir != null) return _dir!;
    final base = await getApplicationSupportDirectory();
    return _dir = p.join(base.path, 'voices', 'supertonic-3');
  }

  String _onnxPath(String d, String f) => p.join(d, 'onnx', f);
  String _voicePath(String d, String id) => p.join(d, 'voice_styles', '$id.json');

  /// 필요한 파일이 다 있는가
  Future<bool> installed() async {
    final d = await dir();
    for (final f in onnxFiles) {
      if (!await File(_onnxPath(d, f)).exists()) return false;
    }
    return await File(_voicePath(d, 'F1')).exists();
  }

  /// 설치된 음성 ("st:F1" …)
  Future<List<String>> voices() async {
    if (!supported || !await installed()) return [];
    final d = await dir();
    return [
      for (final id in voiceIds)
        if (await File(_voicePath(d, id)).exists()) '$prefix$id',
    ];
  }

  /// 인터넷에서 내려받기. [onProgress] (지금 파일, 받은 바이트, 전체 바이트)
  Future<void> download({void Function(String file, int got, int total)? onProgress, bool Function()? cancelled}) async {
    final d = await dir();
    final jobs = <(String url, String dest)>[
      for (final f in onnxFiles) ('$_base/onnx/$f', _onnxPath(d, f)),
      for (final id in voiceIds) ('$_base/voice_styles/$id.json', _voicePath(d, id)),
    ];
    final client = HttpClient()..userAgent = 'ARARIFlex';
    try {
      for (final (url, dest) in jobs) {
        if (await File(dest).exists() && await File(dest).length() > 0) continue;
        await Directory(p.dirname(dest)).create(recursive: true);
        final req = await client.getUrl(Uri.parse(url));
        final res = await req.close();
        if (res.statusCode != 200) {
          throw HttpException('내려받기 실패 (${res.statusCode}): ${p.basename(dest)}', uri: Uri.parse(url));
        }
        final total = res.contentLength;
        final part = File('$dest.part');
        final sink = part.openWrite();
        var got = 0;
        try {
          await for (final chunk in res) {
            if (cancelled?.call() ?? false) throw const _Cancelled();
            sink.add(chunk);
            got += chunk.length;
            onProgress?.call(p.basename(dest), got, total);
          }
        } finally {
          await sink.close();
        }
        await part.rename(dest);
      }
    } finally {
      client.close(force: true);
    }
    await unload();
  }

  /// 다른 PC 에서 받아 둔 폴더에서 가져오기 (인터넷 없는 PC 용).
  /// 폴더 안 어디에 있든 파일 이름으로 찾는다. 가져온 파일 수를 돌려준다.
  Future<int> importFrom(String folder) async {
    final d = await dir();
    final want = {
      for (final f in onnxFiles) f: _onnxPath(d, f),
      for (final id in voiceIds) '$id.json': _voicePath(d, id),
    };
    var n = 0;
    await for (final e in Directory(folder).list(recursive: true, followLinks: false).handleError((_) {})) {
      if (e is! File) continue;
      final name = p.basename(e.path);
      final dest = want[name];
      if (dest == null) continue;
      // 이름이 겹치는 다른 json 을 막기 위해: 음성은 voice_styles 폴더 안의 것만
      if (name.endsWith('.json') && voiceIds.contains(p.basenameWithoutExtension(name)) && !e.path.replaceAll('\\', '/').contains('voice_styles')) {
        continue;
      }
      await Directory(p.dirname(dest)).create(recursive: true);
      await e.copy(dest);
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
  //  합성
  // ---------------------------------------------------------------------

  _Engine? _engine;
  Future<_Engine>? _loading;
  final Map<String, _Style> _styles = {};
  Future<void> _queue = Future.value(); // 한 번에 하나씩 합성

  Future<_Engine> _load() {
    if (_engine != null) return Future.value(_engine!);
    return _loading ??= () async {
      try {
        final d = await dir();
        final e = await _Engine.load(p.join(d, 'onnx'));
        _engine = e;
        return e;
      } finally {
        _loading = null;
      }
    }();
  }

  Future<_Style> _style(String id) async {
    final hit = _styles[id];
    if (hit != null) return hit;
    final d = await dir();
    return _styles[id] = await _Style.load(_voicePath(d, id));
  }

  /// 모델을 메모리에서 내린다. 진행 중인 합성이 끝난 뒤에 (합성 줄에 같이 세움)
  Future<void> unload() {
    final c = Completer<void>();
    _queue = _queue.then((_) async {
      try {
        await _loading;
      } catch (_) {}
      final e = _engine;
      _engine = null;
      for (final s in _styles.values) {
        try {
          await s.dispose();
        } catch (_) {}
      }
      _styles.clear();
      try {
        await e?.close();
      } catch (_) {}
      c.complete();
    });
    return c.future;
  }

  /// 글을 음성 파일(WAV)로 만든다. [speed] 1.0 = 보통
  /// [wanted] 가 false 를 돌려주면 (차례가 왔을 때 이미 필요 없어졌으면) 건너뛴다
  Future<String> synthesize(String text, String voice, {double speed = 1.05, int steps = 8, bool Function()? wanted}) {
    final id = voice.startsWith(prefix) ? voice.substring(prefix.length) : voice;
    final c = Completer<String>();
    _queue = _queue.then((_) async {
      if (wanted != null && !wanted()) {
        c.completeError(StateError('cancelled'));
        return;
      }
      try {
        final engine = await _load();
        final style = await _style(id);
        final samples = await engine.speak(text, langOf(text), style, steps: steps, speed: speed);
        final tmp = await getTemporaryDirectory();
        final out = p.join(tmp.path, 'arari_tts_${DateTime.now().microsecondsSinceEpoch}.wav');
        await File(out).writeAsBytes(wavBytes(samples, engine.sampleRate));
        c.complete(out);
      } catch (e, st) {
        c.completeError(e, st);
      }
    });
    return c.future;
  }

  /// 언어 고르기: 한글이 있으면 ko, 일본 가나면 ja, 로마자뿐이면 en, 나머지는 자동(na)
  static String langOf(String t) {
    if (RegExp(r'[가-힣]').hasMatch(t)) return 'ko';
    if (RegExp(r'[぀-ヿ]').hasMatch(t)) return 'ja';
    if (RegExp(r'[A-Za-z]').hasMatch(t) && !RegExp(r'[^\x00-\x7F’“”‘—–…]').hasMatch(t)) return 'en';
    return 'na';
  }

  /// 16비트 모노 WAV
  static Uint8List wavBytes(Float32List samples, int sampleRate) {
    final dataSize = samples.length * 2;
    final b = ByteData(44 + dataSize);
    void str(int o, String s) {
      for (var i = 0; i < s.length; i++) {
        b.setUint8(o + i, s.codeUnitAt(i));
      }
    }

    str(0, 'RIFF');
    b.setUint32(4, 36 + dataSize, Endian.little);
    str(8, 'WAVE');
    str(12, 'fmt ');
    b.setUint32(16, 16, Endian.little);
    b.setUint16(20, 1, Endian.little);
    b.setUint16(22, 1, Endian.little);
    b.setUint32(24, sampleRate, Endian.little);
    b.setUint32(28, sampleRate * 2, Endian.little);
    b.setUint16(32, 2, Endian.little);
    b.setUint16(34, 16, Endian.little);
    str(36, 'data');
    b.setUint32(40, dataSize, Endian.little);
    for (var i = 0; i < samples.length; i++) {
      b.setInt16(44 + i * 2, (samples[i].clamp(-1.0, 1.0) * 32767).round(), Endian.little);
    }
    return b.buffer.asUint8List();
  }
}

class _Cancelled implements Exception {
  const _Cancelled();
  @override
  String toString() => '취소했습니다';
}

// =====================================================================
//  글 → 숫자 (Supertonic 전처리)
// =====================================================================

const _availableLangs = {'en', 'ko', 'ja', 'ar', 'bg', 'cs', 'da', 'de', 'el', 'es', 'et', 'fi', 'fr', 'hi', 'hr', 'hu', 'id', 'it', 'lt', 'lv', 'nl', 'pl', 'pt', 'ro', 'ru', 'sk', 'sl', 'sv', 'tr', 'uk', 'vi', 'na'};

/// 한글 음절 → 자모 (NFKD 와 같은 분해)
String _decompose(String text) {
  final out = <int>[];
  for (final c in text.runes) {
    if (c >= 0xAC00 && c <= 0xD7A3) {
      final s = c - 0xAC00;
      out
        ..add(0x1100 + s ~/ (21 * 28))
        ..add(0x1161 + (s % (21 * 28)) ~/ 28);
      if (s % 28 > 0) out.add(0x11A7 + s % 28);
    } else {
      out.add(c);
    }
  }
  return String.fromCharCodes(out);
}

String preprocessText(String text, String lang) {
  text = _decompose(text);
  text = text.replaceAll(
      RegExp(
        r'[\u{1F600}-\u{1F64F}]|[\u{1F300}-\u{1F5FF}]|[\u{1F680}-\u{1F6FF}]|[\u{1F700}-\u{1F8FF}]|'
        r'[\u{1F900}-\u{1FAFF}]|[\u{2600}-\u{27BF}]|[\u{1F1E6}-\u{1F1FF}]',
        unicode: true,
      ),
      '');
  const rep = {
    '–': '-', '‑': '-', '—': '-', '_': ' ', '“': '"', '”': '"', '‘': "'", '’': "'",
    '´': "'", '`': "'", '[': ' ', ']': ' ', '|': ' ', '/': ' ', '#': ' ', '→': ' ', '←': ' ',
    // 한국 소설에 흔한 따옴표 · 말줄임
    '「': '"', '」': '"', '『': '"', '』': '"', '…': '...', '~': ' ',
  };
  rep.forEach((a, b) => text = text.replaceAll(a, b));
  text = text.replaceAll(RegExp(r'[♥☆♡©\\*]'), '');
  for (final pnc in [',', '.', '!', '?', ';', ':']) {
    text = text.replaceAll(' $pnc', pnc);
  }
  while (text.contains('""')) {
    text = text.replaceAll('""', '"');
  }
  while (text.contains("''")) {
    text = text.replaceAll("''", "'");
  }
  text = text.replaceAll(RegExp(r'\s+'), ' ').trim();
  if (text.isNotEmpty && !RegExp(r'''[.!?;:,'"‘’)\]}…。」』】〉》›»]$''').hasMatch(text)) text += '.';
  if (!_availableLangs.contains(lang)) lang = 'na';
  return '<$lang>$text</$lang>';
}

/// 긴 글을 모델이 다루기 좋은 길이로 나누기 (문장 단위)
List<String> chunkText(String text, {int maxLen = 300}) {
  final out = <String>[];
  for (var para in text.trim().split(RegExp(r'\n\s*\n+'))) {
    para = para.replaceAll(RegExp(r'\s+'), ' ').trim();
    if (para.isEmpty) continue;
    final sentences = para.split(RegExp(r'(?<=[.!?。？！])\s+'));
    var cur = '';
    for (var s in sentences) {
      // 한 문장이 너무 길면 쉼표/공백에서 자른다
      while (s.length > maxLen) {
        var cut = s.lastIndexOf(RegExp(r'[,，]\s'), maxLen);
        if (cut < maxLen ~/ 3) cut = s.lastIndexOf(' ', maxLen);
        if (cut < maxLen ~/ 3) cut = maxLen;
        final head = s.substring(0, cut + (cut < s.length && s[cut] != ' ' ? 1 : 0)).trim();
        if (cur.isNotEmpty) {
          out.add(cur);
          cur = '';
        }
        out.add(head);
        s = s.substring(head.length).trim();
      }
      if (cur.length + s.length + 1 <= maxLen) {
        cur = cur.isEmpty ? s : '$cur $s';
      } else {
        if (cur.isNotEmpty) out.add(cur);
        cur = s;
      }
    }
    if (cur.isNotEmpty) out.add(cur);
  }
  return out;
}

class _Indexer {
  final Map<int, int> map;
  _Indexer(this.map);
  static Future<_Indexer> load(String path) async {
    final j = jsonDecode(await File(path).readAsString());
    if (j is List) {
      return _Indexer({
        for (var i = 0; i < j.length; i++)
          if (j[i] is int && (j[i] as int) >= 0) i: j[i] as int,
      });
    }
    return _Indexer((j as Map<String, dynamic>).map((k, v) => MapEntry(int.parse(k), v as int)));
  }

  Int64List ids(String processed) {
    final r = processed.runes.toList();
    return Int64List.fromList([for (final c in r) map[c] ?? 0]);
  }
}

class _Style {
  final OrtValue ttl, dp;
  _Style(this.ttl, this.dp);
  static Future<_Style> load(String path) async {
    final j = jsonDecode(await File(path).readAsString()) as Map<String, dynamic>;
    Future<OrtValue> t(String key) {
      final dims = List<int>.from(j[key]['dims'] as List);
      final flat = Float32List.fromList(_flat(j[key]['data']));
      return OrtValue.fromList(flat, [1, dims[1], dims[2]]);
    }

    return _Style(await t('style_ttl'), await t('style_dp'));
  }

  Future<void> dispose() async {
    await ttl.dispose();
    await dp.dispose();
  }

  static List<double> _flat(dynamic x) => x is List ? [for (final e in x) ..._flat(e)] : [(x as num).toDouble()];
}

class _Engine {
  final OrtSession dpOrt, encOrt, estOrt, vocOrt;
  final _Indexer indexer;
  final int sampleRate, baseChunk, compress, ldim;
  _Engine(this.dpOrt, this.encOrt, this.estOrt, this.vocOrt, this.indexer, Map<String, dynamic> cfg)
      : sampleRate = cfg['ae']['sample_rate'] as int,
        baseChunk = cfg['ae']['base_chunk_size'] as int,
        compress = cfg['ttl']['chunk_compress_factor'] as int,
        ldim = cfg['ttl']['latent_dim'] as int;

  static Future<_Engine> load(String onnxDir) async {
    final cfg = jsonDecode(await File(p.join(onnxDir, 'tts.json')).readAsString()) as Map<String, dynamic>;
    final ort = OnnxRuntime();
    final s = <OrtSession>[];
    try {
      for (final n in ['duration_predictor', 'text_encoder', 'vector_estimator', 'vocoder']) {
        s.add(await ort.createSession(p.join(onnxDir, '$n.onnx')));
      }
    } catch (_) {
      for (final x in s) {
        try {
          await x.close();
        } catch (_) {}
      }
      rethrow;
    }
    final idx = await _Indexer.load(p.join(onnxDir, 'unicode_indexer.json'));
    return _Engine(s[0], s[1], s[2], s[3], idx, cfg);
  }

  Future<void> close() async {
    for (final s in [dpOrt, encOrt, estOrt, vocOrt]) {
      await s.close();
    }
  }

  /// 글 전체 → 소리 (문장 묶음마다 합성하고 사이에 짧은 쉼)
  Future<Float32List> speak(String text, String lang, _Style style, {int steps = 8, double speed = 1.05}) async {
    final maxLen = (lang == 'ko' || lang == 'ja') ? 120 : 300;
    final parts = <Float32List>[];
    final gap = Float32List((0.3 * sampleRate).floor());
    for (final chunk in chunkText(text, maxLen: maxLen)) {
      if (parts.isNotEmpty) parts.add(gap);
      parts.add(await _infer(chunk, lang, style, steps, speed));
    }
    final total = parts.fold<int>(0, (a, b) => a + b.length);
    final out = Float32List(total);
    var o = 0;
    for (final x in parts) {
      out.setAll(o, x);
      o += x.length;
    }
    return out;
  }

  Future<Float32List> _infer(String text, String lang, _Style style, int steps, double speed) async {
    final made = <OrtValue>[]; // 다 쓰고 지울 텐서
    Future<OrtValue> f32(List<double> data, List<int> shape) async {
      final v = await OrtValue.fromList(Float32List.fromList(data), shape);
      made.add(v);
      return v;
    }

    final outs = <OrtValue>[];
    try {
      final ids = indexer.ids(preprocessText(text, lang));
      final n = ids.length;
      final idsT = await OrtValue.fromList(ids, [1, n]);
      made.add(idsT);
      final maskT = await f32(List.filled(n, 1.0), [1, 1, n]);

      final dpOut = await dpOrt.run({'text_ids': idsT, 'style_dp': style.dp, 'text_mask': maskT});
      outs.addAll(dpOut.values);
      final dur = (await dpOut.values.first.asFlattenedList()).first as num;
      final seconds = dur.toDouble() / speed;

      final encOut = await encOrt.run({'text_ids': idsT, 'style_ttl': style.ttl, 'text_mask': maskT});
      outs.addAll(encOut.values);
      final emb = encOut.values.first;

      // 잡음에서 시작해 여러 번 다듬는다
      final wavLen = (seconds * sampleRate).floor();
      final chunk = baseChunk * compress;
      final latLen = math.max(1, (wavLen + chunk - 1) ~/ chunk);
      final latDim = ldim * compress;
      final rnd = math.Random();
      var latent = Float32List(latDim * latLen);
      for (var i = 0; i < latent.length; i++) {
        final u1 = math.max(1e-10, rnd.nextDouble());
        final u2 = rnd.nextDouble();
        latent[i] = math.sqrt(-2.0 * math.log(u1)) * math.cos(2.0 * math.pi * u2);
      }
      final latMaskT = await f32(List.filled(latLen, 1.0), [1, 1, latLen]);
      final totalT = await f32([steps.toDouble()], [1]);
      for (var step = 0; step < steps; step++) {
        final noisy = await OrtValue.fromList(latent, [1, latDim, latLen]);
        final cur = await OrtValue.fromList(Float32List.fromList([step.toDouble()]), [1]);
        try {
          final r = await estOrt.run({
            'noisy_latent': noisy,
            'text_emb': emb,
            'style_ttl': style.ttl,
            'text_mask': maskT,
            'latent_mask': latMaskT,
            'total_step': totalT,
            'current_step': cur,
          });
          final flat = await r.values.first.asFlattenedList();
          latent = Float32List.fromList([for (final x in flat) (x as num).toDouble()]);
          for (final v in r.values) {
            await v.dispose();
          }
        } finally {
          await noisy.dispose();
          await cur.dispose();
        }
      }

      final latT = await OrtValue.fromList(latent, [1, latDim, latLen]);
      made.add(latT);
      final vOut = await vocOrt.run({'latent': latT});
      outs.addAll(vOut.values);
      final wav = await vOut.values.first.asFlattenedList();
      final len = math.min(wav.length, wavLen > 0 ? wavLen : wav.length);
      return Float32List.fromList([for (var i = 0; i < len; i++) (wav[i] as num).toDouble()]);
    } finally {
      for (final v in [...made, ...outs]) {
        try {
          await v.dispose();
        } catch (_) {}
      }
    }
  }
}
