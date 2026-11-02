import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:media_kit/media_kit.dart';

import 'natural_tts.dart';

/// 소리 내어 읽기 (PC)
/// Windows 에 들어 있는 음성 엔진(System.Speech, 한국어는 "Microsoft Heami")을 PowerShell 로 부른다.
/// 플러그인 없이 동작하고, 문단 하나씩 읽으면서 다음 문단으로 넘어간다.
class TtsService {
  Process? _proc;
  bool _stopped = false;
  Player? _player; // 자연 음성 재생용
  Completer<bool>? _playing;
  final Map<String, Future<String>> _ready = {}; // 미리 만들어 둔 자연 음성

  static bool get supported => Platform.isWindows || Platform.isMacOS || NaturalTts.supported;

  /// 설치된 음성 이름들 (자연 음성이 있으면 맨 앞에)
  static Future<List<String>> voices() async {
    final natural = await NaturalTts.instance.voices().catchError((_) => <String>[]);
    return [...natural, ...await _systemVoices()];
  }

  /// 목록에 보여 줄 이름
  static String label(String voice) => NaturalTts.isNatural(voice) ? NaturalTts.label(voice) : voice;

  static double _speed(int rate) => (1.05 * (1 + rate.clamp(-10, 10) * 0.06)).clamp(0.6, 1.8);
  static String _key(String text, String voice, int rate) => '$voice|$rate|$text';

  /// 다음에 읽을 글을 미리 만들어 둔다 (자연 음성일 때 끊김 줄이기)
  void prefetch(String text, {String? voice, int rate = 0}) {
    if (voice == null || !NaturalTts.isNatural(voice) || text.trim().isEmpty) return;
    final k = _key(text.trim(), voice, rate);
    if (_ready.containsKey(k)) return;
    if (_ready.length > 6) _ready.remove(_ready.keys.first);
    final f = NaturalTts.instance.synthesize(text.trim(), voice, speed: _speed(rate));
    f.ignore(); // 실패는 실제로 읽을 때 처리
    _ready[k] = f;
  }

  Future<bool> _speakNatural(String t, String voice, int rate) async {
    final k = _key(t, voice, rate);
    final String wav;
    try {
      wav = await (_ready.remove(k) ?? NaturalTts.instance.synthesize(t, voice, speed: _speed(rate)));
    } catch (_) {
      return false;
    }
    if (_stopped) {
      _deleteLater(wav);
      return false;
    }
    final player = _player ??= Player();
    final done = _playing = Completer<bool>();
    final sub = player.stream.completed.listen((c) {
      if (c && !done.isCompleted) done.complete(true);
    });
    try {
      await player.open(Media(Uri.file(wav).toString()));
      return await done.future;
    } finally {
      await sub.cancel();
      _playing = null;
      _deleteLater(wav);
    }
  }

  static void _deleteLater(String path) => Future.delayed(const Duration(seconds: 2), () async {
        try {
          await File(path).delete();
        } catch (_) {}
      });

  Future<void> dispose() async {
    await stop();
    await _player?.dispose();
    _player = null;
  }

  static Future<List<String>> _systemVoices() async {
    try {
      if (Platform.isWindows) {
        final r = await Process.run('powershell', [
          '-NoProfile',
          '-Command',
          r'[Console]::OutputEncoding=[Text.Encoding]::UTF8; Add-Type -AssemblyName System.Speech; '
              r'(New-Object System.Speech.Synthesis.SpeechSynthesizer).GetInstalledVoices() | ForEach-Object { $_.VoiceInfo.Name }',
        ], stdoutEncoding: utf8);
        return (r.stdout as String).split(RegExp(r'\r?\n')).map((e) => e.trim()).where((e) => e.isNotEmpty).toList();
      }
      if (Platform.isMacOS) {
        final r = await Process.run('say', ['-v', '?']);
        return (r.stdout as String).split('\n').map((l) => l.split(RegExp(r'\s{2,}')).first.trim()).where((e) => e.isNotEmpty).toList();
      }
    } catch (_) {}
    return [];
  }

  /// 한 덩어리 읽기. 다 읽으면 true, 중간에 멈추면 false
  /// [rate]: -10(느림) ~ 10(빠름), 0 이 보통
  Future<bool> speak(String text, {String? voice, int rate = 0}) async {
    await stop();
    _stopped = false;
    final t = text.trim();
    if (t.isEmpty) return true;
    if (voice != null && NaturalTts.isNatural(voice)) return _speakNatural(t, voice, rate);
    try {
      if (Platform.isWindows) {
        // 글은 표준입력으로 넘긴다 (따옴표·특수문자 걱정 없음)
        final script = StringBuffer()
          ..write(r'[Console]::InputEncoding=[Text.Encoding]::UTF8; Add-Type -AssemblyName System.Speech; ')
          ..write(r'$s=New-Object System.Speech.Synthesis.SpeechSynthesizer; ')
          ..write('\$s.Rate=${rate.clamp(-10, 10)}; ');
        if (voice != null && voice.isNotEmpty) {
          script.write("try { \$s.SelectVoice('${voice.replaceAll("'", "''")}') } catch {}; ");
        }
        script.write(r'$t=[Console]::In.ReadToEnd(); $s.Speak($t)');
        _proc = await Process.start('powershell', ['-NoProfile', '-Command', script.toString()]);
        _proc!.stdin.add(utf8.encode(t));
        await _proc!.stdin.close();
      } else if (Platform.isMacOS) {
        _proc = await Process.start('say', [
          if (voice != null && voice.isNotEmpty) ...['-v', voice],
          '-r',
          '${(180 + rate * 15).clamp(80, 400)}',
          t,
        ]);
      } else {
        return false;
      }
      final code = await _proc!.exitCode;
      _proc = null;
      return !_stopped && code == 0;
    } catch (_) {
      _proc = null;
      return false;
    }
  }

  Future<void> stop() async {
    _stopped = true;
    final pl = _playing;
    if (pl != null && !pl.isCompleted) pl.complete(false);
    await _player?.stop();
    final p = _proc;
    _proc = null;
    if (p != null) {
      p.kill();
      if (Platform.isWindows) {
        // powershell 이 만든 음성 출력도 확실히 끄기
        try {
          await Process.run('taskkill', ['/PID', '${p.pid}', '/T', '/F']);
        } catch (_) {}
      }
    }
  }
}
