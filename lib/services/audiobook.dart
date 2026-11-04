import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import 'kokoro_tts.dart';
import 'natural_tts.dart';
import 'tts_service.dart';

/// 오디오북 한 부분 (보통 한 장)
class AudiobookPart {
  final String title;
  final List<String> paragraphs;
  final List<int> blocks; // 문단마다 책 속 블록 번호 (주고받는 대사 추론용, 없으면 빈 목록)
  AudiobookPart(this.title, this.paragraphs, [this.blocks = const []]);
  int get chars => paragraphs.fold(0, (a, b) => a + b.length);
}

/// 만드는 중 상태
class AudiobookProgress {
  final int part, parts; // 지금 몇 번째 부분 (0부터) / 모두
  final String title;
  final int doneChars, totalChars;
  final Duration elapsed;
  final Duration made; // 지금까지 만든 소리 길이
  const AudiobookProgress(this.part, this.parts, this.title, this.doneChars, this.totalChars, this.elapsed, this.made);
  double get fraction => totalChars == 0 ? 0 : doneChars / totalChars;

  /// 남은 시간 어림 (처음 조금은 모름)
  Duration? get eta {
    if (doneChars < 200 || elapsed.inSeconds < 5) return null;
    final per = elapsed.inMilliseconds / doneChars;
    return Duration(milliseconds: (per * (totalChars - doneChars)).round());
  }
}

/// 다 만든 결과
class AudiobookResult {
  final List<String> files;
  final Duration length;
  final int skippedParts; // 이미 있어서 건너뛴 부분
  final int failedPieces; // 소리로 못 바꾼 조각
  final bool compressed; // M4A 로 줄였는가 (못 줄이면 WAV 그대로)
  final bool cancelled;
  final String? playlist;
  const AudiobookResult(this.files, this.length, this.skippedParts, this.failedPieces, this.compressed, this.cancelled, this.playlist);
}

/// 글 한 조각을 WAV 파일로 (기기 안 AI 음성 · 기기 음성 모두)
typedef AudioRenderer = Future<String?> Function(String text, String voice, int rate);

/// 소설을 장마다 소리 파일로 만든다 (오프라인)
///
/// 조각마다 지금 고른 음성(대사 · 속마음 · 인물별)으로 WAV 를 만들고, 24kHz 모노 16비트로 맞춰 이어 붙인다.
/// 다 붙이면 기기 내장 인코더로 M4A(AAC) 로 줄인다 (Windows Media Foundation · Android MediaCodec · Apple AVFoundation).
/// 이미 만든 장은 건너뛰므로 중간에 멈춰도 이어서 만들 수 있다.
class AudiobookMaker {
  AudiobookMaker({AudioRenderer? render}) : _render = render ?? AudioRender.toWav;

  static const sampleRate = 24000;
  final AudioRenderer _render;
  bool _cancel = false;
  void cancel() => _cancel = true;
  bool get cancelled => _cancel;

  /// 파일 이름에 못 쓰는 글자 빼기
  static String safeName(String s) {
    final t = s.replaceAll(RegExp(r'[\\/:*?"<>|\x00-\x1F]'), ' ').replaceAll(RegExp(r'\s+'), ' ').trim();
    final cut = t.length > 60 ? t.substring(0, 60).trim() : t;
    return cut.replaceAll(RegExp(r'[. ]+$'), '');
  }

  static String partBase(int i, String title) {
    final name = safeName(title);
    return '${(i + 1).toString().padLeft(3, '0')}${name.isEmpty ? '' : ' $name'}';
  }

