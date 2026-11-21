import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:sqflite/sqflite.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart' show sqfliteFfiInit, databaseFactoryFfi;

import '../models/media_item.dart';
import '../models/series.dart';
import '../services/auth.dart';

class LibraryDb {
  late final Database _db;

  static Future<LibraryDb> open() async {
    // Windows / macOS / Linux 는 FFI 구현, Android / iOS 는 기본 sqflite 사용
    if (Platform.isWindows || Platform.isLinux || Platform.isMacOS) {
      sqfliteFfiInit();
      databaseFactory = databaseFactoryFfi;
    }
    final dir = await getApplicationSupportDirectory();
    final db = LibraryDb();
    db._db = await openDatabase(
      p.join(dir.path, 'library.db'),
      version: 5,
      onCreate: (db, _) async {
        await db.execute('''
          CREATE TABLE items(
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            path TEXT NOT NULL UNIQUE,
            kind TEXT NOT NULL,
            storage TEXT NOT NULL,
            title TEXT NOT NULL,
            author TEXT, publisher TEXT, isbn TEXT, series TEXT,
            year INTEGER, description TEXT, cover_path TEXT,
            tags TEXT, rating INTEGER DEFAULT 0, favorite INTEGER DEFAULT 0,
            size INTEGER DEFAULT 0, added_at INTEGER NOT NULL,
            missing INTEGER DEFAULT 0,
            progress REAL DEFAULT 0, position TEXT, last_opened INTEGER,
            series_id INTEGER, volume REAL, hidden INTEGER DEFAULT 0, pages INTEGER
          )''');
        await _createSeries(db);
        await db.execute('ALTER TABLE series ADD COLUMN hidden INTEGER DEFAULT 0');
        await _createUsers(db);
        await db.execute('CREATE INDEX idx_items_kind ON items(kind)');
        await db.execute('CREATE INDEX idx_items_title ON items(title)');
      },
      onUpgrade: (db, from, to) async {
        if (from < 2) {
          await db.execute('ALTER TABLE items ADD COLUMN progress REAL DEFAULT 0');
          await db.execute('ALTER TABLE items ADD COLUMN position TEXT');
          await db.execute('ALTER TABLE items ADD COLUMN last_opened INTEGER');
        }
        if (from < 3) {
          await db.execute('ALTER TABLE items ADD COLUMN series_id INTEGER');
          await db.execute('ALTER TABLE items ADD COLUMN volume REAL');
          await _createSeries(db);
        }
        if (from < 4) {
          await db.execute('ALTER TABLE items ADD COLUMN hidden INTEGER DEFAULT 0');
          await db.execute('ALTER TABLE series ADD COLUMN hidden INTEGER DEFAULT 0');
          await _createUsers(db);
        }
        if (from < 5) {
          await db.execute('ALTER TABLE items ADD COLUMN pages INTEGER');
          await db.execute('UPDATE items SET rating = rating * 2'); // 5점 → 10점 만점
        }
      },
    );
    await db._tune();
    return db;
  }

  /// 큰 라이브러리용: 빠른 쓰기 모드, 지울 때 쓰는 색인, 끝없이 늘어나는 열람 기록 줄이기
  Future<void> _tune() async {
    for (final sql in [
      'PRAGMA journal_mode=WAL',
      'PRAGMA synchronous=NORMAL',
      'CREATE INDEX IF NOT EXISTS idx_history_item ON history(item_id)',
      'CREATE INDEX IF NOT EXISTS idx_progress_item ON user_progress(item_id)',
      'CREATE INDEX IF NOT EXISTS idx_denied_target ON denied(target)',
    ]) {
      try {
        await _db.rawQuery(sql); // PRAGMA 는 결과를 돌려주므로 rawQuery
      } catch (_) {}
    }
    try {
      // 기록이 많이 쌓였을 때만: 사용자마다 최근 5000건만 남긴다
      final n = Sqflite.firstIntValue(await _db.rawQuery('SELECT COUNT(*) FROM history')) ?? 0;
      if (n > 50000) await _db.execute('DELETE FROM history WHERE id NOT IN (SELECT id FROM history h2 WHERE h2.user_id = history.user_id ORDER BY opened_at DESC LIMIT 5000)');
    } catch (_) {}
  }

