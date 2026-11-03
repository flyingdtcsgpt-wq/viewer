import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:flutter_onnxruntime/flutter_onnxruntime.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import 'natural_tts.dart';

/// 영어 원서용 AI 성우 (Kokoro-82M v1.0, ONNX) — 무료 · 오프라인
///
/// 영어 글 → eSpeak NG 로 발음 기호(IPA) → Kokoro 모델 → 24kHz 음성.
/// 한국어는 지원하지 않는다(한국어는 Supertonic 자연 음성). 모델은 설정에서 받거나 폴더에서 가져온다.
/// eSpeak NG(GPL-3)는 Windows 설치파일의 tools/espeak-ng 에 들어 있고, 맥 · 리눅스는 설치된 espeak-ng 를 쓴다.
class KokoroTts {
  KokoroTts._();
  static final instance = KokoroTts._();

  static const prefix = 'kk:';
  static bool isKokoro(String v) => v.startsWith(prefix);
  static const _base = 'https://github.com/thewh1teagle/kokoro-onnx/releases/download/model-files-v1.1';
  static const voicesFile = 'voices-v1.0.bin';
  static const fastModel = 'kokoro-v1.0.int8.onnx'; // 약 90MB, 그래픽카드 없는 PC 에서 빠름
  static const fullModel = 'kokoro-v1.0.onnx'; // 약 310MB, 원본 음질

  static bool get platformOk => Platform.isWindows || Platform.isMacOS || Platform.isLinux;

  static String label(String voice) {
    final id = voice.startsWith(prefix) ? voice.substring(prefix.length) : voice;
    if (id.length < 4) return voice;
    final region = id[0] == 'b' ? '영국' : '미국';
    final g = id[1] == 'm' ? '남성' : '여성';
    final name = id.substring(3);
    return 'Kokoro 영어($region) $g · ${name[0].toUpperCase()}${name.substring(1)}';
  }

  String? _dir;
  Future<String> dir() async => _dir ??= p.join((await getApplicationSupportDirectory()).path, 'models', 'kokoro');

  /// 쓸 모델 파일 (원본이 있으면 원본, 없으면 빠른 판)
  Future<String?> modelPath() async {
    final d = await dir();
    for (final n in [fullModel, fastModel]) {
      final f = File(p.join(d, n));
      if (await f.exists() && await f.length() > 0) return f.path;
    }
    return null;
  }

  Future<bool> installed() async => await modelPath() != null && await File(p.join(await dir(), voicesFile)).exists();

  // ---- eSpeak NG ----
  String? _espeak;
  String? _espeakData;
  Future<bool> espeakReady() async => (await _findEspeak()) != null;

  Future<String?> _findEspeak() async {
    if (_espeak != null) return _espeak;
    // 직접 지정 (예: 개발 · 검사용)
    final env = Platform.environment['ESPEAK_NG_PATH'];
    if (env != null && await File(env).exists()) {
      _espeakData = p.dirname(env);
      return _espeak = env;
    }
    if (Platform.isWindows) {
      final base = p.join(p.dirname(Platform.resolvedExecutable), 'tools', 'espeak-ng');
      final exe = File(p.join(base, 'espeak-ng.exe'));
      if (await exe.exists()) {
        _espeakData = base; // espeak-ng-data 가 들어 있는 폴더
        return _espeak = exe.path;
      }
      return null;
    }
    for (final c in ['/opt/homebrew/bin/espeak-ng', '/usr/local/bin/espeak-ng', '/usr/bin/espeak-ng']) {
      if (await File(c).exists()) return _espeak = c;
    }
    return null;
  }

  /// 영어 문장 → 발음 기호 (강세 포함)
  Future<String> phonemize(String text, {bool british = false}) async {
    final exe = await _findEspeak();
    if (exe == null) throw StateError('eSpeak NG 가 없습니다');
    final proc = await Process.start(exe, [
      if (_espeakData != null) '--path=$_espeakData',
      '-q',
      '--ipa',
      '-v',
      british ? 'en-gb' : 'en-us',
      '--stdin',
    ]);
    proc.stdin.add(utf8.encode(text));
    await proc.stdin.close();
    final outF = proc.stdout.transform(utf8.decoder).join();
    proc.stderr.drain<void>();
    await proc.exitCode.timeout(const Duration(seconds: 30), onTimeout: () {
      proc.kill();
      return -1;
    });
    final r = (stdout: await outF);
    return r.stdout.replaceAll(RegExp(r'\s+'), ' ').trim();
  }

