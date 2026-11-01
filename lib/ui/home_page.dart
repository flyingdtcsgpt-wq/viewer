import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../app_state.dart';
import '../models/entry.dart';
import '../models/media_item.dart';
import '../services/settings.dart';
import 'admin_page.dart';
import 'ai_chat_sheet.dart';
import 'cover_tile.dart';
import 'detail_page.dart';
import 'history_page.dart';
import 'series_widgets.dart';
import 'settings_page.dart';
import 'viewers/open_item.dart';

const _kinds = <MediaKind?>[null, MediaKind.book, MediaKind.comic, MediaKind.image, MediaKind.video];
const _kindIcons = [Icons.apps, Icons.menu_book, Icons.auto_stories, Icons.image, Icons.movie];
String _kindName(MediaKind? k) => k == null ? '전체' : kindLabel(k);

/// 화면 폭에 따라 레이아웃 변경
///  - 넓은 화면(PC, 840 이상): 왼쪽 사이드바에 모든 메뉴, 오른쪽에 목록
///  - 좁은 화면(휴대폰/작은 창): 하단 탭 + 왼쪽 서랍 메뉴(사이드바와 같은 내용)
class HomePage extends StatelessWidget {
  const HomePage({super.key});

  @override
  Widget build(BuildContext context) {
    final state = context.watch<AppState>();
    final width = MediaQuery.sizeOf(context).width;
    final wide = width >= 840;
    final inSeries = state.currentSeriesId != null && !state.flatMode;
    final title = inSeries ? state.currentSeries!.title : _kindName(state.kindFilter);
    final back = state.currentSeriesId != null
        ? IconButton(tooltip: '위로 (Esc)', icon: const Icon(Icons.arrow_back), onPressed: state.goUp)
        : null;

    final body = Column(children: [
      state.selecting ? const SelectionBar() : _Toolbar(phone: width < 600),
      if (state.hiddenUnlocked) const _HiddenBanner(),
      if (state.scanning || state.scanStatus.isNotEmpty)
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
          child: Row(children: [
            if (state.scanning) const SizedBox(width: 14, height: 14, child: CircularProgressIndicator(strokeWidth: 2)),
            const SizedBox(width: 8),
            Expanded(child: Text(state.scanStatus, overflow: TextOverflow.ellipsis, style: Theme.of(context).textTheme.bodySmall)),
          ]),
        ),
      if (inSeries) const SeriesHeader(),
      const Expanded(child: _Grid()),
    ]);

    Widget page;
    if (wide) {
      page = Scaffold(
        body: SafeArea(
          child: Row(children: [
            const SizedBox(width: 260, child: Material(child: _Sidebar())),
            const VerticalDivider(width: 1),
            Expanded(
              child: Scaffold(
                appBar: AppBar(leading: back, automaticallyImplyLeading: false, title: Text(title, overflow: TextOverflow.ellipsis)),
                body: body,
              ),
            ),
          ]),
        ),
      );
    } else {
      page = Scaffold(
        appBar: AppBar(
          leading: back,
          title: Text(state.currentSeriesId != null ? title : 'MediaShelf', overflow: TextOverflow.ellipsis),
        ),
        drawer: const Drawer(child: SafeArea(child: _Sidebar(inDrawer: true))),
        body: body,
        bottomNavigationBar: NavigationBar(
          selectedIndex: _kinds.indexOf(state.kindFilter),
          onDestinationSelected: (i) => i == 0 ? state.setFilter(clearKind: true) : state.setFilter(kind: _kinds[i]),
          destinations: [
            for (var i = 0; i < _kinds.length; i++)
              NavigationDestination(icon: Icon(_kindIcons[i]), label: _kindName(_kinds[i])),
          ],
        ),
      );
    }

    // 안드로이드 뒤로가기 / Esc: 선택 해제 → 한 단계 위 묶음 → 앱 종료
    return PopScope(
      canPop: !state.selecting && state.currentSeriesId == null,
      onPopInvokedWithResult: (didPop, _) {
        if (didPop) return;
        if (state.selecting) {
          state.clearSelection();
        } else {
          state.goUp();
        }
      },
      child: CallbackShortcuts(
        bindings: {
          const SingleActivator(LogicalKeyboardKey.escape): () {
            if (state.selecting) {
              state.clearSelection();
            } else {
              state.goUp();
            }
          },
          const SingleActivator(LogicalKeyboardKey.backspace, alt: true): state.goUp,
        },
        child: Focus(autofocus: true, child: page),
      ),
    );
  }
}

