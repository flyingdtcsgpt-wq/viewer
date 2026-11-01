import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../app_state.dart';
import '../models/entry.dart';
import '../models/media_item.dart';
import '../services/settings.dart';
import 'ai_chat_sheet.dart';
import 'cover_tile.dart';
import 'detail_page.dart';
import 'series_widgets.dart';
import 'settings_page.dart';
import 'viewers/open_item.dart';

/// 화면 폭에 따라 레이아웃 변경
///  - < 600 : 휴대폰 → 하단 탭 + 서랍(태그)
///  - 600~1100 : 태블릿/작은 창 → 접힌 사이드 레일
///  - >= 1100 : 데스크톱 → 펼친 사이드바
class HomePage extends StatelessWidget {
  const HomePage({super.key});

  static const _kinds = <MediaKind?>[null, MediaKind.book, MediaKind.comic, MediaKind.image, MediaKind.video];
  static const _icons = [Icons.apps, Icons.menu_book, Icons.auto_stories, Icons.image, Icons.movie];

  @override
  Widget build(BuildContext context) {
    final state = context.watch<AppState>();
    final width = MediaQuery.sizeOf(context).width;
    final phone = width < 600;
    final selected = _kinds.indexOf(state.kindFilter);

    void select(int i) => i == 0 ? state.setFilter(clearKind: true) : state.setFilter(kind: _kinds[i]);

    final inSeries = state.currentSeriesId != null && !state.flatMode;
    final title = inSeries ? state.currentSeries!.title : (selected == 0 ? '전체' : kindLabel(_kinds[selected]!));
    final back = state.currentSeriesId != null
        ? IconButton(tooltip: '위로', icon: const Icon(Icons.arrow_back), onPressed: state.goUp)
        : null;

    // 안드로이드 뒤로가기 / Esc: 선택 해제 → 한 단계 위 묶음 → 앱 종료
    Widget withBack(Widget child) => PopScope(
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
            child: Focus(autofocus: true, child: child),
          ),
        );

    final body = Column(children: [
      state.selecting ? const SelectionBar() : _Toolbar(phone: phone),
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

    if (phone) {
      return withBack(Scaffold(
        appBar: AppBar(
          leading: back,
          title: Text(state.currentSeriesId != null ? title : 'MediaShelf', overflow: TextOverflow.ellipsis),
          actions: _actions(context),
        ),
        drawer: const Drawer(child: SafeArea(child: _TagPanel())),
        body: body,
        bottomNavigationBar: NavigationBar(
          selectedIndex: selected,
          onDestinationSelected: select,
          destinations: [
            for (var i = 0; i < _kinds.length; i++)
              NavigationDestination(icon: Icon(_icons[i]), label: _kinds[i] == null ? '전체' : kindLabel(_kinds[i]!)),
          ],
        ),
        floatingActionButton: const _AddButton(),
      ));
    }

    final extended = width >= 1100;
    return withBack(Scaffold(
      body: SafeArea(
        child: Row(children: [
          NavigationRail(
            extended: extended,
            minExtendedWidth: 220,
            selectedIndex: selected,
            onDestinationSelected: select,
            leading: Padding(
              padding: const EdgeInsets.symmetric(vertical: 12),
              child: extended
                  ? Text('MediaShelf', style: Theme.of(context).textTheme.titleLarge)
                  : const Icon(Icons.local_library, size: 32),
            ),
            destinations: [
              for (var i = 0; i < _kinds.length; i++)
                NavigationRailDestination(
                  icon: Icon(_icons[i]),
                  label: Text('${_kinds[i] == null ? '전체' : kindLabel(_kinds[i]!)}  (${state.count(_kinds[i])})'),
                ),
            ],
          ),
          const VerticalDivider(width: 1),
          if (extended) ...[
            const SizedBox(width: 200, child: _TagPanel()),
            const VerticalDivider(width: 1),
          ],
          Expanded(
            child: Scaffold(
              appBar: AppBar(leading: back, title: Text(title, overflow: TextOverflow.ellipsis), actions: _actions(context)),
              body: body,
              floatingActionButton: const _AddButton(),
            ),
          ),
        ]),
      ),
    ));
  }

  List<Widget> _actions(BuildContext context) {
    final state = context.read<AppState>();
    return [
      IconButton(
        tooltip: '다시 스캔',
        icon: const Icon(Icons.refresh),
        onPressed: state.scanning ? null : state.rescanAll,
      ),
      IconButton(
        tooltip: 'AI 도우미',
        icon: const Icon(Icons.auto_awesome),
        onPressed: () => showAiChat(context),
      ),
      IconButton(
        tooltip: '설정',
        icon: const Icon(Icons.settings),
        onPressed: () => Navigator.push(context, MaterialPageRoute(builder: (_) => const SettingsPage())),
      ),
    ];
  }
}

class _Toolbar extends StatelessWidget {
  final bool phone;
  const _Toolbar({required this.phone});

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
            width: phone ? double.infinity : 320,
            child: SearchBar(
              hintText: '제목, 저자, 태그, 파일명 검색',
              leading: const Icon(Icons.search),
              onChanged: state.setQuery,
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
          if (!phone)
            SizedBox(
              width: 180,
              child: Row(children: [
                const Icon(Icons.photo_size_select_large, size: 18),
                Expanded(
                  child: Slider(
                    min: 110,
                    max: 300,
                    value: settings.coverSize,
                    onChanged: (v) => settings.coverSize = v,
                  ),
                ),
              ]),
            ),
        ],
      ),
    );
  }
}

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

    if (entries.isEmpty) {
      return Center(
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          const Icon(Icons.library_books_outlined, size: 64),
          const SizedBox(height: 12),
          Text(inSeries ? '이 묶음은 비어 있습니다.' : '항목이 없습니다. + 버튼으로 폴더나 파일을 추가하세요.'),
        ]),
      );
    }
    // 뷰어에서 앞뒤로 넘길 목록 (묶음 안이면 권 번호순)
    final siblings = entries.whereType<ItemEntry>().map((e) => e.item).toList();

    void tap(Entry e) {
      final ctrl = HardwareKeyboard.instance.isControlPressed || HardwareKeyboard.instance.isMetaPressed;
      if (state.selecting || ctrl) {
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
      padding: const EdgeInsets.fromLTRB(12, 8, 12, 96),
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
              onTap: () => tap(e),
              onLongPress: () => state.toggleSelect(e),
              onEdit: () => showSeriesEditor(context, s.series),
            ),
          ItemEntry it => CoverTile(
              key: ValueKey(e.key),
              item: it.item,
              selected: sel,
              showVolume: inSeries,
              onTap: () => tap(e),
              onLongPress: () => state.toggleSelect(e),
              onInfo: () => Navigator.push(context, MaterialPageRoute(builder: (_) => DetailPage(item: it.item))),
            ),
        };
      },
    );
  }
}

