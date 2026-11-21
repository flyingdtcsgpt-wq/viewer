import 'dart:convert';
import 'dart:io';
import 'dart:isolate';

import 'package:archive/archive_io.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../db/library_db.dart';
import '../version.dart';
import 'portable.dart';

/// 백업 파일에 든 것
class BackupInfo {
  final String created; // 만든 때 (ISO)
  final String version; // 만든 앱 판
  final String platform;
  final int items, series, users, covers;
  const BackupInfo(this.created, this.version, this.platform, this.items, this.series, this.users, this.covers);

  Map<String, Object?> toJson() =>
      {'app': 'ARARIFlex', 'created': created, 'version': version, 'platform': platform, 'items': items, 'series': series, 'users': users, 'covers': covers};

  static BackupInfo fromJson(Map<String, Object?> m) => BackupInfo('${m['created'] ?? ''}', '${m['version'] ?? ''}', '${m['platform'] ?? ''}',
      (m['items'] as num?)?.toInt() ?? 0, (m['series'] as num?)?.toInt() ?? 0, (m['users'] as num?)?.toInt() ?? 0, (m['covers'] as num?)?.toInt() ?? 0);
}

class BackupError implements Exception {
  final String message;
  const BackupError(this.message);
  @override
  String toString() => message;
}

/// 서재 백업 · 복원
///
/// 백업(zip): library.db(서재 목록 · 묶음 · 계정 · 읽은 위치 · 기록 · 권한) + settings.json(모든 설정) +
/// ai_speakers/(AI 화자 분석) + covers/(표지, 선택) + manifest.json.
/// 책 · 만화 · 영상 파일 자체와 내려받은 AI 모델은 넣지 않는다.
/// 복원은 파일을 풀어 `restore_pending` 에 준비해 두고, 앱을 다시 켤 때(DB · 설정을 열기 전) 바꿔 넣는다.
class Backup {
  Backup._();

  static const _pending = 'restore_pending';
  static const _fixFile = 'restore_fix.json';

  static Future<String> _support() async => (await getApplicationSupportDirectory()).path;

  static String fileName(DateTime t) {
    String two(int v) => v.toString().padLeft(2, '0');
    return 'ARARIFlex-backup-${t.year}${two(t.month)}${two(t.day)}-${two(t.hour)}${two(t.minute)}.zip';
  }

  /// 백업 만들기. 만든 파일 경로
  static Future<String> create({
    required LibraryDb db,
    required Map<String, Object?> prefs,
    required String outDir,
    required BackupInfo info,
    bool covers = true,
    String? password,
    String? name,
  }) async {
    final support = await _support();
    await Directory(outDir).create(recursive: true);
    final out = p.join(outDir, name ?? fileName(DateTime.now()));
    final pw = password == null || password.isEmpty ? null : password;
    final tmpDb = p.join(support, 'backup_tmp.db');
    await db.copyTo(tmpDb);
    try {
      final manifest = jsonEncode({...info.toJson(), 'supportDir': support, 'hasCovers': covers});
      final settings = const JsonEncoder.withIndent(' ').convert(prefs);
      await Isolate.run(() => _zip(out, tmpDb, support, manifest, settings, covers, pw));
    } finally {
      try {
        await File(tmpDb).delete();
      } catch (_) {}
    }
    return out;
  }

  /// [password] 가 있으면 안의 파일을 모두 암호화한다 (AES. 암호를 잊으면 풀 수 없다)
  static void _zip(String out, String dbFile, String support, String manifest, String settings, bool covers, String? password) {
    final enc = ZipFileEncoder(password: password)..create(out, level: 6);
    try {
      enc.addArchiveFile(ArchiveFile.string('manifest.json', manifest));
      enc.addArchiveFile(ArchiveFile.string('settings.json', settings));
      enc.addArchiveFile(ArchiveFile.bytes('library.db', File(dbFile).readAsBytesSync()));
      void addDir(String name, {bool store = false}) {
        final d = Directory(p.join(support, name));
        if (!d.existsSync()) return;
        for (final f in d.listSync(followLinks: false).whereType<File>()) {
          final bytes = f.readAsBytesSync();
          final entry = '$name/${p.basename(f.path)}';
          // 표지(JPEG · PNG)는 이미 압축돼 있어 그대로 저장
          enc.addArchiveFile(store ? ArchiveFile.noCompress(entry, bytes.length, bytes) : ArchiveFile.bytes(entry, bytes));
        }
      }

      addDir('ai_speakers');
      if (covers) addDir('covers', store: true);
    } finally {
      enc.closeSync();
    }
  }

  /// 백업을 두는 기본 폴더 (안드로이드: Download/ARARIFlex 백업 — 앱을 지워도 남는다. 그 밖: 문서/ARARIFlex 백업)
  static Future<String> defaultDir() async {
    if (Platform.isAndroid) return '/storage/emulated/0/Download/ARARIFlex 백업';
    return p.join((await getApplicationDocumentsDirectory()).path, 'ARARIFlex 백업');
  }

