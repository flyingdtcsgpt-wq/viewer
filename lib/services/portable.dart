import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// 휴대용 모드: 앱 옆에 `arariflex_data` 폴더가 있으면 라이브러리 DB · 설정 · 표지 · 음성/글자 인식 모델을 전부 그 안에 둔다.
/// 폴더째 USB 에 담아 인터넷 없는 다른 PC 로 옮겨도 그대로 쓸 수 있다.
class Portable {
  Portable._();

  static const folderName = 'arariflex_data';

  /// 휴대용 데이터 폴더 (꺼져 있으면 null)
  static String? root;
  static bool get enabled => root != null;

  /// 앱 실행 파일이 있는 폴더 (macOS 는 .app 이 있는 폴더)
  static String get appDir {
    var d = p.dirname(Platform.resolvedExecutable);
    if (Platform.isMacOS && d.endsWith('/Contents/MacOS')) d = p.dirname(p.dirname(p.dirname(d)));
    return d;
  }

  static String get candidate => p.join(appDir, folderName);

  /// main() 맨 처음에 부른다
  static Future<void> init() async {
    if (!(Platform.isWindows || Platform.isMacOS || Platform.isLinux)) return;
    final d = Directory(candidate);
    if (!await d.exists()) return;
    root = d.path;
    PathProviderPlatform.instance = _PortablePaths(PathProviderPlatform.instance, d.path);
  }

  /// 지금 쓰는 데이터를 앱 옆 arariflex_data 로 복사해 휴대용으로 만든다. 다음 실행부터 적용.
  /// [prefs]: 지금 설정 값 (settings.json 으로 저장)
  static Future<String> makePortable(Map<String, Object?> prefs) async {
    final target = Directory(candidate);
    try {
      await target.create(recursive: true);
      final probe = File(p.join(target.path, '.write_test'));
      await probe.writeAsString('ok');
      await probe.delete();
    } catch (_) {
      throw '앱 폴더에 쓸 수 없습니다 ($appDir).\n설치판(Program Files)은 휴대용으로 만들 수 없으니 포터블 zip 판을 쓰세요.';
    }
    final from = Directory((await getApplicationSupportDirectory()).path);
    if (p.equals(from.path, target.path)) return target.path;
    await for (final e in from.list(recursive: true, followLinks: false)) {
      final rel = p.relative(e.path, from: from.path);
      if (rel.startsWith('arariflex_data')) continue;
      final dest = p.join(target.path, rel);
      if (e is Directory) {
        await Directory(dest).create(recursive: true);
      } else if (e is File) {
        await Directory(p.dirname(dest)).create(recursive: true);
        await e.copy(dest);
      }
    }
    await File(p.join(target.path, 'settings.json')).writeAsString(const JsonEncoder.withIndent(' ').convert(prefs));
    return target.path;
  }
}

class _PortablePaths extends PathProviderPlatform {
  final PathProviderPlatform base;
  final String root;
  _PortablePaths(this.base, this.root);

  Future<String> _dir(String sub) async {
    final d = Directory(sub.isEmpty ? root : p.join(root, sub));
    await d.create(recursive: true);
    return d.path;
  }

  @override
  Future<String?> getApplicationSupportPath() => _dir('');
  @override
  Future<String?> getApplicationDocumentsPath() => _dir('documents');
  @override
  Future<String?> getApplicationCachePath() => _dir('cache');
  @override
  Future<String?> getTemporaryPath() => base.getTemporaryPath(); // 임시 파일은 USB 대신 PC 에 (빠르게)
  @override
  Future<String?> getDownloadsPath() => base.getDownloadsPath();
  @override
  Future<String?> getLibraryPath() => base.getLibraryPath();
  @override
  Future<String?> getExternalStoragePath() => base.getExternalStoragePath();
  @override
  Future<List<String>?> getExternalCachePaths() => base.getExternalCachePaths();
  @override
  Future<List<String>?> getExternalStoragePaths({StorageDirectory? type}) => base.getExternalStoragePaths(type: type);
}