  // ---- 받기 · 가져오기 ----
  Future<void> download({bool full = false, void Function(String file, int got, int total)? onProgress}) async {
    final d = Directory(await dir());
    await d.create(recursive: true);
    final client = HttpClient()..userAgent = 'ARARIFlex';
    try {
      for (final name in [voicesFile, full ? fullModel : fastModel]) {
        final dest = File(p.join(d.path, name));
        if (await dest.exists() && await dest.length() > 0) continue;
        final req = await client.getUrl(Uri.parse('$_base/$name'));
        final res = await req.close();
        if (res.statusCode != 200) throw HttpException('내려받기 실패 (${res.statusCode}): $name');
        final part = File('${dest.path}.part');
        final sink = part.openWrite();
        var got = 0;
        try {
          await for (final c in res) {
            sink.add(c);
            got += c.length;
            onProgress?.call(name, got, res.contentLength);
          }
        } finally {
          await sink.close();
        }
        await part.rename(dest.path);
      }
    } finally {
      client.close(force: true);
    }
    await unload();
  }

  Future<int> importFrom(String folder) async {
    final d = Directory(await dir());
    await d.create(recursive: true);
    var n = 0;
    await for (final e in Directory(folder).list(recursive: true, followLinks: false).handleError((_) {})) {
      if (e is! File) continue;
      final name = p.basename(e.path);
      if (name == voicesFile || name == fastModel || name == fullModel) {
        await e.copy(p.join(d.path, name));
        n++;
      }
    }
    await unload();
    return n;
  }

  Future<void> remove() async {
    await unload();
    final d = Directory(await dir());
    if (await d.exists()) await d.delete(recursive: true);
  }

  /// 영어 목소리들 ("kk:af_heart" …). 미국(a) · 영국(b) 만
  Future<List<String>> voices() async {
    if (!platformOk || !await installed() || !await espeakReady()) return [];
    final v = await _loadVoices();
    final ids = v.keys.where((k) => k.startsWith('a') || k.startsWith('b')).toList()..sort();
    return [for (final k in ids) '$prefix$k'];
  }

  // ---- 합성 ----
  Map<String, Float32List>? _voices; // 이름 → [510 × 256]
  OrtSession? _session;
  String? _tokensInput;
  Future<void> _queue = Future.value();

  Future<Map<String, Float32List>> _loadVoices() async {
    if (_voices != null) return _voices!;
    final bytes = await File(p.join(await dir(), voicesFile)).readAsBytes();
    final v = await Isolate.run(() => _readNpz(bytes));
    _voices = v;
    return v;
  }

  Future<void> unload() {
    final c = Completer<void>();
    _queue = _queue.then((_) async {
      try {
        await _session?.close();
      } catch (_) {}
      _session = null;
      _voices = null;
      c.complete();
    });
    return c.future;
  }

  Future<String> synthesize(String text, String voice, {double speed = 1.0, bool Function()? wanted}) {
    final id = voice.startsWith(prefix) ? voice.substring(prefix.length) : voice;
    final c = Completer<String>();
    _queue = _queue.then((_) async {
      if (wanted != null && !wanted()) {
        c.completeError(StateError('cancelled'));
        return;
      }
      try {
        final model = await modelPath();
        if (model == null) throw StateError('Kokoro 모델이 없습니다');
        _session ??= await OnnxRuntime().createSession(model);
        _tokensInput ??= _session!.inputNames.contains('input_ids') ? 'input_ids' : 'tokens';
        final style = (await _loadVoices())[id];
        if (style == null) throw StateError('목소리 $id 가 없습니다');
        final parts = <Float32List>[];
        final gap = Float32List((0.25 * 24000).floor());
        for (final sentence in chunkText(text, maxLen: 300)) {
          final ph = await phonemize(sentence, british: id.startsWith('b'));
          final tokens = [for (final ch in ph.runes) kokoroVocab[String.fromCharCode(ch)]].whereType<int>().toList();
          if (tokens.isEmpty) continue;
          for (var i = 0; i < tokens.length; i += 500) {
            final t = tokens.sublist(i, math.min(tokens.length, i + 500));
            if (parts.isNotEmpty) parts.add(gap);
            parts.add(await _infer(t, style, speed));
          }
        }
        final total = parts.fold<int>(0, (a, b) => a + b.length);
        final out = Float32List(total);
        var o = 0;
        for (final x in parts) {
          out.setAll(o, x);
          o += x.length;
        }
        final tmp = await getTemporaryDirectory();
        await tmp.create(recursive: true);
        final path = p.join(tmp.path, 'arari_kokoro_${DateTime.now().microsecondsSinceEpoch}.wav');
        await File(path).writeAsBytes(NaturalTts.wavBytes(out, 24000));
        c.complete(path);
      } catch (e, st) {
        c.completeError(e, st);
      }
    });
    return c.future;
  }