  Future<AudiobookResult> make({
    required List<AudiobookPart> parts,
    required String outDir,
    required List<(String, String, int)> Function(String paragraph, int block) plan,
    String bookTitle = '',
    bool compress = true,
    bool single = false, // 다 만든 뒤 책 한 파일로 합친다 (장 파일은 WAV 로 만들었다가 지움)
    void Function(AudiobookProgress)? onProgress,
  }) async {
    final wantM4a = compress;
    if (single) compress = false;
    await Directory(outDir).create(recursive: true);
    final total = parts.fold(0, (a, b) => a + b.chars);
    final sw = Stopwatch()..start();
    final files = <String>[];
    final lengths = <String, Duration>{};
    var done = 0, skipped = 0, failed = 0, samplesAll = 0;
    var compressedAll = compress;
    var fails = 0; // 잇달아 실패한 수 (너무 많으면 그만)
    void report(int i, {int extra = 0}) => onProgress?.call(AudiobookProgress(i, parts.length, parts[i].title, done + extra, total,
        sw.elapsed, Duration(milliseconds: samplesAll * 1000 ~/ sampleRate)));

    try {
      for (var i = 0; i < parts.length && !_cancel; i++) {
        final part = parts[i];
        final base = p.join(outDir, partBase(i, part.title));
        // 이미 만든 장 (이어 만들기)
        final had = [for (final e in single ? ['.wav'] : ['.m4a', '.wav']) File('$base$e')]
            .where((f) => f.existsSync() && f.lengthSync() > 1024)
            .firstOrNull;
        if (part.paragraphs.isEmpty) {
          // 범위 밖 자리 (번호를 맞추려고 둔 것): 이미 만든 파일만 목록에 넣는다
          if (had != null) files.add(had.path);
          continue;
        }
        if (had != null) {
          files.add(had.path);
          skipped++;
          done += part.chars;
          report(i);
          continue;
        }
        report(i);
        final tmp = File('$base.wav.part');
        final raf = await tmp.open(mode: FileMode.write);
        var samples = 0;
        try {
          await raf.writeFrom(NaturalTts.wavBytes(Float32List(0), sampleRate)); // 머리 (길이는 끝에 채움)
          var inPart = 0;
          for (var q = 0; q < part.paragraphs.length; q++) {
            final para = part.paragraphs[q];
            if (_cancel) break;
            for (final (text, voice, rate) in plan(para, q < part.blocks.length ? part.blocks[q] : -1)) {
              if (_cancel) break;
              if (text.trim().isEmpty) continue;
              Int16List? pcm;
              for (var tryNo = 0; tryNo < 2 && pcm == null && !_cancel; tryNo++) {
                String? wav;
                try {
                  wav = await _render(text.trim(), voice, rate);
                  if (wav != null) {
                    final got = pcmFromWav(await File(wav).readAsBytes(), sampleRate);
                    if (got != null && got.length >= sampleRate ~/ 20) pcm = got;
                  }
                } catch (_) {
                } finally {
                  if (wav != null) File(wav).delete().ignore();
                }
              }
              if (_cancel) break;
              // 소리가 없는 파일(그 음성이 읽지 못하는 언어 등)도 실패로 본다
              if (pcm == null || pcm.length < sampleRate ~/ 20) {
                failed++;
                if (++fails >= 12) throw const AudiobookError('음성을 만들지 못했습니다. 다른 음성을 골라 보세요.');
                continue;
              }
              fails = 0;
              await raf.writeFrom(pcm.buffer.asUint8List(pcm.offsetInBytes, pcm.lengthInBytes));
              samples += pcm.length;
              // 조각 사이 짧은 쉼
              final gap = Int16List(sampleRate * 12 ~/ 100);
              await raf.writeFrom(gap.buffer.asUint8List());
              samples += gap.length;
            }
            // 문단 사이 쉼
            final gap = Int16List(sampleRate * 35 ~/ 100);
            await raf.writeFrom(gap.buffer.asUint8List());
            samples += gap.length;
            inPart += para.length;
            report(i, extra: inPart);
          }
          // 머리에 길이 채우기
          final bytes = samples * 2;
          await raf.setPosition(4);
          await raf.writeFrom(_u32(36 + bytes));
          await raf.setPosition(40);
          await raf.writeFrom(_u32(bytes));
        } finally {
          await raf.close();
        }
        if (_cancel) {
          await tmp.delete().catchError((_) => tmp);
          break;
        }
        done += part.chars;
        samplesAll += samples;
        final wav = await tmp.rename('$base.wav');
        var outPath = wav.path;
        if (compress) {
          final m4a = '$base.m4a';
          if (await AudioRender.encodeM4a(wav.path, m4a)) {
            await wav.delete().catchError((_) => wav);
            outPath = m4a;
          } else {
            compressedAll = false;
            await File(m4a).delete().catchError((_) => File(m4a));
          }
        }
        files.add(outPath);
        lengths[outPath] = Duration(milliseconds: samples * 1000 ~/ sampleRate);
        report(i);
      }
    } finally {
      await AudioRender.closeWorkers();
    }

    if (single && !_cancel && files.isNotEmpty) {
      // 장 WAV 들을 차례대로 이어 책 한 파일로
      final name = safeName(bookTitle).isEmpty ? '오디오북' : safeName(bookTitle);
      final whole = p.join(outDir, '$name.wav');
      final out = await File(whole).open(mode: FileMode.write);
      var bytes = 0;
      try {
        await out.writeFrom(NaturalTts.wavBytes(Float32List(0), sampleRate));
        for (final f in files) {
          final raf = await File(f).open();
          try {
            await raf.setPosition(44);
            while (true) {
              final chunk = await raf.read(1 << 20);
              if (chunk.isEmpty) break;
              await out.writeFrom(chunk);
              bytes += chunk.length;
            }
          } finally {
            await raf.close();
          }
        }
        await out.setPosition(4);
        await out.writeFrom(_u32(36 + bytes));
        await out.setPosition(40);
        await out.writeFrom(_u32(bytes));
      } finally {
        await out.close();
      }
      var result = whole;
      var ok = true;
      if (wantM4a) {
        final m4a = p.join(outDir, '$name.m4a');
        ok = await AudioRender.encodeM4a(whole, m4a);
        if (ok) {
          await File(whole).delete();
          result = m4a;
        } else {
          compressedAll = false;
        }
      }
      for (final f in files) {
        await File(f).delete().catchError((_) => File(f));
      }
      return AudiobookResult([result], Duration(milliseconds: bytes ~/ 2 * 1000 ~/ sampleRate), skipped, failed, wantM4a && ok, false, null);
    }

    String? playlist;
    if (files.isNotEmpty) {
      // 차례대로 듣기 목록 (대부분의 음악 앱 · VLC 에서 열림)
      final name = safeName(bookTitle).isEmpty ? '목록' : safeName(bookTitle);
      playlist = p.join(outDir, '$name.m3u8');
      final sb = StringBuffer('#EXTM3U\n');
      for (final f in files) {
        final len = lengths[f];
        sb.writeln('#EXTINF:${len?.inSeconds ?? -1},${p.basenameWithoutExtension(f)}');
        sb.writeln(p.basename(f));
      }
      try {
        await File(playlist).writeAsString(sb.toString());
      } catch (_) {
        playlist = null; // 목록 파일을 못 쓰는 곳 (안드로이드 공용 폴더 등)
      }
    }
    return AudiobookResult(files, Duration(milliseconds: samplesAll * 1000 ~/ sampleRate), skipped, failed,
        compress && compressedAll, _cancel, playlist);
  }

