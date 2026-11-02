import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:archive/archive_io.dart';
import 'package:path/path.dart' as p;

import '../models/media_item.dart';
import 'text_document.dart' show decodeText;

/// 압축 파일(zip/cbz) 안의 파일 하나
class ZipEntry {
  final String name;
  final int size;
  final bool isImage;
  const ZipEntry(this.name, this.size, this.isImage);
  String get base => p.posix.basename(name);
  int get depth => '/'.allMatches(name).length;
}

/// 다시 쓸 때 한 줄: 원래 이름 → 새 이름 (data 가 있으면 새 내용)
class ZipPlan {
  final String? src;
  final String dst;
  final Uint8List? data;
  const ZipPlan(this.src, this.dst, {this.data});
}

/// 이름 붙이는 방식
enum NamePattern { pad3, pad2, pad4, keep }

String patternLabel(NamePattern n) => switch (n) {
      NamePattern.pad3 => '기본 숫자 패딩 (000, 001…)',
      NamePattern.pad2 => '두 자리 (00, 01…)',
      NamePattern.pad4 => '네 자리 (0000, 0001…)',
      NamePattern.keep => '원래 이름 유지',
    };

class ArchiveTools {
  /// macOS/Windows 가 넣는 쓰레기 파일
  static bool isJunk(String name) {
    final b = p.posix.basename(name).toLowerCase();
    return name.startsWith('__MACOSX/') || b == '.ds_store' || b == 'thumbs.db' || b == 'desktop.ini' || b.startsWith('._');
  }

  static int natural(String a, String b) {
    final re = RegExp(r'(\d+)|(\D+)');
    final ma = re.allMatches(a.toLowerCase()).toList();
    final mb = re.allMatches(b.toLowerCase()).toList();
    for (var i = 0; i < ma.length && i < mb.length; i++) {
      final x = ma[i].group(0)!, y = mb[i].group(0)!;
      final nx = int.tryParse(x), ny = int.tryParse(y);
      final c = (nx != null && ny != null) ? nx.compareTo(ny) : x.compareTo(y);
      if (c != 0) return c;
    }
    return ma.length.compareTo(mb.length);
  }

  /// 압축 파일 안 목록 (이미지는 자연 정렬 순)
  static Future<List<ZipEntry>> list(String path) => Isolate.run(() {
        final input = InputFileStream(path);
        try {
          final zip = ZipDecoder().decodeStream(input);
          return zip.files
              .where((f) => f.isFile)
              .map((f) => ZipEntry(f.name, f.size, imageExts.contains(p.extension(f.name).toLowerCase())))
              .toList()
            ..sort((a, b) => natural(a.name, b.name));
        } finally {
          input.closeSync();
        }
      });

  static Future<Uint8List?> readEntry(String path, String name) => Isolate.run(() {
        final input = InputFileStream(path);
        try {
          return ZipDecoder().decodeStream(input).findFile(name)?.content;
        } finally {
          input.closeSync();
        }
      });

  /// 새 이름 만들기
  static String newName(NamePattern pat, int index, String original) {
    final ext = p.extension(original).toLowerCase();
    return switch (pat) {
      NamePattern.pad2 => '${index.toString().padLeft(2, '0')}$ext',
      NamePattern.pad3 => '${index.toString().padLeft(3, '0')}$ext',
      NamePattern.pad4 => '${index.toString().padLeft(4, '0')}$ext',
      NamePattern.keep => p.posix.basename(original),
    };
  }

  /// 평탄화 계획: 폴더 구조를 없애고 이미지만 맨 위에 (쓰레기 파일 제거)
  static List<ZipPlan> flattenPlan(List<ZipEntry> entries, {NamePattern pattern = NamePattern.keep, int start = 0}) {
    final images = entries.where((e) => e.isImage && !isJunk(e.name)).toList();
    final used = <String>{};
    final out = <ZipPlan>[];
    for (var i = 0; i < images.length; i++) {
      var name = newName(pattern, start + i, images[i].name);
      // 다른 폴더에 같은 이름이 있으면 번호를 붙여 겹치지 않게
      var n = 2;
      while (!used.add(name.toLowerCase())) {
        name = '${p.posix.basenameWithoutExtension(name)}_$n${p.posix.extension(name)}';
        n++;
      }
      out.add(ZipPlan(images[i].name, name));
    }
    return out;
  }

  /// 계획대로 압축 파일을 다시 쓴다. [backup] 이면 원본을 .bak 으로 남긴다.
  static Future<void> rewrite(String path, List<ZipPlan> plan, {bool backup = true}) async {
    final tmp = '$path.tmp';
    await Isolate.run(() {
      final input = InputFileStream(path);
      final enc = ZipFileEncoder()..create(tmp, level: 0); // 이미지는 이미 압축돼 있어 저장만
      try {
        final zip = ZipDecoder().decodeStream(input);
        for (final pl in plan) {
          final data = pl.data ?? (pl.src == null ? null : zip.findFile(pl.src!)?.content);
          if (data == null) continue;
          enc.addArchiveFile(ArchiveFile.noCompress(pl.dst, data.length, data));
        }
      } finally {
        enc.closeSync();
        input.closeSync();
      }
    });
    final orig = File(path);
    if (backup) {
      var bak = '$path.bak';
      var n = 2;
      while (await File(bak).exists()) {
        bak = '$path.$n.bak';
        n++;
      }
      await orig.rename(bak);
    } else {
      await orig.delete();
    }
    await File(tmp).rename(path);
  }

  // ---------------- TXT 정리 ----------------

  /// 텍본 정리: UTF-8 로 바꾸고, 줄 끝 공백 제거, 빈 줄 3개 이상 → 2개, 줄바꿈 통일
  static Future<(String encoding, int before, int after)> cleanTxt(String path, {bool backup = true, bool collapseBlank = true}) async {
    final bytes = await File(path).readAsBytes();
    final (text, enc) = decodeText(bytes);
    var t = text.replaceAll('\r\n', '\n').replaceAll('\r', '\n');
    t = t.split('\n').map((l) => l.trimRight()).join('\n');
    if (collapseBlank) t = t.replaceAll(RegExp(r'\n{4,}'), '\n\n\n');
    t = t.trim();
    final out = utf8.encode('$t\n');
    if (backup) await File(path).copy('$path.bak');
    await File(path).writeAsBytes(out);
    return (enc, bytes.length, out.length);
  }
}
