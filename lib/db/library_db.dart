import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:sqflite/sqflite.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart' show sqfliteFfiInit, databaseFactoryFfi;

import '../models/media_item.dart';
import '../models/series.dart';

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
      version: 3,
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
            series_id INTEGER, volume REAL
          )''');
        await _createSeries(db);
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
      },
    );
    return db;
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

  // ---------- 묶음 ----------
  Future<List<Series>> allSeries() async => (await _db.query('series')).map(Series.fromMap).toList();
  Future<int> insertSeries(Series s) => _db.insert('series', s.toMap());
  Future<void> updateSeries(Series s) => _db.update('series', s.toMap(), where: 'id = ?', whereArgs: [s.id]);
  Future<void> deleteSeries(int id) => _db.delete('series', where: 'id = ?', whereArgs: [id]);

  Future<List<MediaItem>> all() async =>
      (await _db.query('items', orderBy: 'added_at DESC')).map(MediaItem.fromMap).toList();

  Future<bool> exists(String path) async =>
      (await _db.query('items', columns: ['id'], where: 'path = ?', whereArgs: [path])).isNotEmpty;

  Future<int> insert(MediaItem item) =>
      _db.insert('items', item.toMap(), conflictAlgorithm: ConflictAlgorithm.ignore);

  Future<void> update(MediaItem item) =>
      _db.update('items', item.toMap(), where: 'id = ?', whereArgs: [item.id]);

  Future<void> delete(int id) => _db.delete('items', where: 'id = ?', whereArgs: [id]);
}