  /// 여러 항목을 한 번에 넣기 (id 를 채워 준다)
  Future<void> insertMany(List<MediaItem> items) async {
    await _db.transaction((txn) async {
      for (final e in items) {
        e.id = await txn.insert('items', e.toMap(), conflictAlgorithm: ConflictAlgorithm.ignore);
      }
    });
  }

  /// 여러 항목을 한 번에 저장 (하나의 트랜잭션: 수만 개도 몇 초)
  Future<void> updateMany(Iterable<MediaItem> items) async {
    final list = items.toList();
    if (list.isEmpty) return;
    await _db.transaction((txn) async {
      final b = txn.batch();
      for (final e in list) {
        b.update('items', e.toMap(), where: 'id = ?', whereArgs: [e.id]);
      }
      await b.commit(noResult: true);
    });
  }

  /// 여러 묶음을 한 번에 저장
  Future<void> updateSeriesMany(Iterable<Series> list) async {
    final l = list.toList();
    if (l.isEmpty) return;
    await _db.transaction((txn) async {
      final b = txn.batch();
      for (final s in l) {
        b.update('series', s.toMap(), where: 'id = ?', whereArgs: [s.id]);
      }
      await b.commit(noResult: true);
    });
  }

  /// 여러 묶음을 한 번에 지우기
  Future<void> deleteSeriesMany(List<int> ids) async {
    if (ids.isEmpty) return;
    await _db.transaction((txn) async {
      for (var i = 0; i < ids.length; i += 500) {
        final chunk = ids.sublist(i, ids.length < i + 500 ? ids.length : i + 500);
        final marks = List.filled(chunk.length, '?').join(',');
        await txn.delete('series', where: 'id IN ($marks)', whereArgs: chunk);
        await txn.delete('denied', where: 'target IN ($marks)', whereArgs: [for (final id in chunk) 's:$id']);
      }
    });
  }

  /// 여러 항목을 한 번에 지우기 (진행률 · 기록 · 권한 포함)
  Future<void> deleteMany(List<int> ids) async {
    if (ids.isEmpty) return;
    await _db.transaction((txn) async {
      for (var i = 0; i < ids.length; i += 500) {
        final chunk = ids.sublist(i, ids.length < i + 500 ? ids.length : i + 500);
        final marks = List.filled(chunk.length, '?').join(',');
        await txn.delete('items', where: 'id IN ($marks)', whereArgs: chunk);
        await txn.delete('user_progress', where: 'item_id IN ($marks)', whereArgs: chunk);
        await txn.delete('history', where: 'item_id IN ($marks)', whereArgs: chunk);
        await txn.delete('denied', where: 'target IN ($marks)', whereArgs: [for (final id in chunk) 'i:$id']);
      }
    });
  }

  // ---------- 백업 · 복원 ----------
  String get path => _db.path;
  Future<void> close() => _db.close();

