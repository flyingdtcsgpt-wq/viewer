import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import 'portable.dart';

/// 예전 이름 때의 데이터 폴더를 지금 자리로 옮긴다 (PC 에서 한 번만).
///
/// 0.6 까지는 앱의 안쪽 이름이 달라서 데이터(서재 DB · 설정 · 표지 · 음성 모델)가 다른 폴더에 있었다.
/// - Windows: `%APPDATA%\com.mediashelf\ARARIFlex` (더 예전은 `…\media_shelf`) → `%APPDATA%\ARARIFlex\ARARIFlex`
/// - macOS: `~/Library/Application Support/com.mediashelf.mediaShelf` → `…/com.arariflex.arariflex`
///
/// 안드로이드 · iOS 는 패키지 이름이 다르면 서로 다른 앱이라 폴더를 건너 옮길 수 없다 → 예전 앱에서 백업, 새 앱에서 복원.
class LegacyData {
  LegacyData._();

  /// main() 에서 설정 · DB 를 열기 전에 부른다. 옮겼으면 예전 폴더 경로를 돌려준다.
  static Future<String?> migrate() async {
    if (Portable.enabled || !(Platform.isWindows || Platform.isMacOS)) return null;
    try {
      final now = await getApplicationSupportDirectory(); // 지금 자리 (없으면 만들어진다)
      final List<String> olds;
      if (Platform.isWindows) {
        final roaming = Platform.environment['APPDATA'];
        if (roaming == null || roaming.isEmpty) return null;
        olds = [p.join(roaming, 'com.mediashelf', 'ARARIFlex'), p.join(roaming, 'com.mediashelf', 'media_shelf')];
      } else {
        olds = [p.join(now.parent.path, 'com.mediashelf.mediaShelf'), p.join(now.parent.path, 'com.mediashelf.media_shelf')];
      }
      return await moveInto(now, olds);
    } catch (e) {
      debugPrint('예전 데이터 옮기기 실패: $e');
      return null;
    }
  }

  /// [olds] 가운데 서재(library.db)가 있는 가장 최근 폴더의 내용을 [now] 로 옮긴다.
  /// [now] 에 이미 서재가 있으면 아무것도 하지 않는다 (새 자리에서 쓰기 시작한 것을 덮어쓰지 않는다).
  @visibleForTesting
  static Future<String?> moveInto(Directory now, List<String> olds) async {
    const db = 'library.db';
    if (await File(p.join(now.path, db)).exists()) return null;
    Directory? from;
    DateTime? newest;
    for (final o in olds) {
      if (p.equals(o, now.path)) continue;
      final f = File(p.join(o, db));
      if (!await f.exists()) continue;
      final t = await f.lastModified();
      if (newest == null || t.isAfter(newest)) {
        newest = t;
        from = Directory(o);
      }
    }
    if (from == null) return null;
    await now.create(recursive: true);
    await for (final e in from.list(followLinks: false)) {
      final to = p.join(now.path, p.basename(e.path));
      // 새 자리에 같은 이름이 벌써 있으면(막 켜며 생긴 빈 설정 파일 등) 예전 것으로 바꾼다
      if (await FileSystemEntity.type(to, followLinks: false) != FileSystemEntityType.notFound) {
        try {
          await (await FileSystemEntity.isDirectory(to) ? Directory(to) : File(to)).delete(recursive: true);
        } catch (_) {
          continue;
        }
      }
      try {
        await e.rename(to); // 같은 드라이브라 바로 끝난다 (큰 음성 모델도)
      } catch (_) {
        await _copy(e, to); // 못 옮기면 복사 (예전 것은 그대로 남는다)
      }
    }
    // 비었으면 예전 폴더를 치운다 (남은 것이 있으면 그대로 둔다)
    try {
      await from.delete();
      await from.parent.delete();
    } catch (_) {}
    return from.path;
  }

  static Future<void> _copy(FileSystemEntity e, String to) async {
    if (e is File) {
      await e.copy(to);
    } else if (e is Directory) {
      await Directory(to).create(recursive: true);
      await for (final c in e.list(followLinks: false)) {
        await _copy(c, p.join(to, p.basename(c.path)));
      }
    }
  }
}
