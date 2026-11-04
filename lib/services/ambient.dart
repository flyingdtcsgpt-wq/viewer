import 'dart:io';
import 'dart:isolate';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:media_kit/media_kit.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import 'natural_tts.dart';

/// 소리 내어 읽을 때 뒤에 깔리는 배경음 (빗소리 · 파도 · 벽난로 · 잡음)
///
/// 녹음 파일을 넣지 않고 앱이 직접 만든다 (저작권 · 용량 걱정 없음, 30초 소리를 이음새 없이 반복).
/// 진짜 녹음이 좋으면 "내 소리 파일" 로 원하는 음악 · 환경음 파일을 고를 수 있다.
class Ambient {
  Ambient._();

  static const kinds = [
    ('rain', '빗소리'),
    ('waves', '파도'),
    ('fire', '벽난로'),
    ('brown', '갈색 소음 (낮고 부드러움)'),
    ('pink', '분홍 소음'),
    ('white', '백색 소음'),
  ];
  static bool isBuiltIn(String v) => kinds.any((k) => k.$1 == v);
  static String label(String v) {
    if (v.isEmpty) return '끔';
    for (final (k, l) in kinds) {
      if (k == v) return l;
    }
    return p.basename(v);
  }

  static Player? _player;
  static String _playing = '';
  static int _job = 0;

  static Future<String> _fileFor(String kind) async {
    final dir = Directory(p.join((await getApplicationSupportDirectory()).path, 'ambient'));
    await dir.create(recursive: true);
    final f = File(p.join(dir.path, '${kind}_v1.wav'));
    if (!await f.exists() || await f.length() < 1000) {
      final bytes = await Isolate.run(() => makeWav(kind));
      await f.writeAsBytes(bytes);
    }
    return f.path;
  }

  /// [source]: 기본 소리 이름 또는 소리 파일 경로. 빈 값이면 끈다
  static Future<void> start(String source, int volume) async {
    if (source.isEmpty) return stop();
    final job = ++_job;
    final path = isBuiltIn(source) ? await _fileFor(source) : source;
    if (job != _job) return;
    if (!File(path).existsSync()) return;
    final pl = _player ??= Player();
    if (_playing != path) {
      await pl.setPlaylistMode(PlaylistMode.single); // 끝나면 처음부터 (반복)
      await pl.setVolume(0);
      await pl.open(Media(Uri.file(path).toString()));
      _playing = path;
    }
    // 부드럽게 커지기
    for (var i = 1; i <= 10 && job == _job; i++) {
      await pl.setVolume(volume.clamp(0, 100) * i / 10);
      await Future<void>.delayed(const Duration(milliseconds: 80));
    }
  }

  static Future<void> setVolume(int volume) async => _player?.setVolume(volume.clamp(0, 100).toDouble());

  /// 부드럽게 줄이고 멈춘다
  static Future<void> stop() async {
    final job = ++_job;
    final pl = _player;
    if (pl == null || _playing.isEmpty) return;
    final from = pl.state.volume;
    for (var i = 9; i >= 0 && job == _job; i--) {
      await pl.setVolume(from * i / 10);
      await Future<void>.delayed(const Duration(milliseconds: 60));
    }
    if (job != _job) return;
    await pl.stop();
    _playing = '';
  }