  /// 지금 DB 를 한 파일로 깔끔하게 복사 (쓰는 중이어도 일관된 사본). 오래된 SQLite 면 체크포인트 뒤 파일 복사
  Future<void> copyTo(String out) async {
    final f = File(out);
    if (await f.exists()) await f.delete();
    try {
      await _db.execute("VACUUM INTO '${out.replaceAll("'", "''")}'");
      if (await f.exists() && await f.length() > 0) return;
    } catch (_) {}
    try {
      await _db.rawQuery('PRAGMA wal_checkpoint(TRUNCATE)');
    } catch (_) {}
    await File(_db.path).copy(out);
  }

  /// 표지 경로를 새 데이터 폴더에 맞게 고친다 (다른 PC · 다시 설치한 뒤 복원했을 때). 고친 수
  Future<int> rewriteCoverPaths(String? Function(String path) fix) async {
    var n = 0;
    await _db.transaction((txn) async {
      for (final table in ['items', 'series']) {
        final rows = await txn.query(table, columns: ['id', 'cover_path'], where: 'cover_path IS NOT NULL');
        final b = txn.batch();
        for (final r in rows) {
          final to = fix(r['cover_path'] as String);
          if (to == null) continue;
          b.update(table, {'cover_path': to}, where: 'id = ?', whereArgs: [r['id']]);
          n++;
        }
        await b.commit(noResult: true);
      }
    });
    return n;
  }

  static Future<void> _createSeries(Database db) async {
    await db.execute('''
      CREATE TABLE series(
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        parent_id INTEGER,
        title TEXT NOT NULL,
        author TEXT, description TEXT, cover_path TEXT,
        total INTEGER, status TEXT, added_at INTEGER NOT NULL
      )''');
    await db.execute('CREATE INDEX idx_items_series ON items(series_id)');
  }

  static Future<void> _createUsers(Database db) async {
    await db.execute('''
      CREATE TABLE users(
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        name TEXT NOT NULL UNIQUE,
        role TEXT NOT NULL,
        pw_hash TEXT, salt TEXT,
        created_at INTEGER NOT NULL
      )''');
    // 사용자마다 따로 저장하는 읽은 위치
    await db.execute('''
      CREATE TABLE user_progress(
        user_id INTEGER NOT NULL, item_id INTEGER NOT NULL,
        progress REAL, position TEXT, last_opened INTEGER,
        PRIMARY KEY(user_id, item_id)
      )''');
    // 열람 기록 (열 때마다 한 줄)
    await db.execute('''
      CREATE TABLE history(
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        user_id INTEGER NOT NULL, item_id INTEGER NOT NULL,
        opened_at INTEGER NOT NULL, closed_at INTEGER,
        progress REAL, position TEXT
      )''');
    await db.execute('CREATE INDEX idx_history_user ON history(user_id, opened_at)');
    // 관리자가 막아둔 접근 ('s:묶음id' / 'i:항목id')
    await db.execute('''
      CREATE TABLE denied(
        user_id INTEGER NOT NULL, target TEXT NOT NULL,
        PRIMARY KEY(user_id, target)
      )''');
  }

  // ---------- 사용자 ----------
  Future<List<AppUser>> users() async => (await _db.query('users', orderBy: 'id')).map(AppUser.fromMap).toList();
  Future<int> insertUser(AppUser u) => _db.insert('users', u.toMap());
  Future<void> updateUser(AppUser u) => _db.update('users', u.toMap(), where: 'id = ?', whereArgs: [u.id]);
  Future<void> deleteUser(int id) async {
    for (final t in ['user_progress', 'history', 'denied']) {
      await _db.delete(t, where: 'user_id = ?', whereArgs: [id]);
    }
    await _db.delete('users', where: 'id = ?', whereArgs: [id]);
  }

  /// 첫 관리자에게 기존(사용자 기능 전) 진행 기록을 넘겨준다
  Future<void> adoptLegacyProgress(int userId) => _db.execute(
        'INSERT OR IGNORE INTO user_progress(user_id, item_id, progress, position, last_opened) '
        'SELECT ?, id, progress, position, last_opened FROM items WHERE last_opened IS NOT NULL',
        [userId],
      );

  Future<Map<int, (double, String?, int?)>> progressFor(int userId) async {
    final rows = await _db.query('user_progress', where: 'user_id = ?', whereArgs: [userId]);
    return {
      for (final r in rows)
        r['item_id'] as int: ((r['progress'] as num?)?.toDouble() ?? 0, r['position'] as String?, r['last_opened'] as int?)
    };
  }

  Future<void> saveProgress(int userId, MediaItem e) => _db.insert(
        'user_progress',
        {
          'user_id': userId,
          'item_id': e.id,
          'progress': e.progress,
          'position': e.position,
          'last_opened': e.lastOpened?.millisecondsSinceEpoch,
        },
        conflictAlgorithm: ConflictAlgorithm.replace,
      );

  /// 여러 항목의 읽은 정도를 한 번에 저장
  Future<void> saveProgressMany(int userId, Iterable<MediaItem> items) async {
    final list = items.where((e) => e.id != null).toList();
    if (list.isEmpty) return;
    await _db.transaction((txn) async {
      final b = txn.batch();
      for (final e in list) {
        b.insert(
          'user_progress',
          {'user_id': userId, 'item_id': e.id, 'progress': e.progress, 'position': e.position, 'last_opened': e.lastOpened?.millisecondsSinceEpoch},
          conflictAlgorithm: ConflictAlgorithm.replace,
        );
      }
      await b.commit(noResult: true);
    });
  }

  /// 열람 기록 줄 시작. 같은 작품을 같은 날 다시 열면 줄을 새로 만들지 않고 그날의 줄을 맨 위로 올린다
  /// (뷰어를 닫았다 다시 열 때마다 같은 작품이 줄줄이 쌓이지 않게. 전에 쌓인 같은 날 줄도 이때 하나로 합친다)
  Future<int> startHistory(int userId, int itemId) async {
    final now = DateTime.now();
    final dayStart = DateTime(now.year, now.month, now.day).millisecondsSinceEpoch;
    final rows = await _db.query('history',
        columns: ['id'], where: 'user_id = ? AND item_id = ? AND opened_at >= ?', whereArgs: [userId, itemId, dayStart], orderBy: 'opened_at DESC');
    if (rows.isEmpty) {
      return _db.insert('history', {'user_id': userId, 'item_id': itemId, 'opened_at': now.millisecondsSinceEpoch});
    }
    final keep = rows.first['id'] as int;
    await _db.update('history', {'opened_at': now.millisecondsSinceEpoch}, where: 'id = ?', whereArgs: [keep]);
    if (rows.length > 1) {
      await _db.delete('history', where: 'id IN (${[for (final r in rows.skip(1)) r['id']].join(',')})');
    }
    return keep;
  }

  Future<void> updateHistory(int id, double progress, String? position) => _db.update(
        'history',
        {'progress': progress, 'position': position, 'closed_at': DateTime.now().millisecondsSinceEpoch},
        where: 'id = ?',
        whereArgs: [id],
      );

  Future<List<HistoryRecord>> history(int userId, {int limit = 500}) async =>
      (await _db.query('history', where: 'user_id = ?', whereArgs: [userId], orderBy: 'opened_at DESC', limit: limit))
          .map(HistoryRecord.fromMap)
          .toList();

  Future<void> clearHistory(int userId) => _db.delete('history', where: 'user_id = ?', whereArgs: [userId]);

  Future<Set<String>> deniedFor(int userId) async =>
      (await _db.query('denied', where: 'user_id = ?', whereArgs: [userId])).map((r) => r['target'] as String).toSet();

  Future<void> setDenied(int userId, String target, bool deny) => deny
      ? _db.insert('denied', {'user_id': userId, 'target': target}, conflictAlgorithm: ConflictAlgorithm.ignore)
      : _db.delete('denied', where: 'user_id = ? AND target = ?', whereArgs: [userId, target]);

  // ---------- 묶음 ----------
  Future<List<Series>> allSeries() async => (await _db.query('series')).map(Series.fromMap).toList();
  Future<int> insertSeries(Series s) => _db.insert('series', s.toMap());
  Future<void> updateSeries(Series s) => _db.update('series', s.toMap(), where: 'id = ?', whereArgs: [s.id]);
  Future<void> deleteSeries(int id) async {
    await _db.delete('series', where: 'id = ?', whereArgs: [id]);
    await _db.delete('denied', where: 'target = ?', whereArgs: ['s:$id']);
  }

  Future<List<MediaItem>> all() async =>
      (await _db.query('items', orderBy: 'added_at DESC')).map(MediaItem.fromMap).toList();

  Future<bool> exists(String path) async =>
      (await _db.query('items', columns: ['id'], where: 'path = ?', whereArgs: [path])).isNotEmpty;

  Future<int> insert(MediaItem item) =>
      _db.insert('items', item.toMap(), conflictAlgorithm: ConflictAlgorithm.ignore);

  Future<void> update(MediaItem item) =>
      _db.update('items', item.toMap(), where: 'id = ?', whereArgs: [item.id]);

  Future<void> delete(int id) async {
    await _db.delete('items', where: 'id = ?', whereArgs: [id]);
    for (final t in ['user_progress', 'history']) {
      await _db.delete(t, where: 'item_id = ?', whereArgs: [id]);
    }
    await _db.delete('denied', where: 'target = ?', whereArgs: ['i:$id']);
  }
}