  static Uint8List _u32(int v) => (ByteData(4)..setUint32(0, v, Endian.little)).buffer.asUint8List();
}

class AudiobookError implements Exception {
  final String message;
  const AudiobookError(this.message);
  @override
  String toString() => message;
}

/// WAV(어떤 꼴이든) → 모노 16비트 [rate]Hz 표본. 못 읽으면 null
///
/// 8/16/24/32비트 정수, 32비트 실수, 여러 채널, 'fmt '·'data' 앞뒤의 다른 덩어리(LIST, FLLR 등)를 모두 받아들인다.
Int16List? pcmFromWav(Uint8List b, int rate) {
  if (b.length < 44) return null;
  final bd = ByteData.sublistView(b);
  String tag(int o) => String.fromCharCodes(b, o, o + 4);
  if (tag(0) != 'RIFF' || tag(8) != 'WAVE') return null;
  int? format, ch, sr, bits, dataAt, dataLen;
  var pos = 12;
  while (pos + 8 <= b.length) {
    final id = tag(pos);
    var len = bd.getUint32(pos + 4, Endian.little);
    final body = pos + 8;
    if (id == 'fmt ' && body + 16 <= b.length) {
      format = bd.getUint16(body, Endian.little);
      ch = bd.getUint16(body + 2, Endian.little);
      sr = bd.getUint32(body + 4, Endian.little);
      bits = bd.getUint16(body + 14, Endian.little);
      if (format == 0xFFFE && len >= 26 && body + 26 <= b.length) format = bd.getUint16(body + 24, Endian.little);
    } else if (id == 'data') {
      // 길이를 안 적은 파일(만드는 중 멈춘 것 등)은 끝까지
      if (len == 0 || len == 0xFFFFFFFF || body + len > b.length) len = b.length - body;
      dataAt = body;
      dataLen = len;
      break;
    }
    pos = body + len + (len & 1);
  }
  if (format == null || ch == null || sr == null || bits == null || dataAt == null || dataLen == null) return null;
  if (ch < 1 || sr < 1000 || (format != 1 && format != 3)) return null;
  final bytesPer = bits ~/ 8;
  if (bytesPer < 1) return null;
  final frames = dataLen ~/ (bytesPer * ch);
  if (frames == 0) return Int16List(0);

  double sampleAt(int o) {
    switch ((format, bits)) {
      case (1, 8):
        return (bd.getUint8(o) - 128) / 128.0;
      case (1, 16):
        return bd.getInt16(o, Endian.little) / 32768.0;
      case (1, 24):
        final v = bd.getUint8(o) | bd.getUint8(o + 1) << 8 | bd.getInt8(o + 2) << 16;
        return v / 8388608.0;
      case (1, 32):
        return bd.getInt32(o, Endian.little) / 2147483648.0;
      case (3, 32):
        return bd.getFloat32(o, Endian.little);
      case (3, 64):
        return bd.getFloat64(o, Endian.little);
      default:
        return 0;
    }
  }

  // 채널 평균 → 모노
  final mono = Float32List(frames);
  final step = bytesPer * ch;
  for (var f = 0; f < frames; f++) {
    var s = 0.0;
    final o = dataAt + f * step;
    for (var c = 0; c < ch; c++) {
      s += sampleAt(o + c * bytesPer);
    }
    mono[f] = s / ch;
  }
  // 표본률 맞추기 (선형 보간 · 내릴 때는 구간 평균으로 거친 소리 줄임)
  final outLen = (frames * rate / sr).floor();
  final out = Int16List(outLen);
  final ratio = sr / rate;
  for (var i = 0; i < outLen; i++) {
    double v;
    if (ratio > 1.5) {
      final a = (i * ratio).floor(), z = ((i + 1) * ratio).floor().clamp(a + 1, frames);
      var s = 0.0;
      for (var k = a; k < z; k++) {
        s += mono[k];
      }
      v = s / (z - a);
    } else {
      final x = i * ratio;
      final a = x.floor();
      final t = x - a;
      final y0 = mono[a.clamp(0, frames - 1)], y1 = mono[(a + 1).clamp(0, frames - 1)];
      v = y0 + (y1 - y0) * t;
    }
    out[i] = (v.clamp(-1.0, 1.0) * 32767).round();
  }
  return out;
}

