import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;

import 'db/library_db.dart';
import 'models/entry.dart';
import 'models/media_item.dart';
import 'models/series.dart';
import 'services/ai_service.dart';
import 'services/auth.dart';
import 'services/cover_service.dart';
import 'services/metadata_service.dart';
import 'services/organizer.dart';
import 'services/series_parser.dart';
import 'services/settings.dart';

enum SortBy { added, recent, title, author, rating }

/// 모아보기 (왼쪽 사이드바)
enum Collection { none, favorites, recent, reading, finished, recentAdded, missing }

String collectionLabel(Collection c) => switch (c) {
      Collection.none => '',
      Collection.favorites => '즐겨찾기',
      Collection.recent => '최근 읽음',
      Collection.reading => '읽는 중',
      Collection.finished => '다 읽음',
      Collection.recentAdded => '최근 추가됨',
      Collection.missing => '누락 권수 확인',
    };

/// 목록 보기 방식 (아래 상태 막대)
enum ViewMode { table, grid, cards }

typedef NavState = ({int? series, Collection col, MediaKind? kind, bool landing, String? lib});

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

  /// 첫 화면(넷플릭스풍 배너 + 가로 줄) 보기 중인지. 종류를 고르거나 검색하면 격자 보기로.
  bool landing = true;

  /// 모아보기 (즐겨찾기 / 최근 읽음 …)
  Collection collection = Collection.none;

  /// 하위 묶음까지 펼쳐서 모든 권 보기
  bool recursive = false;

  /// 라이브러리 폴더 하나만 보기 (사이드바 "라이브러리")
  String? libraryPath;

  void setLibrary(String path) {
    _push();
    libraryPath = path;
    collection = Collection.none;
    currentSeriesId = null;
    landing = false;
    selected.clear();
    focusedKey = null;
    notifyListeners();
  }

  /// 폴더 안 (하위 폴더 수, 파일 수)
  (int, int) libraryCounts(String root) {
    final dirs = <String>{};
    var files = 0;
    final sep = Platform.pathSeparator;
    final prefix = root.endsWith(sep) ? root : '$root$sep';
    for (final e in allItems) {
      if (!e.path.startsWith(prefix)) continue;
      files++;
      final d = p.dirname(e.path);
      if (d != root) dirs.add(d);
    }
    return (dirs.length, files);
  }

  /// 한 번 눌러 고른 칸 (아래 상세 패널에 표시)
  String? focusedKey;

  // ---------------- 뒤로 / 앞으로 ----------------
  final _back = <NavState>[];
  final _fwd = <NavState>[];
  NavState get _nav => (series: currentSeriesId, col: collection, kind: kindFilter, landing: landing, lib: libraryPath);
  void _push() {
    final n = _nav;
    if (_back.isNotEmpty && _back.last == n) return;
    _back.add(n);
    if (_back.length > 100) _back.removeAt(0);
    _fwd.clear();
  }

  void _apply(NavState n) {
    currentSeriesId = n.series;
    collection = n.col;
    kindFilter = n.kind;
    landing = n.landing;
    libraryPath = n.lib;
    selected.clear();
    focusedKey = null;
  }

  bool get canBack => _back.isNotEmpty;
  bool get canForward => _fwd.isNotEmpty;
  void goBack() {
    if (_back.isEmpty) return;
    _fwd.add(_nav);
    _apply(_back.removeLast());
    notifyListeners();
  }

  void goForward() {
    if (_fwd.isEmpty) return;
    _back.add(_nav);
    _apply(_fwd.removeLast());
    notifyListeners();
  }

  void setCollection(Collection c) {
    _push();
    collection = c;
    libraryPath = null;
    currentSeriesId = null;
    landing = false;
    selected.clear();
    focusedKey = null;
    notifyListeners();
  }

  void setRecursive(bool v) {
    recursive = v;
    notifyListeners();
  }

  /// 한 번 클릭: 고르기(상세 표시). 다중 선택은 Ctrl+클릭
  void focus(Entry e) {
    focusedKey = e.key;
    selected
      ..clear()
      ..add(e.key);
    notifyListeners();
  }

  Entry? get focusedEntry {
    final k = focusedKey;
    if (k == null) return null;
    return entries.where((e) => e.key == k).firstOrNull;
  }

  int collectionCount(Collection c) => _collectionEntries(c).length;

  List<Entry> _collectionEntries(Collection c) {
    final items = allItems.where(_passes);
    int byOpened(MediaItem a, MediaItem b) =>
        (b.lastOpened?.millisecondsSinceEpoch ?? 0).compareTo(a.lastOpened?.millisecondsSinceEpoch ?? 0);
    switch (c) {
      case Collection.none:
        return [];
      case Collection.favorites:
        return items.where((e) => e.favorite).map<Entry>(ItemEntry.new).toList();
      case Collection.recent:
        return (items.where((e) => e.lastOpened != null).toList()..sort(byOpened)).take(100).map<Entry>(ItemEntry.new).toList();
      case Collection.reading:
        return (items.where((e) => e.progress > 0 && e.progress < 0.98).toList()..sort(byOpened)).map<Entry>(ItemEntry.new).toList();
      case Collection.finished:
        return (items.where((e) => e.progress >= 0.98).toList()..sort(byOpened)).map<Entry>(ItemEntry.new).toList();
      case Collection.recentAdded:
        return (items.toList()..sort((a, b) => b.addedAt.compareTo(a.addedAt))).take(200).map<Entry>(ItemEntry.new).toList();
      case Collection.missing:
        // 전체 권수를 아는데 다 갖고 있지 않은 묶음
        return _series.values
            .where(canSeeSeries)
            .where((s) => s.total != null && statsOf(s).direct < s.total!)
            .map<Entry>((s) => SeriesEntry(s, statsOf(s)))
            .toList()
          ..sort((a, b) => (a as SeriesEntry).series.title.compareTo((b as SeriesEntry).series.title));
    }
  }

  /// 현재 묶음 아래 모든 권 (하위 묶음 포함)
  List<MediaItem> _itemsBelowVisible(int? seriesId) {
    final t = tree;
    final out = <MediaItem>[];
    void walk(int? id) {
      out.addAll(t.items[id] ?? const <MediaItem>[]);
      for (final c in t.children[id] ?? const <Series>[]) {
        walk(c.id);
      }
    }

    walk(seriesId);
    return out;
  }

  // ---------------- 쪽수 / 평점 ----------------

  /// 쪽수를 모르면 파일을 열어 세고 저장 (만화 zip, PDF)
  Future<void> ensurePages(MediaItem e) async {
    if (e.pages != null) return;
    final n = await covers.pageCount(e);
    if (n == null) return;
    e.pages = n;
    await db.update(e);
    notifyListeners();
  }

  /// 평점 0~10 (별 반 개 = 1점)
  Future<void> setRating(MediaItem e, int r) async {
    e.rating = r.clamp(0, 10);
    await db.update(e);
    notifyListeners();
  }

  Future<void> markFinished(MediaItem e, bool finished) async {
    await saveProgress(e, finished ? (e.position ?? '0') : '0', finished ? 1 : 0);
    notifyListeners();
  }

  /// 다중 선택 ('s:묶음id' / 'i:항목id')
  final Set<String> selected = {};

  // ---------------- 사용자 / 숨김 ----------------
  AppUser? user;
  List<AppUser> users = [];

  /// 숨김 목록이 열려 있는지 (앱을 끄면 항상 false 로 시작)
  bool hiddenUnlocked = false;

  /// 현재 사용자에게 막힌 대상 ('s:id' / 'i:id')
  Set<String> _denied = {};

  /// 열려 있는 뷰어별 기록 줄 번호 (item id → history id)
  final Map<int, int> _openHistory = {};
  MediaKind? kindFilter; // null = 전체
  bool favoritesOnly = false;
  String query = '';
  String? tagFilter;
  SortBy sortBy = SortBy.added;

  bool scanning = false;
  String scanStatus = '';

  Future<void> load() async {
    users = await db.users();
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
  LibraryTree get tree => _tree ??= LibraryTree.build(
        _items.where(canSeeItem).toList(),
        _series.values.where(canSeeSeries),
      );

  /// 보이기 규칙을 무시한 전체 트리 (내부 정리용)
  LibraryTree get rawTree => LibraryTree.build(_items, _series.values);

  // =====================================================================
  //  로그인
  // =====================================================================

  bool get needsSetup => users.isEmpty;
  bool get isAdmin => user?.isAdmin ?? false;

  /// 첫 실행: 관리자 계정 만들기
  Future<void> createFirstAdmin(String name, String pw) async {
    final u = AppUser(name: name.trim(), role: UserRole.admin)..setPassword(pw);
    u.id = await db.insertUser(u);
    await db.adoptLegacyProgress(u.id!);
    users = await db.users();
    await _enter(u);
  }

  Future<bool> login(AppUser u, String pw) async {
    if (!u.check(pw)) return false;
    await _enter(u);
    return true;
  }

  Future<void> _enter(AppUser u) async {
    user = u;
    settings.lastUserId = u.id;
    hiddenUnlocked = false;
    currentSeriesId = null;
    landing = true;
    selected.clear();
    _denied = u.isAdmin ? {} : await db.deniedFor(u.id!);
    // 이 사용자의 읽은 위치로 바꿔 끼우기
    final prog = await db.progressFor(u.id!);
    for (final e in _items) {
      final p = prog[e.id];
      e
        ..progress = p?.$1 ?? 0
        ..position = p?.$2
        ..lastOpened = p?.$3 == null ? null : DateTime.fromMillisecondsSinceEpoch(p!.$3!);
    }
    notifyListeners();
  }

  void logout() {
    user = null;
    hiddenUnlocked = false;
    query = '';
    selected.clear();
    notifyListeners();
  }

  // ---------------- 사용자 관리 (관리자) ----------------

  Future<void> addUser(String name, String pw, UserRole role) async {
    final u = AppUser(name: name.trim(), role: role)..setPassword(pw);
    await db.insertUser(u);
    users = await db.users();
    notifyListeners();
  }

  Future<void> updateUser(AppUser u, {String? newPassword}) async {
    if (newPassword != null) u.setPassword(newPassword);
    await db.updateUser(u);
    users = await db.users();
    notifyListeners();
  }

  Future<void> deleteUser(AppUser u) async {
    await db.deleteUser(u.id!);
    users = await db.users();
    notifyListeners();
  }

  Future<Set<String>> deniedOf(AppUser u) => db.deniedFor(u.id!);

  Future<void> setAccess(AppUser u, Iterable<String> targets, {required bool allowed}) async {
    for (final t in targets) {
      await db.setDenied(u.id!, t, !allowed);
    }
    if (u.id == user?.id && !u.isAdmin) _denied = await db.deniedFor(u.id!);
    notifyListeners();
  }

  // =====================================================================
  //  보이기 규칙: 접근 권한(사용자별) + 숨김(비밀번호)
  // =====================================================================

  /// 이 묶음 또는 상위 묶음 중 하나라도 조건을 만족하는가
  bool _anyAncestor(int? seriesId, bool Function(Series) test) {
    final seen = <int>{};
    var cur = seriesId;
    while (cur != null && seen.add(cur)) {
      final s = _series[cur];
      if (s == null) return false;
      if (test(s)) return true;
      cur = s.parentId;
    }
    return false;
  }

  bool isHiddenItem(MediaItem e) => e.hidden || _anyAncestor(e.seriesId, (s) => s.hidden);
  bool isHiddenSeries(Series s) => _anyAncestor(s.id, (x) => x.hidden);

  bool canAccessItem(MediaItem e) =>
      _denied.isEmpty || (!_denied.contains('i:${e.id}') && !_anyAncestor(e.seriesId, (s) => _denied.contains('s:${s.id}')));
  bool canAccessSeries(Series s) => _denied.isEmpty || !_anyAncestor(s.id, (x) => _denied.contains('s:${x.id}'));

  bool canSeeItem(MediaItem e) => user != null && canAccessItem(e) && (hiddenUnlocked || !isHiddenItem(e));
  bool canSeeSeries(Series s) => user != null && canAccessSeries(s) && (hiddenUnlocked || !isHiddenSeries(s));

  bool get hasHiddenPassword => settings.hiddenPwHash.isNotEmpty;

  /// 검색창에 숨김 비밀번호를 입력하고 Enter → 숨김 목록 열기
  bool trySearchUnlock(String text) {
    if (!hasHiddenPassword || text.isEmpty) return false;
    if (!PasswordHash.verify(text, settings.hiddenPwSalt, settings.hiddenPwHash)) return false;
    hiddenUnlocked = true;
    query = '';
    notifyListeners();
    return true;
  }

  void lockHidden() {
    hiddenUnlocked = false;
    selected.clear();
    if (currentSeries != null && !canSeeSeries(currentSeries!)) currentSeriesId = null;
    notifyListeners();
  }

  void setHiddenPassword(String pw) {
    final salt = PasswordHash.newSalt();
    settings.setHiddenPw(PasswordHash.hash(pw, salt), salt);
  }

  /// 숨김 켜기/끄기 (관리자). 파일도 OS 에서 숨김 속성으로 바꾼다.
  Future<void> setHidden({Iterable<MediaItem> items = const [], Iterable<Series> series = const [], required bool hidden}) async {
    final affected = <MediaItem>{};
    for (final e in items) {
      e.hidden = hidden;
      await db.update(e);
      affected.add(e);
    }
    for (final s in series) {
      s.hidden = hidden;
      await db.updateSeries(s);
      affected.addAll(_itemsUnder(s.id!));
    }
    await _syncOsHidden(affected);
    if (hidden && !hiddenUnlocked) selected.clear();
    notifyListeners();
  }

  /// 묶음 아래 모든 권 (하위 묶음 포함, 보이기 규칙 무시)
  List<MediaItem> _itemsUnder(int seriesId) {
    final ids = <int>{seriesId};
    var grew = true;
    while (grew) {
      grew = false;
      for (final s in _series.values) {
        if (s.parentId != null && ids.contains(s.parentId) && ids.add(s.id!)) grew = true;
      }
    }
    return _items.where((e) => ids.contains(e.seriesId)).toList();
  }

  /// 실제 파일의 숨김 속성 맞추기 (Windows: attrib, macOS: chflags)
  Future<void> _syncOsHidden(Iterable<MediaItem> items) async {
    for (final e in items) {
      final h = isHiddenItem(e);
      try {
        if (Platform.isWindows) {
          await Process.run('attrib.exe', [h ? '+h' : '-h', e.path]);
        } else if (Platform.isMacOS) {
          await Process.run('chflags', [h ? 'hidden' : 'nohidden', e.path]);
        }
        // Android / Linux 는 파일 숨김 속성이 없어 앱 안에서만 숨김
      } catch (_) {}
    }
  }

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
    if (id != currentSeriesId || collection != Collection.none) _push();
    currentSeriesId = id;
    collection = Collection.none;
    libraryPath = null;
    focusedKey = null;
    if (id != null) landing = false;
    selected.clear();
    notifyListeners();
  }

  /// 한 단계 위로. 이미 맨 위면 false
  bool goUp() {
    if (currentSeriesId == null) return false;
    final parent = currentSeries?.parentId;
    // 맨 위로 나오면, 필터 없이 들어왔던 경우 첫 화면으로
    if (parent == null && kindFilter == null && !flatMode) landing = true;
    enterSeries(parent);
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
    if (collection != Collection.none) return _collectionEntries(collection);
    final lib = libraryPath;
    if (lib != null) {
      final sep = Platform.pathSeparator;
      final prefix = lib.endsWith(sep) ? lib : '$lib$sep';
      final q = query.toLowerCase();
      return (allItems
              .where((e) => e.path.startsWith(prefix) && _passes(e))
              .where((e) => q.isEmpty || e.title.toLowerCase().contains(q) || e.fileName.toLowerCase().contains(q))
              .toList()
            ..sort((a, b) => a.path.compareTo(b.path)))
          .map<Entry>(ItemEntry.new)
          .toList();
    }
    if (recursive && !flatMode) {
      final items = _itemsBelowVisible(currentSeriesId).where(_passes).toList()
        ..sort((a, b) {
          final c = seriesPath(a.seriesId).compareTo(seriesPath(b.seriesId));
          return c != 0 ? c : _byVolume(a, b);
        });
      return items.map<Entry>(ItemEntry.new).toList();
    }
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

  // ---------------- 첫 화면 줄들 ----------------

  /// 이어서 보기: 읽다 만 것 (최근 연 순)
  List<MediaItem> get continueWatching => allItems.where((e) => e.progress > 0.0 && e.progress < 0.98).toList()
    ..sort((a, b) => (b.lastOpened?.millisecondsSinceEpoch ?? 0).compareTo(a.lastOpened?.millisecondsSinceEpoch ?? 0));

  /// 맨 위 칸들(묶음 + 낱권) 중 [kind] 가 들어 있는 것, 최근 추가순
  List<Entry> rootEntries({MediaKind? kind, int limit = 24}) {
    final t = tree;
    final out = <(DateTime, Entry)>[];
    for (final s in t.children[null] ?? const <Series>[]) {
      final st = t.stats(s.id!, kind);
      if (st.allItems == 0) continue;
      out.add((st.latestAdded, SeriesEntry(s, st)));
    }
    for (final e in t.items[null] ?? const <MediaItem>[]) {
      if (kind != null && e.kind != kind) continue;
      out.add((e.addedAt, ItemEntry(e)));
    }
    out.sort((a, b) => b.$1.compareTo(a.$1));
    return out.take(limit).map((x) => x.$2).toList();
  }

  /// 첫 화면 큰 배너: 이어보던 것 → 가장 최근 묶음/항목
  Entry? get featured {
    final c = continueWatching.firstOrNull;
    if (c != null) {
      // 묶음에 속해 있으면 묶음을 대표로
      final s = seriesById(c.seriesId);
      if (s != null && canSeeSeries(s)) return SeriesEntry(s, statsOf(s));
      return ItemEntry(c);
    }
    return rootEntries(limit: 1).firstOrNull;
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
    await _syncOsHidden(items);
    notifyListeners();
  }

  /// 묶음을 다른 묶음 아래로 (자기 하위로는 못 옮김)
  Future<bool> moveSeries(Series s, int? parentId) async {
    if (parentId != null && isAncestor(s.id!, parentId)) return false;
    s.parentId = parentId;
    await db.updateSeries(s);
    await _syncOsHidden(_itemsUnder(s.id!));
    notifyListeners();
    return true;
  }

  /// 묶음 해제: 안에 있던 권/하위 묶음은 한 단계 위로
  Future<void> deleteSeries(Series s) async {
    final raw = rawTree;
    for (final e in [...?raw.items[s.id]]) {
      e
        ..seriesId = s.parentId
        ..series = seriesById(s.parentId)?.title;
      await db.update(e);
    }
    for (final c in [...?raw.children[s.id]]) {
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
        if (s != null && canSeeSeries(s)) ss.add(s);
      } else {
        final i = _items.where((e) => e.id == id && canSeeItem(e)).firstOrNull;
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
    var raw = rawTree;
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
        final direct = raw.items[s.id] ?? const <MediaItem>[];
        if (direct.isEmpty) return raw.children[s.id]?.isEmpty ?? true;
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
        raw = rawTree;
      }
      for (final (e, n) in g) {
        e
          ..seriesId = s.id
          ..series = s.title
          ..volume ??= n.volume;
        await db.update(e);
        moved++;
      }
      await _syncOsHidden(g.map((x) => x.$1));
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
      final raw = rawTree;
      // base 가 이미 대표 묶음(하위 묶음만 가짐)이면 그 아래로, 아니면 대표 묶음을 새로 만든다
      final baseIsUmbrella = (raw.items[base.id]?.isEmpty ?? true) && (raw.children[base.id]?.isNotEmpty ?? false);
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

  /// 지금 사용자에게 보이는 항목 전부 (AI, 중복 확인 등에 사용 — 숨김/차단 제외)
  List<MediaItem> get allItems => _items.where(canSeeItem).toList();

  List<MediaItem> get visible {
    final q = query.toLowerCase();
    final list = _items.where(canSeeItem).where((e) {
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

  Set<String> get allTags => {for (final e in allItems) ...e.tags};

  int count(MediaKind? k) {
    final all = allItems;
    return k == null ? all.length : all.where((e) => e.kind == k).length;
  }

  /// 첫 화면으로
  void showLanding() {
    _push();
    collection = Collection.none;
    libraryPath = null;
    focusedKey = null;
    landing = true;
    currentSeriesId = null;
    kindFilter = null;
    favoritesOnly = false;
    tagFilter = null;
    query = '';
    selected.clear();
    notifyListeners();
  }

  void setFilter({MediaKind? kind, bool clearKind = false, bool? favorites, String? tag, bool clearTag = false}) {
    if (kind != kindFilter || clearKind || landing) _push();
    if (kind != null || clearKind) {
      collection = Collection.none;
      libraryPath = null;
    }
    landing = false;
    if (clearKind) kindFilter = null;
    if (kind != null) kindFilter = kind;
    if (favorites != null) favoritesOnly = favorites;
    if (clearTag) tagFilter = null;
    if (tag != null) tagFilter = tag;
    notifyListeners();
  }

  void setQuery(String q) {
    query = q;
    if (q.isNotEmpty) landing = false;
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

  /// 폴더를 하위까지 훑어 지원하는 파일을 등록한다.
  /// 결과를 숫자로 알려준다 (권한 문제로 아무것도 못 읽은 경우를 알아보기 위해).
  Future<void> scanFolders(List<String> dirs) async {
    if (scanning) return;
    scanning = true;
    var found = 0, added = 0, failed = 0, dirErrors = 0, missingDirs = 0, entries = 0;
    try {
      for (final dir in dirs) {
        final d = Directory(dir);
        if (!await d.exists()) {
          missingDirs++;
          continue;
        }
        await for (final ent in d.list(recursive: true, followLinks: false).handleError((_) => dirErrors++)) {
          entries++;
          if (ent is! File) continue;
          if (kindForPath(ent.path) == null) continue;
          found++;
          scanStatus = '스캔 중 ($found): ${p.basename(ent.path)}';
          notifyListeners();
          try {
            if (await _importFile(ent.path, StorageMode.reference)) added++;
          } catch (_) {
            failed++; // 한 파일이 이상해도 나머지는 계속
          }
        }
      }
      await checkMissing();
      final grouped = added > 0 && settings.autoGroup ? await autoGroup() : 0;
      final parts = [
        '찾은 파일 $found개',
        '새로 등록 $added개',
        if (grouped > 0) '$grouped개 시리즈로 묶음',
        if (failed > 0) '실패 $failed개',
        if (missingDirs > 0) '없는 폴더 $missingDirs개',
      ];
      scanStatus = '완료: ${parts.join(' · ')}';
      if (found == 0 && (entries == 0 || dirErrors > 0) && Platform.isAndroid) {
        scanStatus += '  — 폴더 안을 읽지 못했습니다. 저장소 권한("모든 파일 관리 허용")을 확인하세요.';
      }
    } catch (e) {
      scanStatus = '스캔 중 오류: $e';
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
        try {
          if (await _importFile(path, settings.defaultStorage)) added++;
        } catch (_) {}
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
    item.pages = await covers.pageCount(item);

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
    final u = user;
    if (u == null || item.id == null) return;
    await db.saveProgress(u.id!, item);
    // 열람 기록: 뷰어를 열 때 한 줄 만들고, 볼 때마다 그 줄을 갱신
    final hid = _openHistory[item.id!] ??= await db.startHistory(u.id!, item.id!);
    await db.updateHistory(hid, item.progress, position);
  }

  /// 뷰어를 열 때 호출 → 새 기록 줄 시작
  Future<void> beginView(MediaItem item) async {
    final u = user;
    if (u == null || item.id == null) return;
    _openHistory[item.id!] = await db.startHistory(u.id!, item.id!);
  }

  Future<List<(HistoryRecord, MediaItem)>> historyList() async {
    final u = user;
    if (u == null) return [];
    final byId = {for (final e in _items) e.id: e};
    return [
      for (final h in await db.history(u.id!))
        if (byId[h.itemId] case final e? when canSeeItem(e)) (h, e),
    ];
  }

  Future<void> clearHistory() async {
    if (user != null) await db.clearHistory(user!.id!);
    notifyListeners();
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

  Future<void> remove(MediaItem item, {bool deleteFile = false}) => removeMany(items: [item], deleteFile: deleteFile);

  /// 삭제: 항목들과 묶음들(안에 든 것 전부)을 라이브러리에서 뺀다.
  /// [deleteFile] 이 true 면 실제 파일도 지운다. 반환: 지우지 못한 파일 수
  Future<int> removeMany({Iterable<MediaItem> items = const [], Iterable<Series> series = const [], bool deleteFile = false}) async {
    final targets = <MediaItem>{...items};
    final seriesIds = <int>{};
    for (final s in series) {
      targets.addAll(_itemsUnder(s.id!));
      seriesIds.add(s.id!);
      // 하위 묶음까지
      var grew = true;
      while (grew) {
        grew = false;
        for (final c in _series.values) {
          if (c.parentId != null && seriesIds.contains(c.parentId) && seriesIds.add(c.id!)) grew = true;
        }
      }
    }
    var failed = 0;
    for (final e in targets) {
      if (deleteFile) {
        try {
          final f = File(e.path);
          if (Platform.isWindows) await Process.run('attrib.exe', ['-h', '-r', e.path]); // 숨김/읽기전용 풀고 삭제
          if (await f.exists()) await f.delete();
        } catch (_) {
          failed++;
          continue; // 파일을 못 지웠으면 목록에도 남겨둔다
        }
      }
      await db.delete(e.id!);
      _items.remove(e);
    }
    for (final id in seriesIds) {
      await db.deleteSeries(id);
      _series.remove(id);
    }
    if (currentSeriesId != null && !_series.containsKey(currentSeriesId)) currentSeriesId = null;
    selected.clear();
    notifyListeners();
    return failed;
  }

  /// 선택한 것 삭제
  Future<int> removeSelected({required bool deleteFile}) {
    final (ss, ii) = _selection();
    return removeMany(items: ii, series: ss, deleteFile: deleteFile);
  }

  /// 선택한 것 숨김/해제
  Future<void> hideSelected(bool hidden) {
    final (ss, ii) = _selection();
    return setHidden(items: ii, series: ss, hidden: hidden);
  }

  /// 선택한 것의 'i:id' / 's:id' 목록 (접근 권한 설정용)
  List<String> get selectedTargets => selected.toList();

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
    for (final e in allItems) {
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