  Future<Float32List> _infer(List<int> tokens, Float32List voice, double speed) async {
    // 글자 수에 맞는 스타일 한 줄 (n 개면 n-1 번째 줄)
    final row = math.min(tokens.length, 510) - 1;
    final style = Float32List.sublistView(voice, row * 256, row * 256 + 256);
    final made = <OrtValue>[];
    try {
      final ids = await OrtValue.fromList(Int64List.fromList([0, ...tokens, 0]), [1, tokens.length + 2]);
      final st = await OrtValue.fromList(Float32List.fromList(style), [1, 256]);
      final sp = await OrtValue.fromList(Float32List.fromList([speed.clamp(0.5, 2.0)]), [1]);
      made.addAll([ids, st, sp]);
      final r = await _session!.run({_tokensInput!: ids, 'style': st, 'speed': sp});
      made.addAll(r.values);
      final audio = await r.values.first.asFlattenedList();
      return Float32List.fromList([for (final v in audio) (v as num).toDouble()]);
    } finally {
      for (final v in made) {
        try {
          await v.dispose();
        } catch (_) {}
      }
    }
  }
}

/// numpy .npz (zip 안의 .npy 들) → 이름 → float32 배열
Map<String, Float32List> _readNpz(Uint8List bytes) {
  final out = <String, Float32List>{};
  for (final f in ZipDecoder().decodeBytes(bytes).files) {
    if (!f.isFile || !f.name.endsWith('.npy')) continue;
    final b = f.content;
    final bd = ByteData.sublistView(b);
    final major = b[6];
    final hlen = major == 1 ? bd.getUint16(8, Endian.little) : bd.getUint32(8, Endian.little);
    final start = (major == 1 ? 10 : 12) + hlen;
    final header = latin1.decode(b.sublist(major == 1 ? 10 : 12, start));
    if (!header.contains("'<f4'")) continue;
    final n = (b.length - start) ~/ 4;
    final data = Float32List(n);
    for (var i = 0; i < n; i++) {
      data[i] = bd.getFloat32(start + i * 4, Endian.little);
    }
    out[f.name.substring(0, f.name.length - 4)] = data;
  }
  return out;
}

const kokoroVocab = <String, int>{
  ';': 1,
  ':': 2,
  ',': 3,
  '.': 4,
  '!': 5,
  '?': 6,
  '\u{2014}': 9,
  '\u{2026}': 10,
  '"': 11,
  '(': 12,
  ')': 13,
  '\u{201c}': 14,
  '\u{201d}': 15,
  ' ': 16,
  '\u{303}': 17,
  '\u{2a3}': 18,
  '\u{2a5}': 19,
  '\u{2a6}': 20,
  '\u{2a8}': 21,
  '\u{1d5d}': 22,
  '\u{ab67}': 23,
  'A': 24,
  'I': 25,
  'O': 31,
  'Q': 33,
  'S': 35,
  'T': 36,
  'W': 39,
  'Y': 41,
  '\u{1d4a}': 42,
  'a': 43,
  'b': 44,
  'c': 45,
  'd': 46,
  'e': 47,
  'f': 48,
  'h': 50,
  'i': 51,
  'j': 52,
  'k': 53,
  'l': 54,
  'm': 55,
  'n': 56,
  'o': 57,
  'p': 58,
  'q': 59,
  'r': 60,
  's': 61,
  't': 62,
  'u': 63,
  'v': 64,
  'w': 65,
  'x': 66,
  'y': 67,
  'z': 68,
  '\u{251}': 69,
  '\u{250}': 70,
  '\u{252}': 71,
  '\u{e6}': 72,
  '\u{3b2}': 75,
  '\u{254}': 76,
  '\u{255}': 77,
  '\u{e7}': 78,
  '\u{256}': 80,
  '\u{f0}': 81,
  '\u{2a4}': 82,
  '\u{259}': 83,
  '\u{25a}': 85,
  '\u{25b}': 86,
  '\u{25c}': 87,
  '\u{25f}': 90,
  '\u{261}': 92,
  '\u{265}': 99,
  '\u{268}': 101,
  '\u{26a}': 102,
  '\u{29d}': 103,
  '\u{26f}': 110,
  '\u{270}': 111,
  '\u{14b}': 112,
  '\u{273}': 113,
  '\u{272}': 114,
  '\u{274}': 115,
  '\u{f8}': 116,
  '\u{278}': 118,
  '\u{3b8}': 119,
  '\u{153}': 120,
  '\u{279}': 123,
  '\u{27e}': 125,
  '\u{27b}': 126,
  '\u{281}': 128,
  '\u{27d}': 129,
  '\u{282}': 130,
  '\u{283}': 131,
  '\u{288}': 132,
  '\u{2a7}': 133,
  '\u{28a}': 135,
  '\u{28b}': 136,
  '\u{28c}': 138,
  '\u{263}': 139,
  '\u{264}': 140,
  '\u{3c7}': 142,
  '\u{28e}': 143,
  '\u{292}': 147,
  '\u{294}': 148,
  '\u{2c8}': 156,
  '\u{2cc}': 157,
  '\u{2d0}': 158,
  '\u{2b0}': 162,
  '\u{2b2}': 164,
  '\u{2193}': 169,
  '\u{2192}': 171,
  '\u{2197}': 172,
  '\u{2198}': 173,
  '\u{1d7b}': 177,
};
