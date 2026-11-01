import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;

import 'db/library_db.dart';
import 'models/media_item.dart';
import 'services/ai_service.dart';
import 'services/cover_service.dart';
import 'services/metadata_service.dart';
import 'services/organizer.dart';
import 'services/settings.dart';

enum SortBy { added, recent, title, author, rating }

class AppState extends ChangeNotifier {
  final LibraryDb db;
  final Settings settings;
  final CoverService covers;
  late final MetadataService metadata = MetadataService(settings);
  late final AiService ai = AiService(settings);

  AppState(this.db, this.settings, this.covers);

  List<MediaItem> _items = [];
  MediaKind? kindFilter; // null = 전체
  bool favoritesOnly = false;
  String query = '';
  String? tagFilter;
  SortBy sortBy = SortBy.added;

  bool scanning = false;
  String scanStatus = '';

  Future<void> load() async {
    _items = await db.all();
    notifyListeners();
  }

  List<MediaItem> get allItems => _items;

  List<MediaItem> get visible {
    final q = query.toLowerCase();
    final list = _items.where((e) {
      if (kindFilter != null && e.kind != kindFilter) return false;
      if (favoritesOnly && !e.favorite) return false;
      if (tagFilter != null && !e.tags.contains(tagFilter)) return false;
      if (q.isEmpty) return true;
      return e.title.toLowerCase().contains(q) ||
          (e.author ?? '').toLowerCase().contains(q) ||
          (e.series ?? '').toLowerCase().contains(q) ||
          e.tags.any((t) => t.toLowerCase().contains(q)) ||
          e.fileName.toLowerCase().contains(q);
    }).toList();
    switch (sortBy) {
      case SortBy.added:
        list.sort((a, b) => b.addedAt.compareTo(a.addedAt));
      case SortBy.recent:
        list.sort((a, b) => (b.lastOpened?.millisecondsSinceEpoch ?? 0).compareTo(a.lastOpened?.millisecondsSinceEpoch ?? 0));
      case SortBy.title:
        list.sort((a, b) => a.title.compareTo(b.title));
      case SortBy.author:
        list.sort((a, b) => (a.author ?? '').compareTo(b.author ?? ''));
      case SortBy.rating:
        list.sort((a, b) => b.rating.compareTo(a.rating));
    }
    return list;
  }

  Set<String> get allTags => {for (final e in _items) ...e.tags};

  int count(MediaKind? k) => k == null ? _items.length : _items.where((e) => e.kind == k).length;

  void setFilter({MediaKind? kind, bool clearKind = false, bool? favorites, String? tag, bool clearTag = false}) {
    if (clearKind) kindFilter = null;
    if (kind != null) kindFilter = kind;
    if (favorites != null) favoritesOnly = favorites;
    if (clearTag) tagFilter = null;
    if (tag != null) tagFilter = tag;
    notifyListeners();
  }

  void setQuery(String q) {
    query = q;
    notifyListeners();
  }

  void setSort(SortBy s) {
    sortBy = s;
    notifyListeners();
  }

  // ---------------- 스캔 / 가져오기 ----------------

  Future<void> addWatchFolder(String dir) async {
    settings.watchFolders = {...settings.watchFolders, dir}.toList();
    await scanFolders([dir]);
  }

  Future<void> rescanAll() => scanFolders(settings.watchFolders);

  Future<void> scanFolders(List<String> dirs) async {
    if (scanning) return;
    scanning = true;
    var added = 0;
    try {
      for (final dir in dirs) {
        final d = Directory(dir);
        if (!await d.exists()) continue;
        await for (final ent in d.list(recursive: true, followLinks: false).handleError((_) {})) {
          if (ent is! File) continue;
          if (kindForPath(ent.path) == null) continue;
          scanStatus = '스캔 중: ${p.basename(ent.path)}';
          notifyListeners();
          if (await _importFile(ent.path, StorageMode.reference)) added++;
        }
      }
      await checkMissing();
      scanStatus = '완료: 새 항목 $added개';
    } finally {
      scanning = false;
      notifyListeners();
    }
  }