  /// 소리 만들기 (22.05kHz 모노 16비트 WAV, 30초, 끝과 처음을 겹쳐 이음새 없게)
  static Uint8List makeWav(String kind) {
    const sr = 22050, seconds = 30, fade = sr; // 1초 겹침
    final n = sr * seconds;
    final x = Float32List(n + fade);
    final rnd = math.Random(kind.hashCode);
    double white() => rnd.nextDouble() * 2 - 1;
    // 분홍 잡음 (Paul Kellet 필터)
    var b0 = 0.0, b1 = 0.0, b2 = 0.0, b3 = 0.0, b4 = 0.0, b5 = 0.0, b6 = 0.0;
    double pink() {
      final w = white();
      b0 = 0.99886 * b0 + w * 0.0555179;
      b1 = 0.99332 * b1 + w * 0.0750759;
      b2 = 0.96900 * b2 + w * 0.1538520;
      b3 = 0.86650 * b3 + w * 0.3104856;
      b4 = 0.55000 * b4 + w * 0.5329522;
      b5 = -0.7616 * b5 - w * 0.0168980;
      final o = b0 + b1 + b2 + b3 + b4 + b5 + b6 + w * 0.5362;
      b6 = w * 0.115926;
      return o * 0.11;
    }

    var brownV = 0.0;
    double brown() {
      brownV = (brownV + white() * 0.02) * 0.998;
      return brownV * 3.5;
    }

    switch (kind) {
      case 'white':
        for (var i = 0; i < x.length; i++) {
          x[i] = white() * 0.3;
        }
      case 'pink':
        for (var i = 0; i < x.length; i++) {
          x[i] = pink();
        }
      case 'brown':
        for (var i = 0; i < x.length; i++) {
          x[i] = brown();
        }
      case 'waves':
        // 낮은 잡음이 8~12초마다 밀려왔다 빠지는 소리
        var phase = 0.0;
        for (var i = 0; i < x.length; i++) {
          final t = i / sr;
          phase += 2 * math.pi * (0.09 + 0.02 * math.sin(2 * math.pi * t / 30)) / sr;
          final swell = math.pow(0.5 + 0.5 * math.sin(phase), 2.2).toDouble();
          x[i] = brown() * (0.25 + 0.75 * swell) + pink() * 0.35 * swell;
        }
      case 'fire':
        // 웅웅거리는 낮은 소리 + 타닥타닥 튀는 소리
        var crack = 0.0, crackDecay = 0.0, lp = 0.0;
        for (var i = 0; i < x.length; i++) {
          if (rnd.nextDouble() < 18 / sr) {
            crack = 0.4 + rnd.nextDouble() * 0.6;
            crackDecay = 0.90 + rnd.nextDouble() * 0.07;
          }
          final c = crack * white();
          crack *= crackDecay;
          lp += (c - lp) * 0.35; // 너무 날카롭지 않게
          x[i] = brown() * 0.55 + lp * 0.9;
        }
      default: // rain
        // 쏴아 하는 빗소리(분홍 잡음에서 낮은 소리를 뺌) + 굵은 빗방울
        var low = 0.0, drop = 0.0, dropDecay = 0.0, dlp = 0.0;
        for (var i = 0; i < x.length; i++) {
          final pk = pink();
          low += (pk - low) * 0.02;
          if (rnd.nextDouble() < 40 / sr) {
            drop = 0.15 + rnd.nextDouble() * 0.45;
            dropDecay = 0.80 + rnd.nextDouble() * 0.15;
          }
          final d = drop * white();
          drop *= dropDecay;
          dlp += (d - dlp) * 0.5;
          x[i] = (pk - low) * 1.6 + low * 0.5 + dlp * 0.6;
        }
    }
    // 끝 1초를 처음 1초와 겹쳐 반복할 때 이음새가 들리지 않게
    final out = Float32List(n);
    for (var i = 0; i < n; i++) {
      out[i] = x[i];
    }
    for (var i = 0; i < fade; i++) {
      final a = i / fade;
      out[i] = x[i] * a + x[n + i] * (1 - a);
    }
    // 크기 맞추기 (가장 큰 소리 0.6)
    var peak = 0.0;
    for (final v in out) {
      if (v.abs() > peak) peak = v.abs();
    }
    if (peak > 0) {
      final g = 0.6 / peak;
      for (var i = 0; i < n; i++) {
        out[i] *= g;
      }
    }
    return NaturalTts.wavBytes(out, sr);
  }
}