// =====================================================================
//  왼쪽 사이드바 (PC) / 서랍 메뉴 (휴대폰)
// =====================================================================
class _Sidebar extends StatelessWidget {
  final bool inDrawer;
  const _Sidebar({this.inDrawer = false});

  @override
  Widget build(BuildContext context) {
    final state = context.watch<AppState>();
    final text = Theme.of(context).textTheme;
    final scheme = Theme.of(context).colorScheme;
    final admin = state.isAdmin;

    // 서랍에서 메뉴를 누르면 서랍 닫기
    VoidCallback act(VoidCallback f) => () {
          if (inDrawer) Navigator.pop(context);
          f();
        };
    void push(Widget page) => Navigator.push(context, MaterialPageRoute(builder: (_) => page));

    Widget item(IconData icon, String label, VoidCallback? onTap, {bool selected = false, String? trailing}) => ListTile(
          dense: true,
          visualDensity: VisualDensity.compact,
          selected: selected,
          selectedTileColor: scheme.secondaryContainer,
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(24)),
          leading: Icon(icon, size: 20),
          title: Text(label),
          trailing: trailing == null ? null : Text(trailing, style: text.bodySmall),
          onTap: onTap,
        );

    Widget section(String label) => Padding(
          padding: const EdgeInsets.fromLTRB(16, 16, 16, 4),
          child: Text(label, style: text.labelMedium?.copyWith(color: scheme.primary)),
        );

    final tags = state.allTags.toList()..sort();

    return ListView(padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 8), children: [
      // 앱 이름 + 사용자
      Padding(
        padding: const EdgeInsets.fromLTRB(12, 4, 4, 4),
        child: Row(children: [
          const Icon(Icons.local_library),
          const SizedBox(width: 8),
          Expanded(child: Text('MediaShelf', style: text.titleLarge)),
        ]),
      ),
      Card(
        margin: const EdgeInsets.symmetric(horizontal: 4, vertical: 4),
        child: ListTile(
          dense: true,
          leading: CircleAvatar(child: Icon(admin ? Icons.admin_panel_settings : Icons.person)),
          title: Text(state.user?.name ?? ''),
          subtitle: Text(admin ? '관리자' : '사용자'),
          trailing: IconButton(tooltip: '로그아웃', icon: const Icon(Icons.logout), onPressed: act(state.logout)),
        ),
      ),

      section('보기'),
      for (var i = 0; i < _kinds.length; i++)
        item(
          _kindIcons[i],
          _kindName(_kinds[i]),
          act(() {
            state.enterSeries(null);
            i == 0 ? state.setFilter(clearKind: true) : state.setFilter(kind: _kinds[i]);
          }),
          selected: state.kindFilter == _kinds[i],
          trailing: '${state.count(_kinds[i])}',
        ),
      item(Icons.history, '내 열람 기록', act(() => push(const HistoryPage()))),

      if (admin) ...[
        section('라이브러리 관리'),
        item(Icons.create_new_folder, '폴더 등록', act(() async {
          final dir = await FilePicker.getDirectoryPath(dialogTitle: '스캔할 폴더 선택');
          if (dir != null) await state.addWatchFolder(dir);
        })),
        item(Icons.note_add, '파일 가져오기', act(() async {
          final files = await FilePicker.pickFiles(dialogTitle: '가져올 파일 선택');
          final paths = files.map((f) => f.path).whereType<String>().toList();
          if (paths.isNotEmpty) await state.importFiles(paths);
        })),
        item(Icons.refresh, '다시 스캔', state.scanning ? null : act(state.rescanAll)),
        item(Icons.auto_fix_high, '시리즈 자동 묶기', act(() async {
          final n = await state.autoGroup();
          if (context.mounted) {
            ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(content: Text(n == 0 ? '새로 묶을 항목이 없습니다' : '$n개 항목을 시리즈로 묶었습니다')),
            );
          }
        })),
        item(Icons.create_new_folder_outlined, '새 묶음 만들기', act(() async {
          final name = await askText(context, '새 묶음 이름', hint: '예) 명탐정 코난');
          if (name != null && name.isNotEmpty) await state.createSeries(name, parentId: state.currentSeriesId);
        })),
        item(Icons.copy_all, '중복 / 누락 확인', act(() => _showDuplicates(context))),
      ],