/// 글 → 소리 파일, 소리 파일 → M4A (플랫폼마다)
class AudioRender {
  AudioRender._();
  static const _tts = MethodChannel('mediashelf/tts');
  static const _audio = MethodChannel('mediashelf/audio');
  static _WinVoices? _win;

  static bool _isModel(String v) => NaturalTts.isNatural(v) || KokoroTts.isKokoro(v);

  static Future<String> _tmp(String ext) async {
    final t = await getTemporaryDirectory();
    await t.create(recursive: true);
    return p.join(t.path, 'arari_book_${DateTime.now().microsecondsSinceEpoch}$ext');
  }

  /// 글 한 조각을 WAV 로. 실패하면 null
  static Future<String?> toWav(String text, String voice, int rate) async {
    final t = TtsService.normalize(text.trim());
    if (t.isEmpty) return null;
    if (_isModel(voice)) return TtsService.renderModel(t, voice, rate);
    if (Platform.isWindows) return (_win ??= _WinVoices()).render(t, voice, rate, await _tmp('.wav'));
    if (Platform.isMacOS) {
      final out = await _tmp('.wav');
      final txt = await _tmp('.txt');
      await File(txt).writeAsString(t);
      try {
        final r = await Process.run('say', [
          if (voice.isNotEmpty) ...['-v', voice],
          '-r',
          '${(180 + rate * 15).clamp(80, 400)}',
          '-o',
          out,
          '--file-format=WAVE',
          '--data-format=LEI16@24000',
          '-f',
          txt,
        ]);
        return r.exitCode == 0 && File(out).existsSync() ? out : null;
      } finally {
        File(txt).delete().ignore();
      }
    }
    if (Platform.isAndroid || Platform.isIOS) {
      final name = voice.contains(':') ? voice.substring(voice.indexOf(':') + 1).split('|').first : '';
      var parts = t.length > 3500 ? chunkText(t, maxLen: 3500) : [t];
      if (parts.length == 1) {
        final out = await _tmp('.wav');
        final ok = await _tts
            .invokeMethod<bool>('render', {'text': parts.first, 'voice': name, 'rate': (1 + rate.clamp(-10, 10) * 0.1).clamp(0.3, 3.0), 'path': out})
            .timeout(Duration(seconds: 60 + t.length ~/ 3), onTimeout: () => false);
        return ok == true && File(out).existsSync() ? out : null;
      }
      // 아주 긴 조각: 나눠 만든 뒤 붙인다
      final pcm = <int>[];
      for (final part in parts) {
        final w = await toWav(part, voice, rate);
        if (w == null) return null;
        final s = pcmFromWav(await File(w).readAsBytes(), AudiobookMaker.sampleRate);
        File(w).delete().ignore();
        if (s == null) return null;
        pcm.addAll(s);
      }
      final out = await _tmp('.wav');
      final f = Float32List.fromList([for (final v in pcm) v / 32768.0]);
      await File(out).writeAsBytes(NaturalTts.wavBytes(f, AudiobookMaker.sampleRate));
      return out;
    }
    return null;
  }

