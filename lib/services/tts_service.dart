import 'dart:async';
import 'dart:convert';
import 'dart:io';

/// 소리 내어 읽기 (PC)
/// Windows 에 들어 있는 음성 엔진(System.Speech, 한국어는 "Microsoft Heami")을 PowerShell 로 부른다.
/// 플러그인 없이 동작하고, 문단 하나씩 읽으면서 다음 문단으로 넘어간다.
class TtsService {
  Process? _proc;
  bool _stopped = false;

  static bool get supported => Platform.isWindows || Platform.isMacOS;

  /// 설치된 음성 이름들
  static Future<List<String>> voices() async {
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