  /// 개별 파일 가져오기 (드래그/파일선택). 설정이 managed 면 라이브러리 폴더로 이동/복사.
  Future<void> importFiles(List<String> paths) async {
    scanning = true;
    notifyListeners();
    var added = 0;
    try {
      for (final path in paths) {
        if (kindForPath(path) == null) continue;
        scanStatus = '가져오는 중: ${p.basename(path)}';
        notifyListeners();
        if (await _importFile(path, settings.defaultStorage)) added++;
      }
      scanStatus = '완료: 새 항목 $added개';
    } finally {
      scanning = false;
      notifyListeners();
    }
  }

  Future<bool> _importFile(String path, StorageMode mode) async {
    if (await db.exists(path)) return false;
    final kind = kindForPath(path)!;
    final stat = await File(path).stat();
    final item = MediaItem(
      path: path,
      kind: kind,
      storage: StorageMode.reference,
      title: _titleFromFileName(path),
      size: stat.size,
    );
    if (item.extension == '.epub') {
      final info = await covers.readEpubInfo(path);
      if (info != null) {
        item
          ..title = info.title ?? item.title
          ..author = info.author
          ..publisher = info.publisher
          ..isbn = info.isbn
          ..description = info.description;
      }
    }
    item.coverPath = await covers.generate(item);

    if (mode == StorageMode.managed && settings.libraryRoot != null) {
      item.path = await Organizer.apply(item, settings.libraryRoot!, settings.organizePattern, move: settings.moveFiles);
      item.storage = StorageMode.managed;
      if (item.kind == MediaKind.image) item.coverPath = item.path;
    }
    if (await db.exists(item.path)) return false;
    item.id = await db.insert(item);
    _items.insert(0, item);
    return true;
  }

  static String _titleFromFileName(String path) => p
      .basenameWithoutExtension(path)
      .replaceAll(RegExp(r'[_.]+'), ' ')
      .replaceAll(RegExp(r'\s+'), ' ')
      .trim();

  // ---------------- 편집 ----------------

  Future<void> save(MediaItem item) async {
    await db.update(item);
    notifyListeners();
  }

  /// 뷰어가 읽던 위치를 저장 (자주 불리므로 화면 갱신은 하지 않음)
  Future<void> saveProgress(MediaItem item, String position, double progress) async {
    item
      ..position = position
      ..progress = progress.clamp(0.0, 1.0)
      ..lastOpened = DateTime.now();
    await db.update(item);
  }

  /// 뷰어를 닫을 때 목록 갱신
  void refresh() => notifyListeners();

  Future<void> applyMetadata(MediaItem item, BookMetadata m) async {
    item
      ..title = m.title.isNotEmpty ? m.title : item.title
      ..author = m.author ?? item.author
      ..publisher = m.publisher ?? item.publisher
      ..isbn = m.isbn ?? item.isbn
      ..year = m.year ?? item.year
      ..description = m.description ?? item.description;
    if (m.coverUrl != null) {
      item.coverPath = await covers.download(m.coverUrl!, item.path) ?? item.coverPath;
    }
    await save(item);
  }

  Future<void> organize(MediaItem item, {required bool move}) async {
    final root = settings.libraryRoot;
    if (root == null) throw Exception('설정에서 라이브러리 폴더를 먼저 지정하세요.');
    final wasImageCover = item.coverPath == item.path;
    item.path = await Organizer.apply(item, root, settings.organizePattern, move: move);
    item.storage = StorageMode.managed;
    if (wasImageCover) item.coverPath = item.path;
    await save(item);
  }

  Future<void> remove(MediaItem item, {bool deleteFile = false}) async {
    if (deleteFile) {
      final f = File(item.path);
      if (await f.exists()) await f.delete();
    }
    await db.delete(item.id!);
    _items.remove(item);
    notifyListeners();
  }

  /// 원본이 사라진 항목 표시
  Future<void> checkMissing() async {
    for (final e in _items) {
      final missing = !await File(e.path).exists();
      if (missing != e.missing) {
        e.missing = missing;
        await db.update(e);
      }
    }
    notifyListeners();
  }

  /// 같은 이름+크기 파일 → 중복 후보
  List<List<MediaItem>> findDuplicates() {
    final map = <String, List<MediaItem>>{};
    for (final e in _items) {
      map.putIfAbsent('${e.fileName.toLowerCase()}|${e.size}', () => []).add(e);
    }
    return map.values.where((g) => g.length > 1).toList();
  }
}