  /// WAV → M4A(AAC). 못 하면 false (WAV 를 그대로 둔다)
  static Future<bool> encodeM4a(String wav, String m4a) async {
    try {
      if (Platform.isWindows) {
        final ps = File(p.join(Directory.systemTemp.path, 'arari_m4a_v1.ps1'));
        // Windows PowerShell 5.1 은 BOM 이 있어야 UTF-8 로 읽는다
        await ps.writeAsBytes([0xEF, 0xBB, 0xBF, ...utf8.encode(_winEncode)]);
        final r = await Process.run('powershell',
                ['-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', ps.path, '-src', wav, '-dir', p.dirname(m4a), '-name', p.basename(m4a)])
            .timeout(const Duration(minutes: 30));
        lastEncodeLog = '${r.stdout}\n${r.stderr}'.trim();
        return r.exitCode == 0 && File(m4a).existsSync() && File(m4a).lengthSync() > 0;
      }
      if (Platform.isAndroid || Platform.isIOS || Platform.isMacOS) {
        final ok = await _audio.invokeMethod<bool>('encodeM4a', {'src': wav, 'dst': m4a}).timeout(const Duration(minutes: 30));
        return ok == true && File(m4a).existsSync() && File(m4a).lengthSync() > 0;
      }
    } catch (_) {}
    return false;
  }

  static Future<void> closeWorkers() async {
    final w = _win;
    _win = null;
    await w?.close();
  }

