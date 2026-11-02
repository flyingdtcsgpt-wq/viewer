import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:image/image.dart' as img;
import 'package:path/path.dart' as p;

/// 그림 속 글자 읽기 (OCR)
///
/// Windows 에 들어 있는 글자 인식(Windows.Media.Ocr)을 PowerShell 로 부른다.
/// 오프라인 · 무료이고 한국어를 지원한다 (Windows 설정의 한국어 언어팩에 들어 있음).
class OcrService {
  OcrService._();

  static bool get supported => Platform.isWindows;

  /// Windows OCR 이 안전하게 다루는 크기 (넘으면 줄이거나 자른다)
  static const _maxSide = 2600;

  static File? _script;

  /// 마지막으로 실제 쓴 인식 언어 ("ko", "en-US" …). 한국어 인식기가 없으면 다른 언어로 대신 읽는다
  static String? usedLang;
  static bool get koreanMissing => usedLang != null && !usedLang!.toLowerCase().startsWith('ko');

  static const _ps = r'''
param([string]$lang, [string]$list)
$ErrorActionPreference = 'Stop'
try { [Console]::OutputEncoding = [Text.Encoding]::UTF8 } catch {}
Add-Type -AssemblyName System.Runtime.WindowsRuntime
$asTaskGeneric = ([System.WindowsRuntimeSystemExtensions].GetMethods() | Where-Object {
  $_.Name -eq 'AsTask' -and $_.GetParameters().Count -eq 1 -and $_.GetParameters()[0].ParameterType.Name -eq 'IAsyncOperation`1' })[0]
function Await($op, $type) {
  $t = $asTaskGeneric.MakeGenericMethod($type).Invoke($null, @($op))
  $t.Wait(-1) | Out-Null
  $t.Result
}
[Windows.Storage.StorageFile, Windows.Storage, ContentType = WindowsRuntime] | Out-Null
[Windows.Media.Ocr.OcrEngine, Windows.Foundation, ContentType = WindowsRuntime] | Out-Null
[Windows.Graphics.Imaging.BitmapDecoder, Windows.Graphics, ContentType = WindowsRuntime] | Out-Null
[Windows.Globalization.Language, Windows.Globalization, ContentType = WindowsRuntime] | Out-Null
if ($lang -eq '?') {
  [Windows.Media.Ocr.OcrEngine]::AvailableRecognizerLanguages | ForEach-Object { Write-Output $_.LanguageTag }
  exit 0
}
$engine = $null
if ($lang) { $engine = [Windows.Media.Ocr.OcrEngine]::TryCreateFromLanguage((New-Object Windows.Globalization.Language($lang))) }
if ($engine -eq $null) { $engine = [Windows.Media.Ocr.OcrEngine]::TryCreateFromUserProfileLanguages() }
if ($engine -eq $null) { Write-Output '##NOENGINE'; exit 2 }
Write-Output ('##LANG ' + $engine.RecognizerLanguage.LanguageTag)
foreach ($path in [IO.File]::ReadAllLines($list, [Text.Encoding]::UTF8)) {
  if (-not $path) { continue }
  Write-Output ('##PAGE ' + $path)
  $stream = $null
  try {
    $file = Await ([Windows.Storage.StorageFile]::GetFileFromPathAsync($path)) ([Windows.Storage.StorageFile])
    $stream = Await ($file.OpenAsync([Windows.Storage.FileAccessMode]::Read)) ([Windows.Storage.Streams.IRandomAccessStream])
    $decoder = Await ([Windows.Graphics.Imaging.BitmapDecoder]::CreateAsync($stream)) ([Windows.Graphics.Imaging.BitmapDecoder])
    $bmp = Await ($decoder.GetSoftwareBitmapAsync()) ([Windows.Graphics.Imaging.SoftwareBitmap])
    $r = Await ($engine.RecognizeAsync($bmp)) ([Windows.Media.Ocr.OcrResult])
    foreach ($l in $r.Lines) { Write-Output $l.Text }
  } catch {
    Write-Output ('##ERROR ' + $_.Exception.Message)
  } finally {
    if ($stream -ne $null) { $stream.Dispose() }
  }
}
''';

  static Future<File> _scriptFile() async {
    if (_script != null && await _script!.exists()) return _script!;
    final f = File(p.join(Directory.systemTemp.path, 'arari_ocr_v2.ps1'));
    // Windows PowerShell 5.1 은 BOM 이 있어야 UTF-8 로 읽는다
    await f.writeAsBytes([0xEF, 0xBB, 0xBF, ...utf8.encode(_ps)]);
    return _script = f;
  }

  /// 쓸 수 있는 인식 언어 ("ko", "en-US" …)
  static Future<List<String>> languages() async {
    if (!supported) return [];
    try {
      final s = await _scriptFile();
      final r = await Process.run('powershell', ['-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', s.path, '-lang', '?', '-list', ''],
          stdoutEncoding: utf8);
      return (r.stdout as String).split(RegExp(r'\r?\n')).map((e) => e.trim()).where((e) => e.isNotEmpty).toList();
    } catch (_) {
      return [];
    }
  }