      section('도구'),
      item(Icons.auto_awesome, 'AI 도우미', act(() => showAiChat(context))),
      item(Icons.settings, '설정', act(() => push(const SettingsPage()))),
      if (admin) item(Icons.manage_accounts, '관리자 (사용자·권한·숨김)', act(() => push(const AdminPage()))),
      if (state.hiddenUnlocked) item(Icons.lock, '숨김 목록 다시 잠그기', act(state.lockHidden)),

      if (tags.isNotEmpty) ...[
        section('태그'),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 8),
          child: Wrap(spacing: 6, runSpacing: 6, children: [
            for (final t in tags)
              ChoiceChip(
                label: Text(t),
                selected: state.tagFilter == t,
                onSelected: (v) => v ? state.setFilter(tag: t) : state.setFilter(clearTag: true),
              ),
          ]),
        ),
      ],
      if (admin && state.settings.watchFolders.isNotEmpty) ...[
        section('스캔 폴더'),
        for (final f in state.settings.watchFolders)
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 2, 16, 2),
            child: Text(f, style: text.bodySmall, overflow: TextOverflow.ellipsis),
          ),
      ],
    ]);
  }

  Future<void> _showDuplicates(BuildContext context) async {
    final state = context.read<AppState>();
    await state.checkMissing();
    final dups = state.findDuplicates();
    final missing = state.allItems.where((e) => e.missing).toList();
    if (!context.mounted) return;
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('중복 / 누락'),
        content: SizedBox(
          width: 520,
          child: ListView(shrinkWrap: true, children: [
            Text('누락된 원본 ${missing.length}개'),
            for (final m in missing) ListTile(dense: true, title: Text(m.title), subtitle: Text(m.path)),
            const Divider(),
            Text('중복 후보 ${dups.length}그룹'),
            for (final g in dups)
              ExpansionTile(
                title: Text(g.first.fileName),
                children: [for (final e in g) ListTile(dense: true, title: Text(e.path))],
              ),
          ]),
        ),
        actions: [TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('닫기'))],
      ),
    );
  }
}

class _HiddenBanner extends StatelessWidget {
  const _HiddenBanner();
  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      margin: const EdgeInsets.fromLTRB(12, 4, 12, 4),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
      decoration: BoxDecoration(color: scheme.tertiaryContainer, borderRadius: BorderRadius.circular(8)),
      child: Row(children: [
        const Icon(Icons.visibility, size: 18),
        const SizedBox(width: 8),
        const Expanded(child: Text('숨김 목록이 열려 있습니다. 앱을 닫거나 잠그면 다시 숨겨집니다.')),
        TextButton.icon(
          onPressed: context.read<AppState>().lockHidden,
          icon: const Icon(Icons.lock, size: 18),
          label: const Text('잠그기'),
        ),
      ]),
    );
  }
}

// =====================================================================
//  검색 / 정렬 막대
// =====================================================================
class _Toolbar extends StatefulWidget {
  final bool phone;
  const _Toolbar({required this.phone});
  @override
  State<_Toolbar> createState() => _ToolbarState();
}

class _ToolbarState extends State<_Toolbar> {
  late final _search = TextEditingController(text: context.read<AppState>().query);

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final state = context.watch<AppState>();
    final settings = context.watch<Settings>();
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 8, 12, 4),
      child: Wrap(
        spacing: 8,
        runSpacing: 8,
        crossAxisAlignment: WrapCrossAlignment.center,
        children: [
          SizedBox(
            width: widget.phone ? double.infinity : 340,
            child: SearchBar(
              controller: _search,
              hintText: '제목, 저자, 태그, 파일명 검색',
              leading: const Icon(Icons.search),
              trailing: [
                if (_search.text.isNotEmpty)
                  IconButton(
                    icon: const Icon(Icons.close),
                    onPressed: () {
                      _search.clear();
                      state.setQuery('');
                    },
                  ),
              ],
              onChanged: state.setQuery,
              // 숨김 비밀번호를 입력하고 Enter → 숨김 목록 열림 (입력한 글자는 지움)
              onSubmitted: (v) {
                if (state.trySearchUnlock(v)) {
                  _search.clear();
                  ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('숨김 목록을 표시합니다')));
                }
              },
            ),
          ),
          DropdownButton<SortBy>(
            value: state.sortBy,
            onChanged: (v) => state.setSort(v!),
            items: const [
              DropdownMenuItem(value: SortBy.added, child: Text('최근 추가순')),
              DropdownMenuItem(value: SortBy.recent, child: Text('최근 읽은순')),
              DropdownMenuItem(value: SortBy.title, child: Text('제목순')),
              DropdownMenuItem(value: SortBy.author, child: Text('저자순')),
              DropdownMenuItem(value: SortBy.rating, child: Text('별점순')),
            ],
          ),
          FilterChip(
            label: const Text('즐겨찾기'),
            selected: state.favoritesOnly,
            onSelected: (v) => state.setFilter(favorites: v),
          ),
          if (state.tagFilter != null)
            InputChip(label: Text('#${state.tagFilter}'), onDeleted: () => state.setFilter(clearTag: true)),
          if (!widget.phone)
            SizedBox(
              width: 180,
              child: Row(children: [
                const Icon(Icons.photo_size_select_large, size: 18),
                Expanded(
                  child: Slider(min: 110, max: 300, value: settings.coverSize, onChanged: (v) => settings.coverSize = v),
                ),
              ]),
            ),
        ],
      ),
    );
  }
}

