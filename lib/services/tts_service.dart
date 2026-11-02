import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:media_kit/media_kit.dart';

import 'natural_tts.dart';

/// 소리 내어 읽기 (PC)
/// Windows 에 들어 있는 음성 엔진(System.Speech, 한국어는 "Microsoft Heami")을 PowerShell 로 부른다.
/// 플러그인 없이 동작하고, 문단 하나씩 읽으면서 다음 문단으로 넘어간다.
class TtsService {
  Process? _proc;
  bool _stopped = false;
  int _gen = 0; // 멈추거나 새로 읽을 때마다 바뀜 (이전 읽기는 소리를 내지 않음)
  int _epoch = 0; // 사용자가 멈출 때만 바뀜 (그 전에 부탁한 미리 만들기는 건너뜀)

  /// 마지막 speak 가 false 를 돌려준 이유가 "실패"인지 (멈춤이면 false)
  bool failed = false;
  Player? _player; // 자연 음성 재생용
  Completer<bool>? _playing;
  final Map<String, Future<String>> _ready = {}; // 미리 만들어 둔 자연 음성

  static bool get supported => Platform.isWindows || Platform.isMacOS || Platform.isAndroid || NaturalTts.supported;

  /// 안드로이드 기기 음성 (MainActivity 의 TextToSpeech)
  static const _android = MethodChannel('mediashelf/tts');
  static const _andPrefix = 'and:';

  /// 설치된 음성 이름들 (자연 음성이 있으면 맨 앞에)
  static Future<List<String>> voices() async {
    final natural = await NaturalTts.instance.voices().catchError((_) => <String>[]);
    return [...natural, ...await _systemVoices()];
  }

  /// 목록에 보여 줄 이름
  static String label(String voice) {
    if (NaturalTts.isNatural(voice)) return NaturalTts.label(voice);
    if (voice.startsWith(_andPrefix)) {
      // "and:ko-kr-x-kod-local|ko-KR|local" → "기기 음성 · 한국어 kod"
      final parts = voice.substring(_andPrefix.length).split('|');
      final lang = parts.length > 1 && parts[1].startsWith('ko') ? '한국어' : '영어';
      final name = parts.first.contains('language')
          ? '기본'
          : (parts.first.split('-').where((x) => x.length == 3 && x != 'kor' && x != 'eng').firstOrNull ?? parts.first);
      return '기기 음성 · $lang $name${parts.length > 2 && parts[2] == 'net' ? ' (인터넷)' : ''}';
    }
    return voice;
  }

  static double _speed(int rate) => (1.05 * (1 + rate.clamp(-10, 10) * 0.06)).clamp(0.6, 1.8);
  static String _key(String text, String voice, int rate) => '$voice|$rate|$text';

  /// 다음에 읽을 글을 미리 만들어 둔다 (자연 음성일 때 끊김 줄이기)
  void prefetch(String text, {String? voice, int rate = 0}) {
    if (voice == null || !NaturalTts.isNatural(voice) || text.trim().isEmpty) return;
    final k = _key(text.trim(), voice, rate);
    if (_ready.containsKey(k)) return;
    if (_ready.length > 6) _discard(_ready.remove(_ready.keys.first));
    final epoch = _epoch;
    final f = NaturalTts.instance.synthesize(text.trim(), voice, speed: _speed(rate), wanted: () => epoch == _epoch);
    f.ignore(); // 실패는 실제로 읽을 때 처리
    _ready[k] = f;
  }

  /// 안 쓰게 된 미리 만든 음성 파일 지우기
  static void _discard(Future<String>? f) => f?.then(_deleteLater, onError: (_) {});