  /// Windows: Media Foundation(MediaTranscoder) 로 AAC 인코딩. 인수: 원본 WAV, 저장 폴더, 파일 이름
  static String lastEncodeLog = '';
  static String lastRenderLog = '';
  static const _winEncode = r'''
param([string]$src, [string]$dir, [string]$name)
$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Runtime.WindowsRuntime
$ms = [System.WindowsRuntimeSystemExtensions].GetMethods()
$asOp = ($ms | Where-Object { $_.Name -eq 'AsTask' -and $_.GetParameters().Count -eq 1 -and $_.GetParameters()[0].ParameterType.Name -eq 'IAsyncOperation`1' })[0]
$asAct = ($ms | Where-Object { $_.Name -eq 'AsTask' -and $_.GetParameters().Count -eq 1 -and $_.GetParameters()[0].ParameterType.Name -eq 'IAsyncActionWithProgress`1' })[0]
function Await($op, $type) { $t = $asOp.MakeGenericMethod($type).Invoke($null, @($op)); $t.Wait(-1) | Out-Null; $t.Result }
[Windows.Storage.StorageFile, Windows.Storage, ContentType = WindowsRuntime] | Out-Null
[Windows.Storage.StorageFolder, Windows.Storage, ContentType = WindowsRuntime] | Out-Null
[Windows.Media.Transcoding.MediaTranscoder, Windows.Media.Transcoding, ContentType = WindowsRuntime] | Out-Null
[Windows.Media.MediaProperties.MediaEncodingProfile, Windows.Media.MediaProperties, ContentType = WindowsRuntime] | Out-Null
$in = Await ([Windows.Storage.StorageFile]::GetFileFromPathAsync($src)) ([Windows.Storage.StorageFile])
$folder = Await ([Windows.Storage.StorageFolder]::GetFolderFromPathAsync($dir)) ([Windows.Storage.StorageFolder])
$out = Await ($folder.CreateFileAsync($name, [Windows.Storage.CreationCollisionOption]::ReplaceExisting)) ([Windows.Storage.StorageFile])
$profile = [Windows.Media.MediaProperties.MediaEncodingProfile]::CreateM4a([Windows.Media.MediaProperties.AudioEncodingQuality]::Low)
try { $profile.Audio.ChannelCount = 1; $profile.Audio.SampleRate = 44100; $profile.Audio.Bitrate = 96000 } catch {}
$tr = New-Object Windows.Media.Transcoding.MediaTranscoder
$prep = Await ($tr.PrepareFileTranscodeAsync($in, $out, $profile)) ([Windows.Media.Transcoding.PrepareTranscodeResult])
if (-not $prep.CanTranscode) { Write-Output ('##FAIL ' + $prep.FailureReason); exit 2 }
$t = $asAct.MakeGenericMethod([double]).Invoke($null, @($prep.TranscodeAsync()))
$t.Wait(-1) | Out-Null
Write-Output '##OK'
exit 0
''';
}

/// Windows 기기 음성(System.Speech) 을 파일로: PowerShell 하나를 띄워 두고 줄마다 일을 준다 (조각마다 새로 띄우면 느림)
class _WinVoices {
  Process? _proc;
  final _lines = <String>[];
  Completer<void>? _wake;
  Future<void> _queue = Future.value();

  static const _script = r'''
[Console]::InputEncoding=[Text.Encoding]::UTF8; [Console]::OutputEncoding=[Text.Encoding]::UTF8
Add-Type -AssemblyName System.Speech
$s = New-Object System.Speech.Synthesis.SpeechSynthesizer
$def = $s.Voice.Name
$fmt = New-Object System.Speech.AudioFormat.SpeechAudioFormatInfo(24000, [System.Speech.AudioFormat.AudioBitsPerSample]::Sixteen, [System.Speech.AudioFormat.AudioChannel]::Mono)
while (($l = [Console]::In.ReadLine()) -ne $null) {
  try {
    $j = $l | ConvertFrom-Json
    $v = [string]$j.voice
    if (-not $v) { $v = $def }
    try { $s.SelectVoice($v) } catch {}
    $s.Rate = [int]$j.rate
    $s.SetOutputToWaveFile([string]$j.path, $fmt)
    $s.Speak([string]$j.text)
    $s.SetOutputToNull()
    [Console]::Out.WriteLine('##OK')
  } catch {
    try { $s.SetOutputToNull() } catch {}
    [Console]::Out.WriteLine('##ERR ' + ($_.Exception.Message -replace '\s+', ' '))
  }
  [Console]::Out.Flush()
}
''';

  Future<Process> _start() async {
    if (_proc != null) return _proc!;
    final ps = File(p.join(Directory.systemTemp.path, 'arari_voice_file_v1.ps1'));
    // Windows PowerShell 5.1 은 BOM 이 있어야 UTF-8 로 읽는다
    await ps.writeAsBytes([0xEF, 0xBB, 0xBF, ...utf8.encode(_script)]);
    final pr = await Process.start('powershell', ['-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', ps.path]);
    pr.stdin.encoding = utf8; // 한글 글을 그대로 (기본은 시스템 인코딩이라 깨짐)
    pr.stdout.transform(utf8.decoder).transform(const LineSplitter()).listen((l) {
      if (!l.startsWith('##')) return;
      _lines.add(l);
      _wake?.complete();
      _wake = null;
    }, onDone: () {
      _proc = null;
      _lines.add('##ERR');
      _wake?.complete();
      _wake = null;
    });
    pr.stderr.transform(utf8.decoder).listen((e) => AudioRender.lastRenderLog = (AudioRender.lastRenderLog + e).trim());
    return _proc = pr;
  }

