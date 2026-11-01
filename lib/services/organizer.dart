import 'dart:io';

import 'package:path/path.dart' as p;

import '../models/media_item.dart';

/// 정리 규칙에 따라 파일을 라이브러리 폴더로 이동/복사한다.
class Organizer {
  static final _bad = RegExp(r'[<>:"/\\|?*\x00-\x1F]');

  static String _clean(String? s, String fallback) {
    final v = (s ?? '').replaceAll(_bad, '_').trim().replaceAll(RegExp(r'[. ]+$'), '');
    return v.isEmpty ? fallback : (v.length > 120 ? v.substring(0, 120) : v);
  }

  /// 예: pattern `{kind}/{author}/{title}` → `root/책/한강/소년이 온다.epub`
  static String targetPath(String root, String pattern, MediaItem item) {
    final rel = pattern
        .replaceAll('{kind}', kindLabel(item.kind))
        .split('/')
        .map((seg) => seg
            .replaceAll('{author}', _clean(item.author, '작자미상'))
            .replaceAll('{series}', _clean(item.series, '단행본'))
            .replaceAll('{title}', _clean(item.title, p.basenameWithoutExtension(item.path)))
            .replaceAll('{year}', item.year?.toString() ?? '연도미상'))
        .map((seg) => _clean(seg, '_'))
        .toList();
    return p.join(root, p.joinAll(rel)) + item.extension;
  }

  /// 실제로 파일을 옮긴다. 반환: 새 경로
  static Future<String> apply(MediaItem item, String root, String pattern, {required bool move}) async {
    var dest = targetPath(root, pattern, item);
    if (p.equals(dest, item.path)) return dest;
    await Directory(p.dirname(dest)).create(recursive: true);

    // 이름 충돌 시 " (2)" 붙이기
    var n = 2;
    final base = p.withoutExtension(dest), ext = p.extension(dest);
    while (await File(dest).exists()) {
      dest = '$base ($n)$ext';
      n++;
    }

    final src = File(item.path);
    if (!move) {
      await src.copy(dest);
    } else {
      try {
        await src.rename(dest); // 같은 드라이브면 즉시 이동
      } on FileSystemException {
        await src.copy(dest); // 다른 드라이브면 복사 후 삭제
        await src.delete();
      }
    }
    return dest;
  }
}
