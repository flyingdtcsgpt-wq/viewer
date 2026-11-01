import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;

import 'db/library_db.dart';
import 'models/entry.dart';
import 'models/media_item.dart';
import 'models/series.dart';
import 'services/ai_service.dart';
import 'services/cover_service.dart';
import 'services/metadata_service.dart';
import 'services/organizer.dart';
import 'services/series_parser.dart';
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
  final Map<int, Series> _series = {};

  /// 지금 들어와 있는 묶음 (null = 맨 위)
  int? currentSeriesId;

  /// 다중 선택 ('s:묶음id' / 'i:항목id')
  final Set<String> selected = {};
  MediaKind? kindFilter; // null = 전체
  bool favoritesOnly = false;
  String query = '';
  String? tagFilter;
  SortBy sortBy = SortBy.added;

  bool scanning = false;
  String scanStatus = '';

  Future<void> load() async {
    _items = await db.all();
    _series
      ..clear()
      ..addEntries((await db.allSeries()).map((s) => MapEntry(s.id!, s)));
    notifyListeners();
  }

  @override
  void notifyListeners() {
    _tree = null; // 묶음 색인 다시 만들기
    super.notifyListeners();
  }

  // =====================================================================
  //  묶음(시리즈) 트리
  // =====================================================================

  LibraryTree? _tree;
  LibraryTree get tree => _tree ??= LibraryTree.build(_items, _series.values);

  Series? seriesById(int? id) => id == null ? null : _series[id];
  Series? get currentSeries => seriesById(currentSeriesId);
  List<Series> get allSeries => _series.values.toList()..sort((a, b) => a.title.compareTo(b.title));

  /// 맨 위 → 현재 묶음까지
  List<Series> get breadcrumb {
    final out = <Series>[];
    var s = currentSeries;
    final seen = <int>{};
    while (s != null && seen.add(s.id!)) {
      out.insert(0, s);
      s = seriesById(s.parentId);
    }
    return out;
  }

  /// 묶음 경로 문자열 "명탐정 코난 › 외전"
  String seriesPath(int? id) {
    final names = <String>[];
    var s = seriesById(id);
    final seen = <int>{};
    while (s != null && seen.add(s.id!)) {
      names.insert(0, s.title);
      s = seriesById(s.parentId);
    }
    return names.join(' › ');
  }

  void enterSeries(int? id) {
    currentSeriesId = id;
    selected.clear();
    notifyListeners();
  }

  /// 한 단계 위로. 이미 맨 위면 false
  bool goUp() {
    if (currentSeriesId == null) return false;
    enterSeries(currentSeries?.parentId);
    return true;
  }

  SeriesStats statsOf(Series s) => tree.stats(s.id!, kindFilter);

  bool _passes(MediaItem e) {
    if (kindFilter != null && e.kind != kindFilter) return false;
    if (favoritesOnly && !e.favorite) return false;
    if (tagFilter != null && !e.tags.contains(tagFilter)) return false;
    return true;
  }

  /// 검색/즐겨찾기/태그 필터 중이면 묶음 없이 평평하게 보여준다
  bool get flatMode => query.isNotEmpty || favoritesOnly || tagFilter != null;

  /// 그리드에 보일 칸들
  List<Entry> get entries {
    if (flatMode) {
      final q = query.toLowerCase();
      final series = q.isEmpty
          ? <Entry>[]
          : _series.values
              .where((s) => s.title.toLowerCase().contains(q) && statsOf(s).allItems > 0)
              .map<Entry>((s) => SeriesEntry(s, statsOf(s)))
              .toList();
      return [...series, ...visible.map(ItemEntry.new)];
    }
    final t = tree;
    final seriesEntries = (t.children[currentSeriesId] ?? const <Series>[])
        .map((s) => SeriesEntry(s, statsOf(s)))
        .where((e) => kindFilter == null || e.stats.allItems > 0)
        .toList();
    final items = (t.items[currentSeriesId] ?? const <MediaItem>[]).where(_passes).toList();

    if (currentSeriesId != null) {
      // 묶음 안: 하위 묶음은 제목순, 권은 번호순
      seriesEntries.sort((a, b) => a.series.title.compareTo(b.series.title));
      items.sort(_byVolume);
      return [...seriesEntries, ...items.map(ItemEntry.new)];
    }
    // 맨 위: 묶음과 낱권을 같은 기준으로 정렬
    final all = <Entry>[...seriesEntries, ...items.map(ItemEntry.new)];
    DateTime added(Entry e) => switch (e) {
          SeriesEntry s => s.stats.latestAdded,
          ItemEntry i => i.item.addedAt,
        };
    int opened(Entry e) => switch (e) {
          SeriesEntry s => s.stats.lastOpened?.millisecondsSinceEpoch ?? 0,
          ItemEntry i => i.item.lastOpened?.millisecondsSinceEpoch ?? 0,
        };
    String title(Entry e) => switch (e) {
          SeriesEntry s => s.series.title,
          ItemEntry i => i.item.title,
        };
    String author(Entry e) => switch (e) {
          SeriesEntry s => s.series.author ?? '',
          ItemEntry i => i.item.author ?? '',
        };
    int rating(Entry e) => switch (e) {
          SeriesEntry _ => 0,
          ItemEntry i => i.item.rating,
        };
    switch (sortBy) {
      case SortBy.added:
        all.sort((a, b) => added(b).compareTo(added(a)));
      case SortBy.recent:
        all.sort((a, b) => opened(b).compareTo(opened(a)));
      case SortBy.title:
        all.sort((a, b) => title(a).compareTo(title(b)));
      case SortBy.author:
        all.sort((a, b) => author(a).compareTo(author(b)));
      case SortBy.rating:
        all.sort((a, b) => rating(b).compareTo(rating(a)));
    }
    return all;
  }

  static int _byVolume(MediaItem a, MediaItem b) {
    final va = a.volume, vb = b.volume;
    if (va != null && vb != null && va != vb) return va.compareTo(vb);
    if (va != null && vb == null) return -1;
    if (va == null && vb != null) return 1;
    return a.title.compareTo(b.title);
  }

  /// 묶음 안의 권들 (번호순, 하위 묶음 제외)
  List<MediaItem> volumesOf(int seriesId) => [...?tree.items[seriesId]]..sort(_byVolume);

  /// 다음에 읽을 권: 읽다 만 권 → 안 읽은 첫 권
  MediaItem? nextToRead(int seriesId) {
    final vols = volumesOf(seriesId);
    return vols.where((e) => e.progress > 0 && e.progress < 0.98).firstOrNull ??
        vols.where((e) => e.progress < 0.98).firstOrNull ??
        vols.firstOrNull;
  }

  /// 같은 묶음의 다음 권 (뷰어에서 "다음 권")
  MediaItem? nextVolume(MediaItem item) {
    if (item.seriesId == null) return null;
    final vols = volumesOf(item.seriesId!);
    final i = vols.indexOf(item);
    return i >= 0 && i + 1 < vols.length ? vols[i + 1] : null;
  }

  // ---------------- 묶음 편집 ----------------

  Future<Series> createSeries(String title, {int? parentId, SeriesStatus status = SeriesStatus.unknown}) async {
    final s = Series(title: title.trim(), parentId: parentId, status: status);
    s.id = await db.insertSeries(s);
    _series[s.id!] = s;
    notifyListeners();
    return s;
  }

  Future<void> saveSeries(Series s) async {
    await db.updateSeries(s);
    notifyListeners();
  }

  /// [ancestor] 가 [id] 의 상위(또는 자기 자신)인가
  bool isAncestor(int ancestor, int? id) {
    final seen = <int>{};
    var cur = id;
    while (cur != null && seen.add(cur)) {
      if (cur == ancestor) return true;
      cur = _series[cur]?.parentId;
    }
    return false;
  }

  Future<void> moveItems(Iterable<MediaItem> items, int? seriesId) async {
    final s = seriesById(seriesId);
    for (final e in items) {
      e
        ..seriesId = seriesId
        ..series = s?.title;
      e.volume ??= parseName(e.path).volume;
      await db.update(e);
    }
    notifyListeners();
  }

  /// 묶음을 다른 묶음 아래로 (자기 하위로는 못 옮김)
  Future<bool> moveSeries(Series s, int? parentId) async {
    if (parentId != null && isAncestor(s.id!, parentId)) return false;
    s.parentId = parentId;
    await db.updateSeries(s);
    notifyListeners();
    return true;
  }

  /// 묶음 해제: 안에 있던 권/하위 묶음은 한 단계 위로
  Future<void> deleteSeries(Series s) async {
    for (final e in [...?tree.items[s.id]]) {
      e
        ..seriesId = s.parentId
        ..series = seriesById(s.parentId)?.title;
      await db.update(e);
    }
    for (final c in [...?tree.children[s.id]]) {
      c.parentId = s.parentId;
      await db.updateSeries(c);
    }
    await db.deleteSeries(s.id!);
    _series.remove(s.id);
    if (currentSeriesId == s.id) currentSeriesId = s.parentId;
    notifyListeners();
  }

  // ---------------- 선택 ----------------

  bool get selecting => selected.isNotEmpty;

  void toggleSelect(Entry e) {
    if (!selected.remove(e.key)) selected.add(e.key);
    notifyListeners();
  }

  void clearSelection() {
    selected.clear();
    notifyListeners();
  }

  void selectAll() {
    selected.addAll(entries.map((e) => e.key));
    notifyListeners();
  }

  (List<Series>, List<MediaItem>) _selection() {
    final ss = <Series>[], ii = <MediaItem>[];
    for (final k in selected) {
      final id = int.parse(k.substring(2));
      if (k.startsWith('s:')) {
        final s = _series[id];
        if (s != null) ss.add(s);
      } else {
        final i = _items.where((e) => e.id == id).firstOrNull;
        if (i != null) ii.add(i);
      }
    }
    return (ss, ii);
  }

  /// 선택한 것들로 새 묶음 만들기 (현재 위치에)
  Future<Series> groupSelected(String title) async {
    final (ss, ii) = _selection();
    final g = await createSeries(title, parentId: currentSeriesId);
    for (final s in ss) {
      await moveSeries(s, g.id);
    }
    await moveItems(ii, g.id);
    selected.clear();
    notifyListeners();
    return g;
  }

  /// 선택한 것들을 다른 묶음으로 (null = 맨 위)
  Future<int> moveSelected(int? target) async {
    final (ss, ii) = _selection();
    var failed = 0;
    for (final s in ss) {
      if (!await moveSeries(s, target)) failed++;
    }
    await moveItems(ii, target);
    selected.clear();
    notifyListeners();
    return failed;
  }

  /// 선택한 것들을 현재 묶음에서 한 단계 위로 빼기
  Future<void> ungroupSelected() => moveSelected(currentSeries?.parentId);

  // ---------------- 자동 묶기 ----------------

  /// 파일명으로 시리즈를 찾아 묶는다.
  /// 1) 같은 제목 + 권 번호 → 한 묶음
  /// 2) "명탐정 코난" 과 "명탐정 코난 제로의 일상" 처럼 파생 시리즈 → 대표 묶음 아래로
  /// 반환: 묶인 항목 수
  Future<int> autoGroup() async {
    final candidates = _items.where((e) => e.seriesId == null && e.kind != MediaKind.image).toList();
    final groups = <String, List<(MediaItem, ParsedName)>>{};
    for (final e in candidates) {
      final pn = parseName(e.path);
      if (pn.title.isEmpty) continue;
      final key = '${e.kind == MediaKind.video ? 'v' : 'b'}|${normalizeTitle(pn.title)}';
      groups.putIfAbsent(key, () => []).add((e, pn));
    }

    // 같은 제목의 기존 묶음 찾기: 같은 매체(책/영상)의 권이 들어 있거나, 완전히 빈 묶음
    // (대표 묶음처럼 하위 묶음만 가진 것은 제외)
    Series? existing(String title, bool isVideo) {
      final n = normalizeTitle(title);
      return _series.values.where((s) {
        if (normalizeTitle(s.title) != n) return false;
        final direct = tree.items[s.id] ?? const <MediaItem>[];
        if (direct.isEmpty) return tree.children[s.id]?.isEmpty ?? true;
        return direct.any((e) => (e.kind == MediaKind.video) == isVideo);
      }).firstOrNull;
    }

    bool titleTaken(String title) => _series.values.any((s) => normalizeTitle(s.title) == normalizeTitle(title));

    var moved = 0;
    for (final g in groups.values) {
      final (first, pn) = g.first;
      final isVideo = first.kind == MediaKind.video;
      var s = existing(pn.title, isVideo);
      if (s == null) {
        final enough = g.length >= 2 || pn.explicitVolume;
        if (!enough) continue;
        // 같은 제목의 책 묶음이 이미 있으면 "(영상)" 을 붙여 구분 → 나중에 대표 묶음 아래로 모임
        final title = titleTaken(pn.title) ? '${pn.title} (${isVideo ? '영상' : '책'})' : pn.title;
        s = await createSeries(title, status: g.map((x) => x.$2.statusHint).firstWhere(
              (h) => h != SeriesStatus.unknown,
              orElse: () => SeriesStatus.unknown,
            ));
        s.author = first.author;
        await db.updateSeries(s);
      }
      for (final (e, n) in g) {
        e
          ..seriesId = s.id
          ..series = s.title
          ..volume ??= n.volume;
        await db.update(e);
        moved++;
      }
    }
    _tree = null;
    await _nestSpinOffs();
    notifyListeners();
    return moved;
  }

  /// 맨 위에 있는 "A" 와 "A 외전…" 을 대표 묶음 "A" 아래로 모은다
  Future<void> _nestSpinOffs() async {
    final roots = _series.values.where((s) => s.parentId == null).toList()
      ..sort((a, b) => a.title.length.compareTo(b.title.length));
    for (final base in roots) {
      if (base.parentId != null) continue; // 이번 루프에서 이미 옮겨짐
      final spinOffs = roots.where((o) => o.id != base.id && o.parentId == null && isSpinOffOf(base.title, o.title)).toList();
      if (spinOffs.isEmpty) continue;
      _tree = null;
      // base 가 이미 대표 묶음(하위 묶음만 가짐)이면 그 아래로, 아니면 대표 묶음을 새로 만든다
      final baseIsUmbrella = (tree.items[base.id]?.isEmpty ?? true) && (tree.children[base.id]?.isNotEmpty ?? false);
      Series umbrella = base;
      if (!baseIsUmbrella) {
        umbrella = await createSeries(base.title, status: SeriesStatus.unknown);
        umbrella.author = base.author;
        await db.updateSeries(umbrella);
        base.parentId = umbrella.id;
        await db.updateSeries(base);
      }
      for (final o in spinOffs) {
        o.parentId = umbrella.id;
        await db.updateSeries(o);
      }
    }
  }

  /// AI 로 총 권수/연재 상태/작가 채우기
  Future<void> fillSeriesWithAi(Series s) async {
    final r = await ai.seriesInfo(s.title, isVideo: statsOf(s).isVideo);
    final total = r['total'];
    if (total is num && total > 0) s.total = total.toInt();
    final st = SeriesStatus.values.asNameMap()[r['status']];
    if (st != null) s.status = st;
    if ((s.author ?? '').isEmpty && (r['author'] ?? '').toString().isNotEmpty) s.author = r['author'];
    if ((s.description ?? '').isEmpty && (r['description'] ?? '').toString().isNotEmpty) s.description = r['description'];
    await saveSeries(s);
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
          seriesPath(e.seriesId).toLowerCase().contains(q) ||
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
      final grouped = added > 0 && settings.autoGroup ? await autoGroup() : 0;
      scanStatus = '완료: 새 항목 $added개${grouped > 0 ? ' · $grouped개 시리즈로 묶음' : ''}';
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
      final grouped = added > 0 && settings.autoGroup ? await autoGroup() : 0;
      scanStatus = '완료: 새 항목 $added개${grouped > 0 ? ' · $grouped개 시리즈로 묶음' : ''}';
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

/// 묶음 색인: 부모 → 자식 묶음, 묶음 → 권
class LibraryTree {
  final Map<int?, List<Series>> children = {};
  final Map<int?, List<MediaItem>> items = {};
  final Map<String, SeriesStats> _stats = {};

  LibraryTree._();

  factory LibraryTree.build(List<MediaItem> all, Iterable<Series> series) {
    final t = LibraryTree._();
    final ids = series.map((s) => s.id).toSet();
    for (final s in series) {
      // 부모가 사라진 묶음은 맨 위로
      t.children.putIfAbsent(ids.contains(s.parentId) ? s.parentId : null, () => []).add(s);
    }
    for (final e in all) {
      t.items.putIfAbsent(ids.contains(e.seriesId) ? e.seriesId : null, () => []).add(e);
    }
    return t;
  }

  SeriesStats stats(int id, MediaKind? kind) => _stats.putIfAbsent('$id|${kind?.name}', () {
        final direct = (items[id] ?? const <MediaItem>[]).where((e) => kind == null || e.kind == kind).toList();
        final subs = children[id] ?? const <Series>[];
        var all = direct.length, finished = direct.where((e) => e.progress >= 0.98).length, videos = 0;
        var latest = DateTime.fromMillisecondsSinceEpoch(0);
        DateTime? opened;
        String? cover;
        final sortedDirect = [...direct]..sort(AppState._byVolume);
        cover = sortedDirect.map((e) => e.coverPath).whereType<String>().firstOrNull;
        for (final e in direct) {
          if (e.kind == MediaKind.video) videos++;
          if (e.addedAt.isAfter(latest)) latest = e.addedAt;
          if (e.lastOpened != null && (opened == null || e.lastOpened!.isAfter(opened))) opened = e.lastOpened;
        }
        var nonEmptySubs = 0;
        for (final c in subs) {
          final st = stats(c.id!, kind);
          if (st.allItems == 0 && kind != null) continue;
          nonEmptySubs++;
          all += st.allItems;
          finished += st.finished;
          if (st.isVideo) videos += st.allItems;
          if (st.latestAdded.isAfter(latest)) latest = st.latestAdded;
          if (st.lastOpened != null && (opened == null || st.lastOpened!.isAfter(opened))) opened = st.lastOpened;
          cover ??= c.coverPath ?? st.coverPath;
        }
        return SeriesStats(
          direct: direct.length,
          childSeries: nonEmptySubs,
          allItems: all,
          finished: finished,
          coverPath: cover,
          isVideo: all > 0 && videos * 2 >= all,
          latestAdded: latest,
          lastOpened: opened,
        );
      });
}