  Future<String?> render(String text, String voice, int rate, String out) {
    final c = Completer<String?>();
    _queue = _queue.then((_) async {
      try {
        final pr = await _start();
        _lines.clear();
        pr.stdin.writeln(jsonEncode({'text': text, 'voice': voice, 'rate': rate.clamp(-10, 10), 'path': out}));
        await pr.stdin.flush();
        final deadline = DateTime.now().add(Duration(seconds: 60 + text.length ~/ 3));
        while (_lines.isEmpty && DateTime.now().isBefore(deadline)) {
          final w = _wake = Completer<void>();
          await w.future.timeout(deadline.difference(DateTime.now()), onTimeout: () {});
        }
        final ok = _lines.isNotEmpty && _lines.first == '##OK';
        if (_lines.isEmpty) {
          // 응답이 없으면 새로 띄운다
          pr.kill();
          _proc = null;
          AudioRender.lastRenderLog = '${AudioRender.lastRenderLog} [worker: no reply]'.trim();
        } else if (!ok) {
          AudioRender.lastRenderLog = '${AudioRender.lastRenderLog} [worker: ${_lines.first}]'.trim();
        }
        if (ok && File(out).existsSync() && File(out).lengthSync() > 100) {
          c.complete(out);
        } else {
          // 띄워 둔 일꾼이 안 되면, 읽어주기와 같은 방식(한 번에 하나)으로 다시
          c.complete(await _once(text, voice, rate, out));
        }
      } catch (_) {
        c.complete(null);
      }
    });
    return c.future;
  }

  /// PowerShell 을 한 번 띄워 한 조각만 (느리지만 확실)
  static Future<String?> _once(String text, String voice, int rate, String out) async {
    final script = StringBuffer()
      ..write(r'[Console]::InputEncoding=[Text.Encoding]::UTF8; Add-Type -AssemblyName System.Speech; ')
      ..write(r'$s=New-Object System.Speech.Synthesis.SpeechSynthesizer; ')
      ..write('\$s.Rate=${rate.clamp(-10, 10)}; ');
    if (voice.isNotEmpty) script.write("try { \$s.SelectVoice('${voice.replaceAll("'", "''")}') } catch {}; ");
    script
      ..write(r'$f=New-Object System.Speech.AudioFormat.SpeechAudioFormatInfo(24000,[System.Speech.AudioFormat.AudioBitsPerSample]::Sixteen,[System.Speech.AudioFormat.AudioChannel]::Mono); ')
      ..write("\$s.SetOutputToWaveFile('${out.replaceAll("'", "''")}', \$f); ")
      ..write(r'$t=[Console]::In.ReadToEnd(); $s.Speak($t); $s.SetOutputToNull(); $s.Dispose()');
    try {
      final pr = await Process.start('powershell', ['-NoProfile', '-Command', script.toString()]);
      pr.stdin.add(utf8.encode(text));
      await pr.stdin.close();
      final err = pr.stderr.transform(utf8.decoder).join();
      pr.stdout.drain<void>();
      final code = await pr.exitCode.timeout(Duration(seconds: 60 + text.length ~/ 3), onTimeout: () {
        pr.kill();
        return -1;
      });
      final e = (await err).trim();
      if (e.isNotEmpty) AudioRender.lastRenderLog = '${AudioRender.lastRenderLog} [once: $e]'.trim();
      return code == 0 && File(out).existsSync() && File(out).lengthSync() > 100 ? out : null;
    } catch (e) {
      AudioRender.lastRenderLog = '${AudioRender.lastRenderLog} [once: $e]'.trim();
      return null;
    }
  }

  Future<void> close() async {
    await _queue;
    final pr = _proc;
    _proc = null;
    if (pr == null) return;
    try {
      await pr.stdin.close();
    } catch (_) {}
    await pr.exitCode.timeout(const Duration(seconds: 5), onTimeout: () {
      pr.kill();
      return -1;
    });
  }
}
