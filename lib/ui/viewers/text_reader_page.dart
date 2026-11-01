import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../../app_state.dart';
import '../../models/media_item.dart';
import '../../services/settings.dart';
import '../../services/text_document.dart';
import 'open_item.dart';

/// TXT / EPUB 뷰어
///
/// 긴 소설(수 MB)도 빠르게 열리도록 문단 단위로 지연 렌더링한다.
/// 특정 위치로 이동할 때는 "기준 블록(anchor)"을 바꿔서, 그 블록부터 아래로 / 그 앞은 위로
/// 그리는 방식(center sliver)이라 높이를 미리 계산할 필요가 없다.
class TextReaderPage extends StatefulWidget {
  final MediaItem item;
  const TextReaderPage({super.key, required this.item});

  @override
  State<TextReaderPage> createState() => _TextReaderPageState();
}

class _ReaderColors {
  final Color bg, fg;
  const _ReaderColors(this.bg, this.fg);
}

const _themes = [
  _ReaderColors(Color(0xFFFFFFFF), Color(0xFF222222)), // 흰색
  _ReaderColors(Color(0xFFF4ECD8), Color(0xFF5B4636)), // 세피아
  _ReaderColors(Color(0xFF2B2B2B), Color(0xFFD6D6D6)), // 회색
  _ReaderColors(Color(0xFF000000), Color(0xFFA0A0A0)), // 검정
];
const _themeNames = ['흰색', '세피아', '회색', '검정'];

class _TextReaderPageState extends State<TextReaderPage> {
  final _scaffold = GlobalKey<ScaffoldState>();
  final _viewKey = GlobalKey();
  final _ctrl = ScrollController();
  final _alive = <int, BuildContext>{}; // 화면에 붙어 있는 블록들
  final _focus = FocusNode();

  TextDocument? _doc;
  Object? _error;
  int _anchor = 0;
  Key _centerKey = UniqueKey();
  int _current = 0;
  bool _showUi = false;
  Timer? _saveTimer;

  late final AppState _app = context.read<AppState>();

  MediaItem get item => widget.item;
  int get _count => _doc?.blocks.length ?? 0;
  double get _progress => _count <= 1 ? 1 : _current / (_count - 1);

  @override
  void initState() {
    super.initState();
    _app; // dispose 에서 context 를 쓰지 않도록 미리 잡아둔다
    _load();
  }

  Future<void> _load() async {
    try {
      final doc = await TextDocument.load(item.path);
      if (!mounted) return;
      final saved = int.tryParse(item.position ?? '') ?? 0;
      setState(() {
        _doc = doc;
        _anchor = saved.clamp(0, doc.blocks.isEmpty ? 0 : doc.blocks.length - 1);
        _current = _anchor;
      });
    } catch (e) {
      if (mounted) setState(() => _error = e);
    }
  }

  @override
  void dispose() {
    _saveTimer?.cancel();
    if (_doc != null && _count > 0) {
      _app.saveProgress(item, '$_current', _progress).then((_) => _app.refresh());
    }
    _ctrl.dispose();
    _focus.dispose();
    super.dispose();
  }

  // ---------------- 위치 ----------------

