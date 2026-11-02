import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../models/media_item.dart';
import 'archive_tools.dart';

/// RAR / 7Z / CBR / CB7 읽기
/// Windows 10(1803+)·11 과 macOS 에 들어 있는 tar(bsdtar, libarchive)를 쓴다.
/// (ZIP/CBZ 는 앱 안에서 직접 읽는다)
class ExtArchive {
  static const exts = {'.cbr', '.rar', '.cb7', '.7z'};

  static bool handles(String path) => exts.contains(p.extension(path).toLowerCase());
  static bool get supported => Platform.isWindows || Platform.isMacOS;

  /// 안의 이미지 이름들 (자연 정렬)
  static Future<List<String>> listImages(String path) async {
    final r = await Process.run('tar', ['-tf', path], stdoutEncoding: systemEncoding);
    if (r.exitCode != 0) throw Exception('이 압축 형식을 열 수 없습니다 (tar: ${(r.stderr as String).trim()})');
    return const LineSplitter()
        .convert(r.stdout as String)
        .map((e) => e.trim())
        .where((e) => e.isNotEmpty && imageExts.contains(p.extension(e).toLowerCase()) && !ArchiveTools.isJunk(e))
        .toList()
      ..sort(ArchiveTools.natural);
  }

  /// 파일 하나만 꺼내기 (표지용)
  static Future<Uint8List?> readOne(String path, String name) async {
    final r = await Process.run('tar', ['-xOf', path, name], stdoutEncoding: null);
    if (r.exitCode != 0) return null;
    final out = r.stdout as List<int>;
    return out.isEmpty ? null : Uint8List.fromList(out);
  }

  /// 전체를 임시 폴더에 풀고, 이미지 파일 경로들을 순서대로 돌려준다 (뷰어용)
  static Future<List<String>> extractAll(String path) async {
    final tmp = await getTemporaryDirectory();
    final dir = Directory(p.join(tmp.path, 'mediashelf_extract', sha1.convert(utf8.encode(path)).toString()));
    if (!await dir.exists() || (await dir.list().isEmpty)) {
      await dir.create(recursive: true);
      final r = await Process.run('tar', ['-xf', path, '-C', dir.path]);
      if (r.exitCode != 0) throw Exception('압축을 풀 수 없습니다 (tar: ${(r.stderr as String).trim()})');
    }
    final files = <String>[];
    await for (final e in dir.list(recursive: true)) {
      if (e is File && imageExts.contains(p.extension(e.path).toLowerCase()) && !ArchiveTools.isJunk(e.path)) files.add(e.path);
    }
    files.sort(ArchiveTools.natural);
    return files;
  }

  /// 뷰어를 닫을 때 임시 폴더 정리
  static Future<void> cleanup(String path) async {
    try {
      final tmp = await getTemporaryDirectory();
      final dir = Directory(p.join(tmp.path, 'mediashelf_extract', sha1.convert(utf8.encode(path)).toString()));
      if (await dir.exists()) await dir.delete(recursive: true);
    } catch (_) {}
  }
}
