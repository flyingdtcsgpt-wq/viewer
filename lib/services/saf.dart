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