  void _jumpTo(int block) {
    if (_count == 0) return;
    setState(() {
      _anchor = block.clamp(0, _count - 1);
      _current = _anchor;
      _centerKey = UniqueKey();
    });
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_ctrl.hasClients) _ctrl.jumpTo(0);
    });
    _scheduleSave();
  }

  /// 화면 맨 위에 걸친 블록 번호 계산
  void _updateCurrent() {
    final view = _viewKey.currentContext?.findRenderObject() as RenderBox?;
    if (view == null || !view.attached) return;
    final top = view.localToGlobal(Offset.zero).dy + 8;
    int? best;
    double bestY = double.infinity;
    _alive.forEach((index, ctx) {
      final box = ctx.findRenderObject() as RenderBox?;
      if (box == null || !box.attached || !box.hasSize) return;
      final y = box.localToGlobal(Offset.zero).dy;
      if (y + box.size.height > top && y < bestY) {
        bestY = y;
        best = index;
      }
    });
    if (best != null && best != _current) {
      setState(() => _current = best!);
      _scheduleSave();
    }
  }

  void _scheduleSave() {
    _saveTimer?.cancel();
    _saveTimer = Timer(const Duration(seconds: 1), () {
      _app.saveProgress(item, '$_current', _progress);
    });
  }

  void _page(int dir) {
    if (!_ctrl.hasClients) return;
    final pos = _ctrl.position;
    final target = (pos.pixels + dir * pos.viewportDimension * 0.9).clamp(pos.minScrollExtent, pos.maxScrollExtent);
    _ctrl.animateTo(target, duration: const Duration(milliseconds: 180), curve: Curves.easeOut);
  }

  // ---------------- 화면 ----------------

  @override
  Widget build(BuildContext context) {
    final s = context.watch<Settings>();
    final colors = _themes[s.readerTheme.clamp(0, _themes.length - 1)];

    Widget body;
    if (_error != null) {
      body = Center(child: Text('열 수 없습니다: $_error', style: TextStyle(color: colors.fg)));
    } else if (_doc == null) {
      body = const Center(child: CircularProgressIndicator());
    } else if (_count == 0) {
      body = Center(child: Text('내용이 없습니다', style: TextStyle(color: colors.fg)));
    } else {
      body = _buildText(s, colors);
    }

    return CallbackShortcuts(
      bindings: {
        const SingleActivator(LogicalKeyboardKey.pageDown): () => _page(1),
        const SingleActivator(LogicalKeyboardKey.space): () => _page(1),
        const SingleActivator(LogicalKeyboardKey.arrowRight): () => _page(1),
        const SingleActivator(LogicalKeyboardKey.pageUp): () => _page(-1),
        const SingleActivator(LogicalKeyboardKey.arrowLeft): () => _page(-1),
        const SingleActivator(LogicalKeyboardKey.space, shift: true): () => _page(-1),
        const SingleActivator(LogicalKeyboardKey.home): () => _jumpTo(0),
        const SingleActivator(LogicalKeyboardKey.end): () => _jumpTo(_count - 1),
        const SingleActivator(LogicalKeyboardKey.keyF, control: true): _openSearch,
        const SingleActivator(LogicalKeyboardKey.escape): () => Navigator.maybePop(context),
      },
      child: Focus(
        focusNode: _focus,
        autofocus: true,
        child: Scaffold(
          key: _scaffold,
          backgroundColor: colors.bg,
          endDrawer: _doc == null ? null : _tocDrawer(),
          body: Stack(children: [
            Positioned.fill(child: SafeArea(child: body)),
            // 위쪽 도구 모음
            AnimatedPositioned(
              duration: const Duration(milliseconds: 180),
              top: _showUi ? 0 : -120,
              left: 0,
              right: 0,
              child: Material(
                elevation: 3,
                child: SafeArea(
                  bottom: false,
                  child: AppBar(
                    title: Text(item.title, overflow: TextOverflow.ellipsis),
                    actions: [
                      IconButton(tooltip: '본문 검색 (Ctrl+F)', icon: const Icon(Icons.search), onPressed: _openSearch),
                      IconButton(tooltip: '보기 설정', icon: const Icon(Icons.text_fields), onPressed: _openSettings),
                      NextVolumeButton(item: item),
                      IconButton(
                        tooltip: '목차',
                        icon: const Icon(Icons.toc),
                        onPressed: () => _scaffold.currentState?.openEndDrawer(),
                      ),
                    ],
                  ),
                ),
              ),
            ),
            // 아래쪽 진행 막대
            AnimatedPositioned(
              duration: const Duration(milliseconds: 180),
              bottom: _showUi ? 0 : -120,
              left: 0,
              right: 0,
              child: Material(
                elevation: 3,
                child: SafeArea(
                  top: false,
                  child: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
                    child: Row(children: [
                      Expanded(
                        child: Slider(
                          value: _progress.clamp(0.0, 1.0),
                          onChanged: (v) => setState(() => _current = (v * (_count - 1)).round()),
                          onChangeEnd: (v) => _jumpTo((v * (_count - 1)).round()),
                        ),
                      ),
                      Text('${(_progress * 100).toStringAsFixed(1)}%'),
                    ]),
                  ),
                ),
              ),
            ),
          ]),
        ),
      ),
    );
  }

  Widget _buildText(Settings s, _ReaderColors colors) {
    final blocks = _doc!.blocks;
    final base = TextStyle(fontSize: s.readerFontSize, height: s.readerLineHeight, color: colors.fg);
    final screenH = MediaQuery.sizeOf(context).height;

    Widget item(int i) => _BlockItem(
          key: ValueKey(i),
          index: i,
          registry: _alive,
          child: _renderBlock(blocks[i], base, s, colors, screenH),
        );

    return LayoutBuilder(builder: (context, c) {
      final hPad = ((c.maxWidth - s.readerMaxWidth) / 2).clamp(20.0, double.infinity);
      return GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTapUp: (d) {
          final x = d.localPosition.dx / c.maxWidth;
          if (x < 0.25) {
            _page(-1);
          } else if (x > 0.75) {
            _page(1);
          } else {
            setState(() => _showUi = !_showUi);
          }
        },
        child: NotificationListener<ScrollNotification>(
          onNotification: (n) {
            if (n is ScrollEndNotification) _updateCurrent();
            return false;
          },
          child: CustomScrollView(
            key: _viewKey,
            controller: _ctrl,
            center: _centerKey,
            slivers: [
              // 기준 블록 앞부분 (위쪽으로 쌓임)
              SliverPadding(
                padding: EdgeInsets.symmetric(horizontal: hPad),
                sliver: SliverList(
                  delegate: SliverChildBuilderDelegate((_, i) => item(_anchor - 1 - i), childCount: _anchor),
                ),
              ),
              // 기준 블록부터 끝까지
              SliverPadding(
                key: _centerKey,
                padding: EdgeInsets.fromLTRB(hPad, 0, hPad, screenH * 0.5),
                sliver: SliverList(
                  delegate: SliverChildBuilderDelegate((_, i) => item(_anchor + i), childCount: blocks.length - _anchor),
                ),
              ),
            ],
          ),
        ),
      );
    });
  }

  Widget _renderBlock(TextBlock b, TextStyle base, Settings s, _ReaderColors colors, double screenH) {
    final gap = s.readerFontSize * s.readerParagraphGap;
    if (b.isImage) {
      return Padding(
        padding: EdgeInsets.symmetric(vertical: gap),
        child: ConstrainedBox(
          constraints: BoxConstraints(maxHeight: screenH * 0.85),
          child: Image.memory(b.image!, fit: BoxFit.contain, errorBuilder: (_, _, _) => const SizedBox()),
        ),
      );
    }
    final text = b.text ?? '';
    if (text.trim().isEmpty) return SizedBox(height: gap + s.readerFontSize * 0.6);
    if (b.heading > 0) {
      const scale = [1.0, 1.6, 1.45, 1.3, 1.15, 1.1, 1.05];
      return Padding(
        padding: EdgeInsets.only(top: gap * 2, bottom: gap * 1.5),
        child: Text(text,
            style: base.copyWith(fontSize: s.readerFontSize * scale[b.heading], fontWeight: FontWeight.bold, height: 1.4)),
      );
    }
    final t = Padding(padding: EdgeInsets.only(bottom: gap), child: Text(text, style: base));
    if (!b.quote) return t;
    return Container(
      margin: EdgeInsets.only(bottom: gap),
      padding: const EdgeInsets.only(left: 12),
      decoration: BoxDecoration(border: Border(left: BorderSide(color: colors.fg.withValues(alpha: 0.4), width: 3))),
      child: Text(text, style: base.copyWith(fontStyle: FontStyle.italic)),
    );
  }

  // ---------------- 목차 / 검색 / 설정 ----------------

  Widget _tocDrawer() {
    final toc = _doc!.toc;
    var currentToc = -1;
    for (var i = 0; i < toc.length; i++) {
      if (toc[i].block <= _current) currentToc = i;
    }
    return Drawer(
      child: SafeArea(
        child: Column(children: [
          ListTile(title: const Text('목차'), subtitle: Text('${toc.length}개 · ${_doc!.encoding}')),
          const Divider(height: 1),
          Expanded(
            child: toc.isEmpty
                ? const Center(child: Text('목차를 찾지 못했습니다'))
                : ListView.builder(
                    itemCount: toc.length,
                    itemBuilder: (_, i) => ListTile(
                      dense: true,
                      selected: i == currentToc,
                      title: Text(toc[i].title),
                      onTap: () {
                        Navigator.pop(context);
                        _jumpTo(toc[i].block);
                      },
                    ),
                  ),
          ),
        ]),
      ),
    );
  }

  Future<void> _openSearch() async {
    if (_doc == null) return;
    final target = await showDialog<int>(context: context, builder: (_) => _SearchDialog(_doc!.blocks));
    if (target != null) _jumpTo(target);
  }

  void _openSettings() {
    showModalBottomSheet(
      context: context,
      constraints: const BoxConstraints(maxWidth: 640),
      builder: (_) => Consumer<Settings>(
        builder: (context, s, _) => ListView(shrinkWrap: true, padding: const EdgeInsets.all(16), children: [
          Wrap(spacing: 8, children: [
            for (var i = 0; i < _themes.length; i++)
              ChoiceChip(
                avatar: CircleAvatar(backgroundColor: _themes[i].bg),
                label: Text(_themeNames[i]),
                selected: s.readerTheme == i,
                onSelected: (_) => s.readerTheme = i,
              ),
          ]),
          _slider('글자 크기', s.readerFontSize, 12, 40, (v) => s.readerFontSize = v, digits: 0),
          _slider('줄 간격', s.readerLineHeight, 1.2, 2.6, (v) => s.readerLineHeight = v),
          _slider('문단 간격', s.readerParagraphGap, 0, 1.5, (v) => s.readerParagraphGap = v),
          _slider('본문 최대 폭', s.readerMaxWidth, 420, 1600, (v) => s.readerMaxWidth = v, digits: 0),
          Text('인코딩: ${_doc?.encoding ?? '-'}', style: Theme.of(context).textTheme.bodySmall),
        ]),
      ),
    );
  }

  Widget _slider(String label, double value, double min, double max, ValueChanged<double> onChanged, {int digits = 1}) =>
      Row(children: [
        SizedBox(width: 90, child: Text(label)),
        Expanded(child: Slider(value: value.clamp(min, max), min: min, max: max, onChanged: onChanged)),
        SizedBox(width: 44, child: Text(value.toStringAsFixed(digits))),
      ]);
}

