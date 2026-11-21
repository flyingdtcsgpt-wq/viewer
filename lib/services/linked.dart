import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

import 'fd_file.dart';
import 'saf.dart';

/// 연결한 폴더 하나 (플레이스토어판): 사용자가 시스템 폴더 선택 창에서 고른 폴더.
/// 파일을 앱 폴더로 복사하지 않고 그 자리에서 읽는다 → 기기 저장공간이든 SD 카드든 사용자가 정한 곳이 곧 서재.
class LinkedFolder {
  const LinkedFolder({required this.tree, required this.path, this.name = ''});

  /// 시스템이 준 폴더 주소 (content://…/tree/…). 이 주소로만 읽고 지울 수 있다
  final String tree;

  /// 그 폴더의 실제 위치 (/storage/emulated/0/Comics, /storage/1234-5678/만화 …). 목록 · DB 에는 이 경로를 쓴다
  final String path;
  final String name;

  String get label => name.isNotEmpty ? name : p.basename(path);

  /// SD 카드 · USB 처럼 뺄 수 있는 저장소인가
  bool get removable => !path.startsWith('/storage/emulated/');

  Map<String, String> toJson() => {'tree': tree, 'path': path, 'name': name};
  static LinkedFolder fromJson(Map<String, dynamic> j) =>
      LinkedFolder(tree: '${j['tree']}', path: '${j['path']}', name: '${j['name'] ?? ''}');

  static List<LinkedFolder> decode(String? raw) {
    if (raw == null || raw.isEmpty) return const [];
    try {
      return [for (final e in jsonDecode(raw) as List) fromJson((e as Map).cast<String, dynamic>())];
    } catch (_) {
      return const [];
    }
  }

  static String encode(List<LinkedFolder> v) => jsonEncode([for (final e in v) e.toJson()]);
}

/// 연결한 폴더의 파일 읽기 · 지우기.
///
/// 저장소 권한이 없어서 이 폴더의 파일은 경로(File)로는 열리지 않는다. 대신 시스템에 "이 폴더의 이 파일을 열어 달라" 고 해서
/// 받은 파일 번호로 읽는다([FileRef]). 연결한 폴더 밖의 파일(앱 전용 폴더, 전체판의 모든 파일)은 지금까지처럼 경로로 읽는다.
class Linked {
  Linked._();

  /// 지금 연결된 폴더들 (AppState 가 설정에서 읽어 넣는다)
  static List<LinkedFolder> folders = const [];

  static LinkedFolder? of(String path) {
    for (final f in folders) {
      if (path == f.path || path.startsWith('${f.path}/')) return f;
    }
    return null;
  }

  static bool has(String path) => folders.isNotEmpty && of(path) != null;

  /// 연결한 폴더 기준 상대 경로 ('' = 폴더 자신)
  static String rel(LinkedFolder f, String path) => path.length <= f.path.length ? '' : path.substring(f.path.length + 1);

  /// 읽을 수 있게 연다. 연결한 폴더의 파일이 아니면 경로 그대로.
  /// 연결한 폴더의 파일인데 열지 못하면(SD 카드를 뺐거나 폴더 권한이 풀림) [FileSystemException]
  static Future<FileRef> ref(String path) async {
    final f = of(path);
    if (f == null) return FileRef(path);
    final r = await Saf.openFd(tree: f.tree, rel: rel(f, path));
    if (r == null) {
      throw FileSystemException(
          f.removable ? '파일을 열 수 없습니다. SD 카드(또는 USB)가 꽂혀 있는지 확인하세요' : '파일을 열 수 없습니다. 폴더를 옮겼거나 지웠다면 다시 연결해 주세요', path);
    }
    return FileRef(path, r.fd, r.size);
  }

  /// 열고 → [body] → 닫기 (파일 번호를 잊지 않고 한 번만 닫는다)
  static Future<T> use<T>(String path, Future<T> Function(FileRef ref) body) async {
    final r = await ref(path);
    try {
      return await body(r);
    } finally {
      r.close();
    }
  }

  static Future<bool> exists(String path) async {
    final f = of(path);
    if (f == null) return File(path).exists();
    final r = await Saf.openFd(tree: f.tree, rel: rel(f, path));
    if (r == null) return false;
    closeFd(r.fd);
    return true;
  }

  /// 영상 플레이어 · 썸네일처럼 주소를 받는 곳에 넘길 content:// 주소 (연결한 폴더의 파일이 아니면 null)
  static Future<String?> uri(String path) async {
    final f = of(path);
    return f == null ? null : Saf.docUri(f.tree, rel(f, path));
  }

  static Future<bool> delete(String path) async {
    final f = of(path);
    if (f == null) return false;
    return Saf.deleteIn(f.tree, rel(f, path));
  }
}