// =====================================================================
//  표지 목록
// =====================================================================
class _Grid extends StatelessWidget {
  const _Grid();

  @override
  Widget build(BuildContext context) {
    final state = context.watch<AppState>();
    final entries = state.entries;
    final width = MediaQuery.sizeOf(context).width;
    // 휴대폰은 화면 폭 기준 2~3열 자동, 큰 화면은 슬라이더 값
    final coverSize = width < 600 ? (width - 24) / (width < 400 ? 2 : 3) : context.watch<Settings>().coverSize;
    final inSeries = state.currentSeriesId != null && !state.flatMode;
    final admin = state.isAdmin;

    if (entries.isEmpty) {
      return Center(
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          const Icon(Icons.library_books_outlined, size: 64),
          const SizedBox(height: 12),
          Text(inSeries
              ? '이 묶음은 비어 있습니다.'
              : (admin ? '항목이 없습니다. 왼쪽 메뉴의 "폴더 등록"으로 추가하세요.' : '볼 수 있는 항목이 없습니다.')),
        ]),
      );
    }
    // 뷰어에서 앞뒤로 넘길 목록 (묶음 안이면 권 번호순)
    final siblings = entries.whereType<ItemEntry>().map((e) => e.item).toList();

    void info(MediaItem e) => Navigator.push(context, MaterialPageRoute(builder: (_) => DetailPage(item: e)));

    void tap(Entry e) {
      final ctrl = HardwareKeyboard.instance.isControlPressed || HardwareKeyboard.instance.isMetaPressed;
      if (admin && (state.selecting || ctrl)) {
        state.toggleSelect(e);
        return;
      }
      switch (e) {
        case SeriesEntry s:
          state.enterSeries(s.series.id);
        case ItemEntry i:
          openItem(context, i.item, siblings: siblings);
      }
    }

    return GridView.builder(
      padding: const EdgeInsets.fromLTRB(12, 8, 12, 48),
      gridDelegate: SliverGridDelegateWithMaxCrossAxisExtent(
        maxCrossAxisExtent: coverSize,
        childAspectRatio: 0.6,
        crossAxisSpacing: 12,
        mainAxisSpacing: 12,
      ),
      itemCount: entries.length,
      itemBuilder: (context, i) {
        final e = entries[i];
        final sel = state.selected.contains(e.key);
        return switch (e) {
          SeriesEntry s => SeriesTile(
              key: ValueKey(e.key),
              entry: s,
              selected: sel,
              hidden: state.isHiddenSeries(s.series),
              onTap: () => tap(e),
              // 선택(묶기·숨김·권한·삭제)은 관리자만
              onLongPress: admin ? () => state.toggleSelect(e) : () => state.enterSeries(s.series.id),
              onEdit: admin ? () => showSeriesEditor(context, s.series) : () {},
            ),
          ItemEntry it => CoverTile(
              key: ValueKey(e.key),
              item: it.item,
              selected: sel,
              hidden: state.isHiddenItem(it.item),
              showVolume: inSeries,
              onTap: () => tap(e),
              onLongPress: admin ? () => state.toggleSelect(e) : () => info(it.item),
              onInfo: () => info(it.item),
            ),
        };
      },
    );
  }
}