  /// 암호가 걸린 백업인가 (zip 의 첫 파일 머리표에 있는 "암호화" 표시를 본다)
  static Future<bool> isLocked(String zipPath) async {
    try {
      final head = await File(zipPath).openRead(0, 8).fold<List<int>>([], (a, b) => a..addAll(b));
      return head.length >= 8 && head[0] == 0x50 && head[1] == 0x4b && head[2] == 3 && head[3] == 4 && (head[6] & 1) != 0;
    } catch (_) {
      return false;
    }
  }

  /// 자동 백업: [everyDays] 일이 지났으면 서재 · 설정만(표지 없이) 작게 저장하고, 자기가 만든 것 중 최근 [keep] 개만 남긴다.
  /// 만들었으면 파일 경로, 아직 때가 아니거나 못 만들었으면 null. [last]: 마지막 자동 백업 때 (ISO)
  static Future<String?> auto({
    required LibraryDb db,
    required Map<String, Object?> prefs,
    required String outDir,
    required BackupInfo info,
    required String last,
    String? password,
    int everyDays = 7,
    int keep = 4,
  }) async {
    final lastAt = DateTime.tryParse(last);
    if (lastAt != null && DateTime.now().difference(lastAt) < Duration(days: everyDays)) return null;
    try {
      final t = DateTime.now();
      String two(int n) => n.toString().padLeft(2, '0');
      final name = '$autoPrefix${t.year}${two(t.month)}${two(t.day)}-${two(t.hour)}${two(t.minute)}.zip';
      final out = await create(db: db, prefs: prefs, outDir: outDir, info: info, covers: false, password: password, name: name);
      // 오래된 자동 백업 정리 (이름순 = 날짜순). 앱을 다시 깔기 전에 만든 것은 지울 권한이 없을 수 있다 → 그냥 둔다
      final old = [
        await for (final e in Directory(outDir).list(followLinks: false))
          if (e is File && p.basename(e.path).startsWith(autoPrefix) && e.path.endsWith('.zip')) e.path,
      ]..sort();
      for (final f in old.take(old.length > keep ? old.length - keep : 0)) {
        try {
          await File(f).delete();
        } catch (_) {}
      }
      return out;
    } catch (_) {
      return null;
    }
  }

  static const autoPrefix = 'ARARIFlex-자동백업-';

  /// 백업 파일을 확인하고, 다음에 앱을 켤 때 적용되게 준비한다. 암호가 걸린 백업이면 [password]
  static Future<BackupInfo> stage(String zipPath, {String? password}) async {
    final support = await _support();
    final tmp = Directory(p.join(support, '$_pending.tmp'));
    if (await tmp.exists()) await tmp.delete(recursive: true);
    await tmp.create(recursive: true);
    try {
      final locked = await isLocked(zipPath);
      if (locked && (password == null || password.isEmpty)) throw const BackupError('암호가 걸린 백업입니다. 암호를 넣어 주세요');
      final into = tmp.path;
      final pw = locked ? password : null;
      String? manifest;
      try {
        manifest = await Isolate.run(() => _unzip(zipPath, into, pw));
      } catch (e) {
        if (locked) throw const BackupError('암호가 맞지 않습니다');
        rethrow;
      }
      if (manifest == null) throw const BackupError('ARARIFlex 백업 파일이 아닙니다 (library.db 가 없음)');
      final dbFile = File(p.join(tmp.path, 'library.db'));
      final head = await dbFile.openRead(0, 16).fold<List<int>>([], (a, b) => a..addAll(b));
      if (utf8.decode(head.take(15).toList(), allowMalformed: true) != 'SQLite format 3') {
        throw BackupError(locked ? '암호가 맞지 않습니다' : '백업 파일이 깨졌습니다 (서재 DB 를 읽을 수 없음)');
      }
      final target = Directory(p.join(support, _pending));
      if (await target.exists()) await target.delete(recursive: true);
      await tmp.rename(target.path);
      return BackupInfo.fromJson((jsonDecode(manifest) as Map).cast<String, Object?>());
    } catch (e) {
      if (await tmp.exists()) await tmp.delete(recursive: true);
      if (e is BackupError) rethrow;
      throw BackupError('백업 파일을 읽지 못했습니다: $e');
    }
  }

  /// zip 을 풀고 manifest.json 내용을 돌려준다 (library.db 가 없으면 null). 폴더 밖으로 나가는 이름은 무시
  static String? _unzip(String zipPath, String into, String? password) {
    final input = InputFileStream(zipPath);
    try {
      final zip = ZipDecoder().decodeStream(input, password: password);
      String? manifest;
      var hasDb = false;
      for (final f in zip.files.where((f) => f.isFile)) {
        final name = f.name.replaceAll('\\', '/');
        final ok = name == 'manifest.json' ||
            name == 'settings.json' ||
            name == 'library.db' ||
            (RegExp(r'^(covers|ai_speakers)/[^/]+$').hasMatch(name) && !name.contains('..'));
        if (!ok) continue;
        final target = File(p.join(into, name));
        target.parent.createSync(recursive: true);
        final out = OutputFileStream(target.path);
        try {
          f.writeContent(out);
        } finally {
          out.closeSync();
        }
        if (name == 'library.db') hasDb = true;
        if (name == 'manifest.json') manifest = target.readAsStringSync();
      }
      return hasDb ? (manifest ?? '{}') : null;
    } finally {
      input.closeSync();
    }
  }

