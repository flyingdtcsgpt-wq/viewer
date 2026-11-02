import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../app_state.dart';
import '../models/entry.dart';
import '../models/media_item.dart';
import '../services/settings.dart';
import '../services/storage_permission.dart';
import 'admin_page.dart';
import 'batch_editor_page.dart';
import 'share_page.dart';
import 'tools/tools_page.dart';
import 'brand.dart';
import 'browser.dart';
import 'ai_chat_sheet.dart';
import 'history_page.dart';
import 'import_dialog.dart';
import 'landing_view.dart';
import 'series_widgets.dart';
import 'settings_page.dart';

const _kinds = <MediaKind?>[null, MediaKind.book, MediaKind.comic, MediaKind.image, MediaKind.video];

/// ARARIFlex 로고 (어두운 배경용)
class Logo extends StatelessWidget {
  final double size;
  const Logo({super.key, this.size = 24});
  @override
  Widget build(BuildContext context) => ArariLogo(size: size, onDark: Theme.of(context).brightness == Brightness.dark);
}
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
      if (inSeries && !state.recursive) const SeriesHeader(),
      const Expanded(child: EntryBrowser(desktop: false)),
    ]);

    final showLanding = state.landing && !state.selecting && !state.flatMode;

    Widget page;
    if (wide) {
      // PC: 위 작업 줄 / 왼쪽 사이드바 / 가운데 목록 / 아래 상세 패널 + 상태 막대
      page = Scaffold(
        body: SafeArea(
          child: Column(children: [
            const _TopActionBar(),
            const Divider(height: 1),
            Expanded(
              child: Row(children: [
                const SizedBox(width: 270, child: Material(child: _Sidebar())),
                const VerticalDivider(width: 1),
                Expanded(
                  child: showLanding
                      ? const LandingView(topBar: _LandingTopBar(wide: true))
                      : Column(children: [
                          const _Toolbar(phone: false),
                          const PathBar(),
                          if (state.hiddenUnlocked) const _HiddenBanner(),
                          const Expanded(child: EntryBrowser(desktop: true)),
                          const DetailPanel(),
                          const StatusBar(),
                        ]),
                ),
              ]),
            ),
          ]),
        ),
      );
    } else {
      page = Scaffold(
        appBar: showLanding
            ? null
            : AppBar(
                leading: back,
                title: state.currentSeriesId != null ? Text(title, overflow: TextOverflow.ellipsis) : const Logo(size: 20),
              ),
        drawer: const Drawer(child: SafeArea(child: _Sidebar(inDrawer: true))),
        body: showLanding ? const LandingView(topBar: _LandingTopBar(wide: false)) : body,
        // 휴대폰 하단 탭: 홈 · 책 · 만화 · 그림 · 영상
        bottomNavigationBar: NavigationBar(
          selectedIndex: showLanding || state.kindFilter == null ? 0 : _kinds.indexOf(state.kindFilter),
          onDestinationSelected: (i) => i == 0 ? state.showLanding() : state.setFilter(kind: _kinds[i]),
          destinations: [
            const NavigationDestination(icon: Icon(Icons.home_outlined), selectedIcon: Icon(Icons.home), label: '홈'),
            for (var i = 1; i < _kinds.length; i++)
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
          const SingleActivator(LogicalKeyboardKey.arrowLeft, alt: true): state.goBack,
          const SingleActivator(LogicalKeyboardKey.arrowRight, alt: true): state.goForward,
          const SingleActivator(LogicalKeyboardKey.keyA, control: true): state.selectAll,
          const SingleActivator(LogicalKeyboardKey.f5): () {
            if (state.isAdmin && !state.scanning) state.rescanAll();
          },
          const SingleActivator(LogicalKeyboardKey.enter): () {
            final e = state.focusedEntry;
            if (e != null) openEntry(context, e, state.entries.whereType<ItemEntry>().map((x) => x.item).toList());
          },
          const SingleActivator(LogicalKeyboardKey.delete): () async {
            if (!state.isAdmin || state.selected.isEmpty) return;
            final mode = await confirmDelete(context, '선택한 ${state.selected.length}개');
            if (mode != null) await state.removeSelected(deleteFile: mode);
          },
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
    // 서랍이 닫혀도 살아 있는 화면 context (대화상자/알림용)
    final rootContext = Navigator.of(context).context;
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
      if (inDrawer)
        const Padding(
          padding: EdgeInsets.fromLTRB(12, 4, 4, 4),
          child: Logo(size: 26),
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

      section('모아보기'),
      item(Icons.home, '홈', act(state.showLanding), selected: state.landing && !state.flatMode && state.collection == Collection.none),
      for (final (c, icon) in const [
        (Collection.favorites, Icons.star),
        (Collection.recent, Icons.schedule),
        (Collection.reading, Icons.auto_stories),
        (Collection.finished, Icons.task_alt),
        (Collection.recentAdded, Icons.calendar_month),
        (Collection.missing, Icons.search),
      ])
        item(
          icon,
          collectionLabel(c),
          act(() => state.setCollection(c)),
          selected: state.collection == c,
          trailing: '${state.collectionCount(c)}',
        ),
      item(Icons.history, '내 열람 기록', act(() => push(const HistoryPage()))),

      // 라이브러리 폴더 (설정에서 정한 순서 · 그룹 · 별칭)
      if (state.visibleLibraryFolders.isNotEmpty) ...[
        section('라이브러리'),
        for (final (i, f) in state.visibleLibraryFolders.indexed) ...[
          if (f.group.isNotEmpty && (i == 0 || state.visibleLibraryFolders[i - 1].group != f.group))
            Padding(
              padding: const EdgeInsets.fromLTRB(18, 8, 16, 2),
              child: Text(f.group, style: text.labelSmall?.copyWith(color: Colors.grey)),
            ),
          Builder(builder: (_) {
            final (dirs, files) = state.libraryCounts(f.path);
            return ListTile(
              dense: true,
              visualDensity: VisualDensity.compact,
              contentPadding: EdgeInsets.only(left: f.group.isEmpty ? 16 : 28, right: 12),
              selected: state.libraryPath == f.path,
              selectedTileColor: scheme.secondaryContainer,
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(24)),
              title: Text(f.name, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontWeight: FontWeight.w600)),
              trailing: Row(mainAxisSize: MainAxisSize.min, children: [
                const Icon(Icons.folder, size: 13, color: Color(0xFFFFC107)),
                Text(' $dirs  ', style: text.bodySmall),
                const Icon(Icons.description, size: 13, color: Colors.grey),
                Text(' $files', style: text.bodySmall),
              ]),
              onTap: act(() => state.setLibrary(f.path)),
            );
          }),
        ],
      ],

      section('종류'),
      for (var i = 0; i < _kinds.length; i++)
        if (i == 0 || state.kindAllowed(_kinds[i]!))
        item(
          _kindIcons[i],
          _kindName(_kinds[i]),
          act(() {
            state.enterSeries(null);
            i == 0 ? state.setFilter(clearKind: true) : state.setFilter(kind: _kinds[i]);
          }),
          selected: !state.landing && state.collection == Collection.none && state.libraryPath == null && state.kindFilter == _kinds[i] && state.currentSeriesId == null,
          trailing: '${state.count(_kinds[i])}',
        ),

      // 맨 위 묶음들 (폴더처럼)
      if (state.tree.children[null]?.isNotEmpty ?? false) ...[
        section('묶음'),
        for (final s in [...state.tree.children[null]!]..sort((a, b) => a.title.compareTo(b.title)))
          item(
            Icons.folder,
            s.title,
            act(() => state.enterSeries(s.id)),
            selected: state.breadcrumb.firstOrNull?.id == s.id && state.collection == Collection.none,
            trailing: '${state.statsOf(s).allItems}',
          ),
      ],

      if (admin && inDrawer) ...[
        section('라이브러리 관리'),
        item(Icons.create_new_folder, '폴더 추가', act(() => addFolderFlow(rootContext))),
        item(Icons.note_add, '파일 추가', act(() => addFilesFlow(rootContext))),
        item(Icons.refresh, '다시 스캔', state.scanning ? null : act(() async {
          if (await ensureStorageAccess(rootContext)) await state.rescanAll();
        })),
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
      item(Icons.settings, '설정', act(() => showSettings(rootContext))),
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

/// PC 위쪽 작업 줄: 폴더 추가 · 파일 추가 · 선택 삭제 · 전체 선택 … / 버전 · 기록 · AI · 설정
class _TopActionBar extends StatelessWidget {
  const _TopActionBar();

  @override
  Widget build(BuildContext context) {
    final state = context.watch<AppState>();
    final scheme = Theme.of(context).colorScheme;
    final admin = state.isAdmin;
    final has = state.selected.isNotEmpty;
    void push(Widget p) => Navigator.push(context, MaterialPageRoute(builder: (_) => p));
    void toast(String m) => ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(m)));

    Widget btn(IconData icon, String label, VoidCallback? onTap, {Color? color}) => Padding(
          padding: const EdgeInsets.only(right: 6),
          child: FilledButton.tonalIcon(
            style: FilledButton.styleFrom(
              backgroundColor: scheme.surfaceContainerHigh,
              foregroundColor: color ?? scheme.onSurface,
              disabledBackgroundColor: scheme.surfaceContainer,
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 14),
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(6)),
            ),
            onPressed: onTap,
            icon: Icon(icon, size: 18),
            label: Text(label),
          ),
        );

    // 고른 항목이 있을 때만 쓸 수 있는 동작은 고른 뒤에만 나타난다 (흐린 버튼이 자리를 차지하지 않게)
    final selActions = <Widget>[
      Padding(
        padding: const EdgeInsets.only(right: 10),
        child: InputChip(
          avatar: Icon(Icons.check_circle, size: 18, color: scheme.primary),
          label: Text('${state.selected.length}개 선택'),
          onDeleted: state.clearSelection,
          deleteButtonTooltipMessage: '선택 해제 (Esc)',
        ),
      ),
      if (admin) ...[
        btn(Icons.delete_outline, '삭제', () async {
          final mode = await confirmDelete(context, '선택한 ${state.selected.length}개');
          if (mode != null) await state.removeSelected(deleteFile: mode);
        }, color: Colors.redAccent),
        btn(Icons.create_new_folder_outlined, '묶기', () async {
          final t = await askText(context, '새 묶음 이름', hint: '예) 명탐정 코난');
          if (t != null && t.isNotEmpty) await state.groupSelected(t);
        }),
        btn(Icons.drive_file_move, '다른 묶음으로', () async {
          final c = await pickSeries(context, title: '어느 묶음으로 옮길까요?');
          if (c != null) await state.moveSelected(c.id);
        }),
        btn(Icons.edit_note, '메타데이터', () {
          final items = state.selectedItemsDeep;
          if (items.isNotEmpty) push(BatchEditorPage(items: items));
        }),
        btn(Icons.visibility_off, '숨기기', () async {
          if (!state.hasHiddenPassword) return toast('먼저 관리자 메뉴에서 숨김 비밀번호를 정하세요');
          await state.hideSelected(true);
        }),
        if (state.hiddenUnlocked) btn(Icons.visibility, '숨김 해제', () => state.hideSelected(false)),
        btn(Icons.lock_person, '사용자 접근', () => showAccessForSelection(context)),
      ],
    ];

    return Container(
      color: scheme.surfaceContainerLowest,
      padding: const EdgeInsets.fromLTRB(16, 8, 12, 8),
      child: Row(children: [
        const Logo(size: 22),
        const SizedBox(width: 20),
        if (admin && !has) ...[
          PopupMenuButton<int>(
            tooltip: '라이브러리에 추가',
            position: PopupMenuPosition.under,
            onSelected: (v) => v == 0 ? addFolderFlow(context) : addFilesFlow(context),
            itemBuilder: (_) => const [
              PopupMenuItem(value: 0, child: ListTile(leading: Icon(Icons.create_new_folder), title: Text('폴더 추가'), subtitle: Text('폴더 안의 책 · 만화 · 그림 · 영상을 찾아 추가'))),
              PopupMenuItem(value: 1, child: ListTile(leading: Icon(Icons.note_add), title: Text('파일 추가'), subtitle: Text('파일을 골라서 추가'))),
            ],
            child: IgnorePointer(
              child: FilledButton.icon(
                style: FilledButton.styleFrom(
                  padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(6)),
                ),
                onPressed: () {},
                icon: const Icon(Icons.add, size: 20),
                label: const Text('추가'),
              ),
            ),
          ),
          const SizedBox(width: 8),
        ],
        Expanded(
          child: has
              ? SingleChildScrollView(scrollDirection: Axis.horizontal, child: Row(children: selActions))
              : const SizedBox(),
        ),
        if (admin)
          PopupMenuButton<int>(
            tooltip: '더보기',
            icon: const Icon(Icons.more_horiz),
            position: PopupMenuPosition.under,
            onSelected: (v) async {
              switch (v) {
                case 0:
                  state.selected.length > 1 ? state.clearSelection() : state.selectAll();
                case 1:
                  final n = await state.autoGroup();
                  toast(n == 0 ? '새로 묶을 항목이 없습니다' : '$n개 항목을 시리즈로 묶었습니다');
                case 2:
                  push(const ToolsPage());
                case 3:
                  push(const SharePage());
              }
            },
            itemBuilder: (_) => [
              const PopupMenuItem(value: 0, child: ListTile(leading: Icon(Icons.select_all), title: Text('전체 선택 / 해제'), trailing: Text('Ctrl+A'))),
              const PopupMenuItem(value: 1, child: ListTile(leading: Icon(Icons.auto_fix_high), title: Text('시리즈 자동 묶기'))),
              const PopupMenuDivider(),
              const PopupMenuItem(value: 2, child: ListTile(leading: Icon(Icons.construction), title: Text('파일 도구'))),
              PopupMenuItem(
                value: 3,
                child: ListTile(
                  leading: Icon(state.share.running ? Icons.wifi_tethering : Icons.wifi_tethering_off,
                      color: state.share.running ? Colors.greenAccent : null),
                  title: Text(state.share.running ? '공유 서버 (켜짐)' : '공유 서버'),
                ),
              ),
            ],
          ),
        if (admin && state.share.running)
          IconButton(
            tooltip: '공유 서버 켜짐',
            icon: const Icon(Icons.wifi_tethering, color: Colors.greenAccent),
            onPressed: () => push(const SharePage()),
          ),
        IconButton(tooltip: '내 열람 기록', icon: const Icon(Icons.history), onPressed: () => push(const HistoryPage())),
        IconButton(tooltip: 'AI 도우미', icon: const Icon(Icons.auto_awesome), onPressed: () => showAiChat(context)),
        if (admin) IconButton(tooltip: '관리자', icon: const Icon(Icons.manage_accounts), onPressed: () => push(const AdminPage())),
        IconButton(tooltip: '설정', icon: const Icon(Icons.settings), onPressed: () => showSettings(context)),
      ]),
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
    context.watch<Settings>(); // 설정이 바뀌면 다시 그리기
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
          FilterChip(
            avatar: const Icon(Icons.account_tree, size: 16),
            label: const Text('하위 묶음 포함'),
            selected: state.recursive,
            onSelected: state.setRecursive,
          ),
          if (state.tagFilter != null)
            InputChip(label: Text('#${state.tagFilter}'), onDeleted: () => state.setFilter(clearTag: true)),
        ],
      ),
    );
  }
}

