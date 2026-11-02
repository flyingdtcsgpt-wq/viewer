import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:path/path.dart' as p;

import '../models/media_item.dart';
import 'archive_tools.dart';

/// RAR / 7Z / CBR / CB7 읽기 — 압축을 풀지 않고 필요한 쪽만 꺼낸다 (꿀뷰 방식)
/// 1순위: 설치파일에 함께 들어 있는 7-Zip (tools/7zip/7z.exe, LGPL + unRAR 라이선스)
/// 2순위: Windows 10(1803+)/11 · macOS 에 들어 있는 tar(bsdtar)
/// (ZIP/CBZ 는 앱 안에서 직접 읽는다)
class ExtArchive {
  static const exts = {'.cbr', '.rar', '.cb7', '.7z'};

  static bool handles(String path) => exts.contains(p.extension(path).toLowerCase());
  static bool get supported => Platform.isWindows || Platform.isMacOS;

  /// 앱과 함께 설치된 7z.exe
  static String? get sevenZip {
    if (!Platform.isWindows) return null;
    final exe = p.join(p.dirname(Platform.resolvedExecutable), 'tools', '7zip', '7z.exe');
    return File(exe).existsSync() ? exe : null;
  }

  /// 안의 이미지 이름들 (자연 정렬)
  static Future<List<String>> listImages(String path) async {
    final names = <String>[];
    final sz = sevenZip;
    if (sz != null) {
      // -slt: 항목마다 "Path = …" 줄, -sccUTF-8: 한글 파일명 깨짐 방지
      final r = await Process.run(sz, ['l', '-ba', '-slt', '-sccUTF-8', path], stdoutEncoding: utf8);
      if (r.exitCode != 0) throw Exception('압축 파일을 열 수 없습니다 (7-Zip: ${(r.stderr as String).trim()})');
      String? cur;
      var folder = false;
      for (final line in const LineSplitter().convert(r.stdout as String)) {
        if (line.startsWith('Path = ')) {
          if (cur != null && !folder) names.add(cur);
          cur = line.substring(7);
          folder = false;
        } else if (line.startsWith('Folder = +')) {
          folder = true;
        }
      }
      if (cur != null && !folder) names.add(cur);
    } else {
      final r = await Process.run('tar', ['-tf', path], stdoutEncoding: systemEncoding);
      if (r.exitCode != 0) throw Exception('이 압축 형식을 열 수 없습니다 (tar: ${(r.stderr as String).trim()})');
      names.addAll(const LineSplitter().convert(r.stdout as String).map((e) => e.trim()).where((e) => e.isNotEmpty));
    }
    return names.where((e) => imageExts.contains(p.extension(e).toLowerCase()) && !ArchiveTools.isJunk(e.replaceAll('\\', '/'))).toList()
      ..sort(ArchiveTools.natural);
  }

  /// 파일 하나만 꺼내서 메모리로 (디스크에 풀지 않음)
  static Future<Uint8List?> readOne(String path, String name) async {
    final sz = sevenZip;
    final r = sz != null
        ? await Process.run(sz, ['e', '-so', '-spd', '-sccUTF-8', path, name], stdoutEncoding: null)
        : await Process.run('tar', ['-xOf', path, name], stdoutEncoding: null);
    if (r.exitCode != 0) return null;
    final out = r.stdout as List<int>;
    return out.isEmpty ? null : Uint8List.fromList(out);
  }
}

/// 쪽을 그때그때 꺼내 읽는 대기열 (동시에 몇 개만 — 7z 프로세스를 너무 많이 띄우지 않게)
class PageLoader {
  final String path;
  final List<String> names;
  final int parallel;
  final void Function(int index, Uint8List bytes) onLoaded;
  PageLoader(this.path, this.names, this.onLoaded, {this.parallel = 3});

  final _queue = <int>[];
  final _busy = <int>{};
  final _done = <int>{};
  bool _closed = false;

  /// [i] 를 먼저 읽도록 맨 앞에 넣는다
  void want(int i, {bool urgent = false}) {
    if (i < 0 || i >= names.length || _done.contains(i) || _busy.contains(i)) return;
    _queue.remove(i);
    urgent ? _queue.insert(0, i) : _queue.add(i);
    _pump();
  }

  /// 메모리에서 지워진 쪽은 다시 읽을 수 있게
  void forget(int i) => _done.remove(i);

  void _pump() {
    while (!_closed && _busy.length < parallel && _queue.isNotEmpty) {
      final i = _queue.removeAt(0);
      _busy.add(i);
      ExtArchive.readOne(path, names[i]).then((b) {
        _busy.remove(i);
        if (_closed) return;
        if (b != null) {
          _done.add(i);
          onLoaded(i, b);
        }
        _pump();
      });
    }
  }

  void close() {
    _closed = true;
    _queue.clear();
  }
}