/// 설정 저장소: 보통은 SharedPreferences, 휴대용 모드면 arariflex_data/settings.json
abstract class Prefs {
  static Future<Prefs> open() async {
    final r = Portable.root;
    if (r != null) return _FilePrefs.load(p.join(r, 'settings.json'));
    return _SharedPrefs(await SharedPreferences.getInstance());
  }

  bool? getBool(String k);
  int? getInt(String k);
  double? getDouble(String k);
  String? getString(String k);
  List<String>? getStringList(String k);
  Future<bool> setBool(String k, bool v);
  Future<bool> setInt(String k, int v);
  Future<bool> setDouble(String k, double v);
  Future<bool> setString(String k, String v);
  Future<bool> setStringList(String k, List<String> v);
  Future<bool> remove(String k);

  /// 모든 값 (휴대용으로 옮길 때)
  Map<String, Object?> all();
}

class _SharedPrefs implements Prefs {
  final SharedPreferences s;
  _SharedPrefs(this.s);
  @override
  bool? getBool(String k) => s.getBool(k);
  @override
  int? getInt(String k) => s.getInt(k);
  @override
  double? getDouble(String k) => s.getDouble(k);
  @override
  String? getString(String k) => s.getString(k);
  @override
  List<String>? getStringList(String k) => s.getStringList(k);
  @override
  Future<bool> setBool(String k, bool v) => s.setBool(k, v);
  @override
  Future<bool> setInt(String k, int v) => s.setInt(k, v);
  @override
  Future<bool> setDouble(String k, double v) => s.setDouble(k, v);
  @override
  Future<bool> setString(String k, String v) => s.setString(k, v);
  @override
  Future<bool> setStringList(String k, List<String> v) => s.setStringList(k, v);
  @override
  Future<bool> remove(String k) => s.remove(k);
  @override
  Map<String, Object?> all() => {for (final k in s.getKeys()) k: s.get(k)};
}

/// JSON 파일 하나에 저장 (값을 바꾸면 잠시 뒤 한 번에 씀)
class _FilePrefs implements Prefs {
  final File file;
  final Map<String, Object?> m;
  bool _pending = false;
  _FilePrefs(this.file, this.m);

  static Future<_FilePrefs> load(String path) async {
    final f = File(path);
    Map<String, Object?> m = {};
    try {
      if (await f.exists()) m = (jsonDecode(await f.readAsString()) as Map).cast<String, Object?>();
    } catch (_) {
      // 깨진 파일은 옆에 두고 새로 시작
      try {
        await f.copy('$path.broken');
      } catch (_) {}
    }
    return _FilePrefs(f, m);
  }

  Future<bool> _put(String k, Object? v) async {
    if (v == null) {
      m.remove(k);
    } else {
      m[k] = v;
    }
    if (!_pending) {
      _pending = true;
      Future.delayed(const Duration(milliseconds: 300), () async {
        _pending = false;
        final tmp = File('${file.path}.tmp');
        await tmp.writeAsString(const JsonEncoder.withIndent(' ').convert(m));
        await tmp.rename(file.path);
      });
    }
    return true;
  }

  T? _get<T>(String k) {
    final v = m[k];
    return v is T ? v : null;
  }

  @override
  bool? getBool(String k) => _get<bool>(k);
  @override
  int? getInt(String k) => _get<int>(k);
  @override
  double? getDouble(String k) {
    final v = m[k];
    return v is num ? v.toDouble() : null;
  }

  @override
  String? getString(String k) => _get<String>(k);
  @override
  List<String>? getStringList(String k) {
    final v = m[k];
    return v is List ? v.map((e) => '$e').toList() : null;
  }

  @override
  Future<bool> setBool(String k, bool v) => _put(k, v);
  @override
  Future<bool> setInt(String k, int v) => _put(k, v);
  @override
  Future<bool> setDouble(String k, double v) => _put(k, v);
  @override
  Future<bool> setString(String k, String v) => _put(k, v);
  @override
  Future<bool> setStringList(String k, List<String> v) => _put(k, v);
  @override
  Future<bool> remove(String k) => _put(k, null);
  @override
  Map<String, Object?> all() => Map.of(m);
}