  Future<bool> _speakNatural(String t, String voice, int rate, int gen) async {
    final k = _key(t, voice, rate);
    final String wav;
    try {
      wav = await (_ready.remove(k) ?? NaturalTts.instance.synthesize(t, voice, speed: _speed(rate)));
    } catch (_) {
      failed = gen == _gen;
      return false;
    }
    // 만드는 사이에 멈추거나 다른 글을 읽기 시작했으면 버린다
    if (gen != _gen) {
      _deleteLater(wav);
      return false;
    }
    final player = _player ??= Player();
    final done = _playing = Completer<bool>();
    var started = false; // 이전 파일의 늦은 "끝남" 알림을 무시하려고
    final subs = [
      player.stream.playing.listen((p) {
        if (p) started = true;
      }),
      player.stream.completed.listen((c) {
        if (c && started && !done.isCompleted) done.complete(true);
      }),
      player.stream.error.listen((e) {
        if (!done.isCompleted) {
          failed = true;
          done.complete(false);
        }
      }),
    ];
    try {
      // 재생이 끝났다는 알림이 오지 않아도 영원히 멈추지 않게: 소리 길이 + 여유
      final seconds = ((await File(wav).length()) - 44) / 2 / 44100;
      await player.open(Media(Uri.file(wav).toString()));
      return await done.future.timeout(Duration(milliseconds: (seconds * 1000).round() + 5000), onTimeout: () {
        if (!started) failed = true;
        return started;
      });
    } catch (_) {
      failed = true;
      return false;
    } finally {
      for (final x in subs) {
        await x.cancel();
      }
      if (identical(_playing, done)) _playing = null;
      if (gen == _gen) await player.stop(); // 파일을 놓아야 지울 수 있다
      _deleteLater(wav);
    }
  }

  static void _deleteLater(String path) => Future.delayed(const Duration(seconds: 2), () async {
        for (var i = 0; i < 5; i++) {
          try {
            await File(path).delete();
            return;
          } catch (_) {
            await Future<void>.delayed(const Duration(seconds: 3));
          }
        }
      });

  Future<void> dispose() async {
    await stop();
    for (final f in _ready.values) {
      _discard(f);
    }
    _ready.clear();
    await _player?.dispose();
    _player = null;
  }

  static Future<List<String>> _systemVoices() async {
    try {
      if (Platform.isAndroid) {
        final v = await _android.invokeListMethod<String>('voices').timeout(const Duration(seconds: 10), onTimeout: () => null);
        return [for (final x in v ?? const <String>[]) '$_andPrefix$x'];
      }
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
    await _halt();
    _stopped = false;
    failed = false;
    final gen = _gen;
    final t = text.trim();
    if (t.isEmpty) return true;
    if (voice != null && NaturalTts.isNatural(voice)) return _speakNatural(t, voice, rate, gen);
    if (Platform.isAndroid) {
      try {
        final name = voice != null && voice.startsWith(_andPrefix) ? voice.substring(_andPrefix.length).split('|').first : '';
        // 안드로이드 음성 엔진은 한 번에 약 4000자까지
        for (final part in t.length > 3500 ? chunkText(t, maxLen: 3500) : [t]) {
          final ok = await _android
              .invokeMethod<bool>('speak', {'text': part, 'voice': name, 'rate': (1 + rate.clamp(-10, 10) * 0.1).clamp(0.3, 3.0)})
              // 엔진이 끝났다고 알려 주지 않아도 멈추지 않게 (글자 수에 맞춘 넉넉한 시간)
              .timeout(Duration(seconds: 30 + part.length ~/ 3), onTimeout: () => null);
          if (gen != _gen) return false;
          if (ok != true) {
            failed = true;
            return false;
          }
        }
        return true;
      } catch (_) {
        failed = gen == _gen;
        return false;
      }
    }
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
      if (!_stopped && code != 0) failed = true;
      return !_stopped && code == 0;
    } catch (_) {
      _proc = null;
      return false;
    }
  }

  /// 읽기를 멈춘다. 미리 만들던 음성도 버린다
  Future<void> stop() async {
    _epoch++;
    for (final f in _ready.values) {
      _discard(f);
    }
    _ready.clear();
    await _halt();
  }

  /// 지금 소리만 멈춤 (다음 글을 읽기 직전에 부름, 미리 만든 음성은 유지)
  Future<void> _halt() async {
    _stopped = true;
    _gen++;
    final pl = _playing;
    if (pl != null && !pl.isCompleted) pl.complete(false);
    await _player?.stop();
    if (Platform.isAndroid) {
      try {
        await _android.invokeMethod('stop');
      } catch (_) {}
    }
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
