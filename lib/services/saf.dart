import 'dart:io';

import 'package:flutter/services.dart';

/// 사용자가 고른 파일 · 폴더 하나 (안드로이드 Storage Access Framework)
class SafEntry {
  final String uri;
  final String name;
  final int size; // 모르면 -1
  final String rel; // 고른 폴더 기준 상대 폴더 ('' = 바로 아래)
  const SafEntry(this.uri, this.name, this.size, this.rel);

  static SafEntry from(Object? m) {
    final x = (m as Map).cast<String, Object?>();
    return SafEntry('${x['uri']}', '${x['name'] ?? ''}', (x['size'] as num?)?.toInt() ?? -1, '${x['rel'] ?? ''}');
  }
}

/// 안드로이드: 저장소 권한 없이 사용자가 고른 파일 · 폴더만 읽어 앱 폴더로 가져온다 (플레이스토어 정책)
/// 네이티브 쪽은 tool/patch_android.py 가 MainActivity 에 넣는다.
class Saf {
  Saf._();
  static const _ch = MethodChannel('arariflex/saf');

  static bool get supported => Platform.isAndroid;

  static List<SafEntry> _list(Object? r) => r is List ? [for (final m in r) SafEntry.from(m)] : const [];

  /// 파일 여러 개 고르기 (취소하면 빈 목록)
  static Future<List<SafEntry>> pickFiles() async => _list(await _ch.invokeMethod('pickFiles'));

  /// 폴더 고르기 → 폴더 주소 (취소하면 null)
  static Future<String?> pickFolder() => _ch.invokeMethod<String>('pickFolder');

  /// 폴더 아래 모든 파일 (하위 폴더 포함)
  static Future<List<SafEntry>> listTree(String tree) async => _list(await _ch.invokeMethod('listTree', {'tree': tree}));

  /// 파일을 [dest] 경로로 복사 (받는 중엔 .part)
  static Future<bool> copy(String uri, String dest) async => await _ch.invokeMethod<bool>('copy', {'uri': uri, 'dest': dest}) ?? false;

  /// 원본 지우기 (옮기기). 지울 수 없는 곳이면 false
  static Future<bool> delete(String uri) async => await _ch.invokeMethod<bool>('delete', {'uri': uri}) ?? false;

  static Future<void> releaseFolder(String tree) => _ch.invokeMethod('releaseFolder', {'tree': tree});

  // ---------- 폴더 연결: 복사하지 않고 그 자리에서 읽기 ----------

  /// 고른 폴더의 실제 위치와 상태.
  /// path: 기기 저장공간 · SD 카드 · USB 의 경로 (그 밖의 곳 — 클라우드 등 — 이면 null → 연결할 수 없다)
  /// held: 이 폴더를 읽을 권한을 아직 쥐고 있는가, alive: 지금 읽을 수 있는가 (SD 카드를 빼면 false)
  static Future<({String? path, bool held, bool alive})> treeInfo(String tree) async {
    final m = ((await _ch.invokeMethod('treeInfo', {'tree': tree})) as Map?)?.cast<String, Object?>() ?? const {};
    return (path: m['path'] as String?, held: m['held'] == true, alive: m['alive'] == true);
  }

  /// 폴더 아래 모든 파일. ok 가 false 면 다 보지 못한 것이다(읽다 실패 · 너무 많음) → 목록에서 빼는 판단에 쓰면 안 된다
  static Future<({bool ok, List<SafEntry> files})> scanTree(String tree) async {
    final m = ((await _ch.invokeMethod('scanTree', {'tree': tree})) as Map?)?.cast<String, Object?>() ?? const {};
    return (ok: m['ok'] == true, files: _list(m['files']));
  }

  /// 읽기용으로 열어 파일 번호와 크기를 받는다 (닫기는 받은 쪽이 한다 — fd_file.dart closeFd).
  /// [tree] + [rel]: 연결한 폴더 안의 파일. [path]: 보통 파일 (시험용)
  static Future<({int fd, int size})?> openFd({String? tree, String rel = '', String? path}) async {
    final m = ((await _ch.invokeMethod('openFd', {'tree': tree, 'rel': rel, 'path': path})) as Map?)?.cast<String, Object?>();
    final fd = (m?['fd'] as num?)?.toInt() ?? -1;
    return fd < 0 ? null : (fd: fd, size: (m?['size'] as num?)?.toInt() ?? 0);
  }

  /// 연결한 폴더 안 파일의 content:// 주소
  static Future<String?> docUri(String tree, String rel) => _ch.invokeMethod<String>('docUri', {'tree': tree, 'rel': rel});

  /// 연결한 폴더 안의 파일 지우기
  static Future<bool> deleteIn(String tree, String rel) async => await _ch.invokeMethod<bool>('deleteIn', {'tree': tree, 'rel': rel}) ?? false;

  /// "공유 → ARARIFlex" 로 앱이 열렸을 때 받은 파일.
  /// null = 공유로 연 것이 아님, 빈 목록 = 공유이지만 파일이 없음(글자 · 링크만)
  static Future<List<SafEntry>?> takeShared() async {
    final r = await _ch.invokeMethod('takeShared');
    return r == null ? null : _list(r);
  }

  /// 앱이 켜져 있을 때 공유받은 파일
  static void onShared(void Function(List<SafEntry>) f) {
    _ch.setMethodCallHandler((call) async {
      if (call.method == 'shared') f(_list(call.arguments));
    });
  }
}