/// 첫 화면 배너 위에 겹치는 줄: (휴대폰) 메뉴 + 로고, 검색
class _LandingTopBar extends StatefulWidget {
  final bool wide;
  const _LandingTopBar({required this.wide});
  @override
  State<_LandingTopBar> createState() => _LandingTopBarState();
}

class _LandingTopBarState extends State<_LandingTopBar> {
  final _c = TextEditingController();

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final state = context.read<AppState>();
    return SafeArea(
      bottom: false,
      child: Padding(
        padding: EdgeInsets.fromLTRB(widget.wide ? 40 : 4, 8, widget.wide ? 40 : 8, 0),
        child: Row(children: [
          if (!widget.wide) ...[
            IconButton(
              color: Colors.white,
              icon: const Icon(Icons.menu),
              onPressed: () => Scaffold.of(context).openDrawer(),
            ),
            const Logo(size: 20),
          ],
          const Spacer(),
          SizedBox(
            width: widget.wide ? 280 : 170,
            height: 40,
            child: TextField(
              controller: _c,
              style: const TextStyle(color: Colors.white),
              cursorColor: Colors.white,
              decoration: InputDecoration(
                isDense: true,
                hintText: '검색',
                hintStyle: const TextStyle(color: Colors.white70),
                prefixIcon: const Icon(Icons.search, color: Colors.white),
                filled: true,
                fillColor: Colors.black54,
                border: OutlineInputBorder(borderRadius: BorderRadius.circular(4), borderSide: const BorderSide(color: Colors.white38)),
                enabledBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(4), borderSide: const BorderSide(color: Colors.white38)),
              ),
              // Enter 를 눌러야 검색 (숨김 비밀번호면 숨김 목록이 열림)
              onSubmitted: (v) {
                _c.clear();
                if (state.trySearchUnlock(v)) {
                  ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('숨김 목록을 표시합니다')));
                } else if (v.trim().isNotEmpty) {
                  state.setQuery(v.trim());
                }
              },
            ),
          ),
        ]),
      ),
    );
  }
}