  static Future<bool> hasPending() async => Directory(p.join(await _support(), _pending)).exists();

  static Future<void> cancelPending() async {
    final d = Directory(p.join(await _support(), _pending));
    if (await d.exists()) await d.delete(recursive: true);
  }

  /// main() 에서 DB · 설정을 열기 전에 부른다. 준비된 복원이 있으면 바꿔 넣고 true
  static Future<bool> applyPending() async {
    final support = await _support();
    final dir = Directory(p.join(support, _pending));
    if (!await dir.exists()) return false;
    try {
      final staged = File(p.join(dir.path, 'library.db'));
      if (!await staged.exists()) return false;
      // 1) 서재 DB: 지금 것은 하나 남겨 둔다 (잘못 복원했을 때 되돌릴 수 있게)
      final live = File(p.join(support, 'library.db'));
      if (await live.exists()) {
        final keep = File(p.join(support, 'library.before-restore.db'));
        if (await keep.exists()) await keep.delete();
        await live.rename(keep.path);
      }
      for (final ext in ['-wal', '-shm', '-journal']) {
        final f = File('${live.path}$ext');
        if (await f.exists()) await f.delete();
      }
      await staged.copy(live.path);
      // 2) 표지 · AI 화자 분석
      for (final name in ['covers', 'ai_speakers']) {
        final from = Directory(p.join(dir.path, name));
        if (!await from.exists()) continue;
        final to = Directory(p.join(support, name));
        await to.create(recursive: true);
        await for (final f in from.list(followLinks: false)) {
          if (f is File) await f.copy(p.join(to.path, p.basename(f.path)));
        }
      }
      // 3) 설정
      final sf = File(p.join(dir.path, 'settings.json'));
      if (await sf.exists()) {
        final m = (jsonDecode(await sf.readAsString()) as Map).cast<String, Object?>();
        if (Portable.root != null) {
          await File(p.join(Portable.root!, 'settings.json')).writeAsString(const JsonEncoder.withIndent(' ').convert(m));
        } else {
          final prefs = await Prefs.open();
          for (final k in prefs.all().keys.toList()) {
            await prefs.remove(k);
          }
          for (final e in m.entries) {
            final v = e.value;
            if (v is bool) {
              await prefs.setBool(e.key, v);
            } else if (v is int) {
              await prefs.setInt(e.key, v);
            } else if (v is double) {
              await prefs.setDouble(e.key, v);
            } else if (v is String) {
              await prefs.setString(e.key, v);
            } else if (v is List) {
              await prefs.setStringList(e.key, [for (final x in v) '$x']);
            }
          }
        }
      }
      // 4) 표지 경로: 데이터 폴더가 달라졌으면 DB 를 연 뒤 고친다
      String? oldSupport;
      try {
        final mf = File(p.join(dir.path, 'manifest.json'));
        if (await mf.exists()) oldSupport = (jsonDecode(await mf.readAsString()) as Map)['supportDir'] as String?;
      } catch (_) {}
      if (oldSupport != null && oldSupport != support) {
        await File(p.join(support, _fixFile)).writeAsString(jsonEncode({'from': oldSupport}));
      }
      return true;
    } finally {
      try {
        await dir.delete(recursive: true);
      } catch (_) {}
    }
  }

  /// 옛 데이터 폴더의 표지 경로 → 지금 데이터 폴더. 해당 없으면 null
  static String? movedCover(String path, String oldSupport, String newSupport) {
    String norm(String s) => s.replaceAll('\\', '/').toLowerCase();
    final a = norm(path), b = norm(oldSupport);
    if (!a.startsWith(b.endsWith('/') ? b : '$b/')) return null;
    final name = path.replaceAll('\\', '/').split('/').last;
    return p.join(newSupport, 'covers', name);
  }

  /// DB 를 연 뒤: 복원으로 데이터 폴더가 달라졌으면 표지 경로를 고친다
  static Future<void> fixAfterRestore(LibraryDb db) async {
    final support = await _support();
    final f = File(p.join(support, _fixFile));
    if (!await f.exists()) return;
    try {
      final from = (jsonDecode(await f.readAsString()) as Map)['from'] as String?;
      if (from != null) await db.rewriteCoverPaths((path) => movedCover(path, from, support));
    } catch (_) {
    } finally {
      try {
        await f.delete();
      } catch (_) {}
    }
  }

  static BackupInfo describe({required int items, required int series, required int users, required int covers}) =>
      BackupInfo(DateTime.now().toIso8601String(), appVersion, Platform.operatingSystem, items, series, users, covers);
}