  /// 그림 파일 여러 개를 한 번에 읽는다 (PowerShell 을 한 번만 띄워 빠르게).
  /// 결과: 파일 경로 → 글. 인식기가 없으면 [OcrUnavailable].
  static Future<Map<String, String>> recognizeFiles(List<String> paths, {String lang = 'ko'}) async {
    if (!supported) throw const OcrUnavailable('이 기기에서는 글자 인식을 쓸 수 없습니다');
    final tmp = await Directory.systemTemp.createTemp('arari_ocr');
    try {
      // 모든 그림을 OCR 이 확실히 다루는 PNG 로: 넓으면 줄이고, 긴 웹툰은 여러 조각으로 자른다
      final prepared = <String, String>{}; // 조각 → 원본
      for (var i = 0; i < paths.length; i++) {
        final src = paths[i];
        final List<Uint8List> tiles;
        try {
          final bytes = await File(src).readAsBytes();
          tiles = await Isolate.run(() => _tiles(bytes));
        } catch (_) {
          continue;
        }
        for (var t = 0; t < tiles.length; t++) {
          final use = p.join(tmp.path, '${i}_$t.png');
          await File(use).writeAsBytes(tiles[t]);
          prepared[use] = src;
        }
      }
      final list = File(p.join(tmp.path, 'list.txt'));
      await list.writeAsString(prepared.keys.join('\r\n'), encoding: utf8);
      final s = await _scriptFile();
      final proc = await Process.start(
        'powershell',
        ['-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', s.path, '-lang', lang, '-list', list.path],
      );
      final outF = proc.stdout.transform(utf8.decoder).join();
      final errF = proc.stderr.transform(utf8.decoder).join();
      // 쪽당 넉넉히 20초, 그래도 안 끝나면 끊는다
      final code = await proc.exitCode.timeout(Duration(seconds: 30 + prepared.length * 20), onTimeout: () {
        proc.kill();
        return -1;
      });
      final r = (exitCode: code, stdout: await outF, stderr: await errF);
      final out = r.stdout;
      final lm = RegExp(r'##LANG (\S+)').firstMatch(out);
      if (lm != null) usedLang = lm.group(1);
      if (out.contains('##NOENGINE')) {
        throw const OcrUnavailable('Windows 글자 인식기가 없습니다. 설정 → 시간 및 언어 → 언어에서 한국어를 추가하세요.');
      }
      final result = <String, String>{};
      String? cur;
      final buf = StringBuffer();
      void flush() {
        if (cur != null) {
          final key = prepared[cur] ?? cur;
          final t = buf.toString().trim();
          result[key] = [if ((result[key] ?? '').isNotEmpty) result[key]!, if (t.isNotEmpty) t].join('\n');
        }
        buf.clear();
      }

      for (final line in out.split(RegExp(r'\r?\n'))) {
        if (line.startsWith('##PAGE ')) {
          flush();
          cur = line.substring(7).trim();
        } else if (line.startsWith('##')) {
          continue;
        } else if (cur != null) {
          buf.writeln(line);
        }
      }
      flush();
      if (result.isEmpty && r.exitCode != 0) {
        throw OcrUnavailable('글자 인식 실패: ${r.stderr.trim().split('\n').first}');
      }
      return result;
    } finally {
      try {
        await tmp.delete(recursive: true);
      } catch (_) {}
    }
  }

  /// 그림 데이터(압축 파일 속 만화 쪽 등) 하나 읽기
  static Future<String> recognizeBytes(Uint8List bytes, {String lang = 'ko'}) async {
    final f = File(p.join(Directory.systemTemp.path, 'arari_ocr_${DateTime.now().microsecondsSinceEpoch}.img'));
    await f.writeAsBytes(bytes);
    try {
      return (await recognizeFiles([f.path], lang: lang)).values.firstOrNull ?? '';
    } finally {
      try {
        await f.delete();
      } catch (_) {}
    }
  }

  static List<Uint8List> _tiles(Uint8List bytes) {
    final im = img.decodeImage(bytes);
    if (im == null) return const [];
    var x = im;
    if (x.width > _maxSide) x = img.copyResize(x, width: _maxSide);
    if (x.height <= _maxSide) return [img.encodePng(x, level: 1)];
    // 조각 경계에 걸린 줄을 놓치지 않게 조금씩 겹쳐 자른다
    const overlap = 80;
    return [
      for (var y = 0; y < x.height; y += _maxSide - overlap)
        if (y == 0 || y + overlap < x.height)
          img.encodePng(img.copyCrop(x, x: 0, y: y, width: x.width, height: (x.height - y).clamp(1, _maxSide)), level: 1),
    ];
  }

  /// OCR 결과를 소리 내어 읽기 좋게: 줄바꿈으로 끊긴 문장을 잇는다
  static String tidy(String raw) {
    final lines = raw.split('\n').map((e) => e.trim()).where((e) => e.isNotEmpty).toList();
    final b = StringBuffer();
    for (final l in lines) {
      if (b.isEmpty) {
        b.write(l);
      } else if (RegExp(r'[.!?。」』"”]$').hasMatch(b.toString())) {
        b.write('\n$l');
      } else {
        b.write(' $l');
      }
    }
    return b.toString();
  }
}

class OcrUnavailable implements Exception {
  final String message;
  const OcrUnavailable(this.message);
  @override
  String toString() => message;
}