/// 화면에 붙어 있는 동안 자신의 위치를 registry 에 등록
class _BlockItem extends StatefulWidget {
  final int index;
  final Map<int, BuildContext> registry;
  final Widget child;
  const _BlockItem({super.key, required this.index, required this.registry, required this.child});

  @override
  State<_BlockItem> createState() => _BlockItemState();
}

class _BlockItemState extends State<_BlockItem> {
  @override
  void initState() {
    super.initState();
    widget.registry[widget.index] = context;
  }

  @override
  void dispose() {
    if (identical(widget.registry[widget.index], context)) widget.registry.remove(widget.index);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => widget.child;
}

class _SearchDialog extends StatefulWidget {
  final List<TextBlock> blocks;
  const _SearchDialog(this.blocks);
  @override
  State<_SearchDialog> createState() => _SearchDialogState();
}

class _SearchDialogState extends State<_SearchDialog> {
  final _q = TextEditingController();
  List<(int, String)> _hits = [];

  void _search() {
    final q = _q.text.trim().toLowerCase();
    if (q.isEmpty) return;
    final hits = <(int, String)>[];
    for (var i = 0; i < widget.blocks.length && hits.length < 300; i++) {
      final t = widget.blocks[i].text;
      if (t == null) continue;
      final at = t.toLowerCase().indexOf(q);
      if (at < 0) continue;
      final from = (at - 30).clamp(0, t.length);
      final to = (at + q.length + 50).clamp(0, t.length);
      hits.add((i, '${from > 0 ? '…' : ''}${t.substring(from, to)}${to < t.length ? '…' : ''}'));
    }
    setState(() => _hits = hits);
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
        title: TextField(
          controller: _q,
          autofocus: true,
          onSubmitted: (_) => _search(),
          decoration: InputDecoration(
            hintText: '본문에서 찾기',
            suffixIcon: IconButton(icon: const Icon(Icons.search), onPressed: _search),
          ),
        ),
        content: SizedBox(
          width: 560,
          height: 420,
          child: _hits.isEmpty
              ? const Center(child: Text('검색어를 입력하세요'))
              : ListView.builder(
                  itemCount: _hits.length,
                  itemBuilder: (_, i) => ListTile(
                    dense: true,
                    title: Text(_hits[i].$2, maxLines: 2, overflow: TextOverflow.ellipsis),
                    onTap: () => Navigator.pop(context, _hits[i].$1),
                  ),
                ),
        ),
        actions: [TextButton(onPressed: () => Navigator.pop(context), child: const Text('닫기'))],
      );
}