class _TagPanel extends StatelessWidget {
  const _TagPanel();

  @override
  Widget build(BuildContext context) {
    final state = context.watch<AppState>();
    final tags = state.allTags.toList()..sort();
    return ListView(
      padding: const EdgeInsets.all(12),
      children: [
        Text('태그', style: Theme.of(context).textTheme.titleSmall),
        const SizedBox(height: 8),
        if (tags.isEmpty) const Text('아직 태그가 없습니다', style: TextStyle(color: Colors.grey)),
        Wrap(spacing: 6, runSpacing: 6, children: [
          for (final t in tags)
            ChoiceChip(
              label: Text(t),
              selected: state.tagFilter == t,
              onSelected: (v) => v ? state.setFilter(tag: t) : state.setFilter(clearTag: true),
            ),
        ]),
        const Divider(height: 32),
        Text('스캔 폴더', style: Theme.of(context).textTheme.titleSmall),
        for (final f in state.settings.watchFolders)
          Padding(
            padding: const EdgeInsets.only(top: 4),
            child: Text(f, style: Theme.of(context).textTheme.bodySmall, overflow: TextOverflow.ellipsis),
          ),
      ],
    );
  }
}

class _AddButton extends StatelessWidget {
  const _AddButton();

  @override
  Widget build(BuildContext context) {
    final state = context.read<AppState>();
    return MenuAnchor(
      menuChildren: [
        MenuItemButton(
          leadingIcon: const Icon(Icons.create_new_folder),
          child: const Text('폴더 등록 (원본 위치 참조)'),
          onPressed: () async {
            final dir = await FilePicker.getDirectoryPath(dialogTitle: '스캔할 폴더 선택');
            if (dir != null) await state.addWatchFolder(dir);
          },
        ),
        MenuItemButton(
          leadingIcon: const Icon(Icons.note_add),
          child: const Text('파일 가져오기'),
          onPressed: () async {
            final files = await FilePicker.pickFiles(dialogTitle: '가져올 파일 선택');
            final paths = files.map((f) => f.path).whereType<String>().toList();
            if (paths.isNotEmpty) await state.importFiles(paths);
          },
        ),
        MenuItemButton(
          leadingIcon: const Icon(Icons.auto_fix_high),
          child: const Text('파일명으로 시리즈 자동 묶기'),
          onPressed: () async {
            final n = await state.autoGroup();
            if (context.mounted) {
              ScaffoldMessenger.of(context).showSnackBar(
                SnackBar(content: Text(n == 0 ? '새로 묶을 항목이 없습니다' : '$n개 항목을 시리즈로 묶었습니다')),
              );
            }
          },
        ),
        MenuItemButton(
          leadingIcon: const Icon(Icons.create_new_folder_outlined),
          child: const Text('새 묶음 만들기'),
          onPressed: () async {
            final name = await askText(context, '새 묶음 이름', hint: '예) 명탐정 코난');
            if (name != null && name.isNotEmpty) await state.createSeries(name, parentId: state.currentSeriesId);
          },
        ),
        MenuItemButton(
          leadingIcon: const Icon(Icons.copy_all),
          child: const Text('중복 / 누락 확인'),
          onPressed: () => _showDuplicates(context),
        ),
      ],
      builder: (context, controller, _) => FloatingActionButton.extended(
        onPressed: () => controller.isOpen ? controller.close() : controller.open(),
        icon: const Icon(Icons.add),
        label: const Text('추가'),
      ),
    );
  }

  Future<void> _showDuplicates(BuildContext context) async {
    final state = context.read<AppState>();
    await state.checkMissing();
    final dups = state.findDuplicates();
    final missing = state.allItems.where((e) => e.missing).toList();
    if (!context.mounted) return;
    showDialog(
      context: context,
      builder: (_) => AlertDialog(
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
        actions: [TextButton(onPressed: () => Navigator.pop(context), child: const Text('닫기'))],
      ),
    );
  }
}
