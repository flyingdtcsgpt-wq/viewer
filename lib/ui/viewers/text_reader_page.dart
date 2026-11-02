import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../../app_state.dart';
import '../../models/media_item.dart';
import '../../services/settings.dart';
import '../../services/text_document.dart';
import '../cover_tile.dart';
import 'open_item.dart';
import 'viewer_chrome.dart';

/// TXT / EPUB 뷰어 — BookManager 스타일
/// 왼쪽: 목차·하이라이트·검색 / 위: 도구줄 / 오른쪽: 뷰어 설정 / 아래: 장(章) 줄
///
/// 긴 소설(수 MB)도 빠르게 열리도록 문단 단위로 지연 렌더링한다.
/// 특정 위치로 이동할 때는 "기준 블록(anchor)"을 바꿔서 그 블록부터 그리는 방식(center sliver).
class TextReaderPage extends StatefulWidget {
  final MediaItem item;
  const TextReaderPage({super.key, required this.item});

  @override
  State<TextReaderPage> createState() => _TextReaderPageState();
}

class ReaderTheme {
  final String name;
  final Color bg, fg;
  const ReaderTheme(this.name, this.bg, this.fg);
}

const readerThemes = [
  ReaderTheme('원본', Color(0xFFFAFAFA), Color(0xFF222222)),
  ReaderTheme('다크', Color(0xFF1E1E1E), Color(0xFFDDDDDD)),
  ReaderTheme('블랙', Color(0xFF000000), Color(0xFFB0B0B0)),
  ReaderTheme('종이', Color(0xFFF3EEE3), Color(0xFF333333)),
  ReaderTheme('세피아', Color(0xFFF4ECD8), Color(0xFF5B4636)),
  ReaderTheme('화이트', Color(0xFFFFFFFF), Color(0xFF111111)),
  ReaderTheme('그린', Color(0xFFE3EEDC), Color(0xFF2E3B2C)),
];

/// 하이라이트 색 (마지막은 밑줄)
const hlColors = [Color(0xFFFFD54F), Color(0xFF81C784), Color(0xFF64B5F6), Color(0xFFF48FB1), Color(0xFFB39DDB)];

class _TextReaderPageState extends State<TextReaderPage> {
  final _viewKey = GlobalKey();
  final _ctrl = ScrollController();
  final _alive = <int, BuildContext>{}; // 화면에 붙어 있는 블록들
  final _focus = FocusNode();
  final _searchCtrl = TextEditingController();

  TextDocument? _doc;
  Object? _error;
  int _anchor = 0;
  Key _centerKey = UniqueKey();
  int _current = 0;
  Timer? _saveTimer;

  bool _left = false; // 왼쪽 목차 패널
  int _leftTab = 0; // 0 목차, 1 하이라이트, 2 검색결과
  bool _right = false; // 오른쪽 설정 패널
  bool _chrome = true;
  bool _fullscreen = false;
  bool _selectMode = false; // 글자 선택(하이라이트) 모드
  String _selected = '';
  List<(int, String)> _hits = [];

  late final AppState _app = context.read<AppState>();

  MediaItem get item => widget.item;
  int get _count => _doc?.blocks.length ?? 0;
  double get _progress => _count <= 1 ? 1 : _current / (_count - 1);

  @override
  void initState() {
    super.initState();
    _app; // dispose 에서 context 를 쓰지 않도록 미리 잡아둔다
    _left = WidgetsBinding.instance.platformDispatcher.views.first.physicalSize.width /
            WidgetsBinding.instance.platformDispatcher.views.first.devicePixelRatio >=
        1200; // 넓은 화면이면 처음부터 목차를 연다
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
    if (_fullscreen) SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
    _ctrl.dispose();
    _focus.dispose();
    _searchCtrl.dispose();
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
    _saveTimer = Timer(const Duration(seconds: 1), () => _app.saveProgress(item, '$_current', _progress));
  }

  void _page(int dir) {
    if (!_ctrl.hasClients) return;
    final pos = _ctrl.position;
    final target = (pos.pixels + dir * pos.viewportDimension * 0.9).clamp(pos.minScrollExtent, pos.maxScrollExtent);
    _ctrl.animateTo(target, duration: const Duration(milliseconds: 180), curve: Curves.easeOut);
  }

  int get _tocIndex {
    final toc = _doc?.toc ?? const <TocEntry>[];
    var cur = -1;
    for (var i = 0; i < toc.length; i++) {
      if (toc[i].block <= _current) cur = i;
    }
    return cur;
  }

  void _chapter(int d) {
    final toc = _doc?.toc ?? const <TocEntry>[];
    if (toc.isEmpty) return;
    final t = (_tocIndex + d).clamp(0, toc.length - 1);
    _jumpTo(toc[t].block);
  }

  void _toggleFullscreen() {
    setState(() {
      _fullscreen = !_fullscreen;
      _chrome = !_fullscreen;
    });
    SystemChrome.setEnabledSystemUIMode(_fullscreen ? SystemUiMode.immersiveSticky : SystemUiMode.edgeToEdge);
  }

  void _search(String q) {
    final query = q.trim().toLowerCase();
    if (query.isEmpty || _doc == null) return;
    final hits = <(int, String)>[];
    final blocks = _doc!.blocks;
    for (var i = 0; i < blocks.length && hits.length < 500; i++) {
      final t = blocks[i].text;
      if (t == null) continue;
      final at = t.toLowerCase().indexOf(query);
      if (at < 0) continue;
      final from = (at - 30).clamp(0, t.length);
      final to = (at + query.length + 50).clamp(0, t.length);
      hits.add((i, '${from > 0 ? '…' : ''}${t.substring(from, to)}${to < t.length ? '…' : ''}'));
    }
    setState(() {
      _hits = hits;
      _leftTab = 2;
      _left = true;
    });
  }

  String? get _fontFamily => switch (context.read<Settings>().readerFont) {
        1 => Platform.isWindows ? 'Batang' : 'serif',
        2 => Platform.isWindows ? 'Malgun Gothic' : 'sans-serif',
        _ => null,
      };

  // ---------------- 화면 ----------------

  @override
  Widget build(BuildContext context) {
    final s = context.watch<Settings>();
    final theme = readerThemes[s.readerTheme.clamp(0, readerThemes.length - 1)];
    final wide = MediaQuery.sizeOf(context).width >= 900;

    Widget body;
    if (_error != null) {
      body = Center(child: Text('열 수 없습니다: $_error', style: TextStyle(color: theme.fg)));
    } else if (_doc == null) {
      body = const Center(child: CircularProgressIndicator());
    } else if (_count == 0) {
      body = Center(child: Text('내용이 없습니다', style: TextStyle(color: theme.fg)));
    } else {
      body = _buildText(s, theme);
    }

    final page = Container(
      color: theme.bg,
      child: Column(children: [
        Expanded(child: body),
        if (_chrome && s.viewerSlider && (_doc?.toc.isNotEmpty ?? false)) _chapterStrip(),
      ]),
    );

    return CallbackShortcuts(
      bindings: {
        const SingleActivator(LogicalKeyboardKey.pageDown): () => _page(1),
        const SingleActivator(LogicalKeyboardKey.space): () => _page(1),
        const SingleActivator(LogicalKeyboardKey.arrowRight): () => _page(s.comicRtl ? -1 : 1),
        const SingleActivator(LogicalKeyboardKey.pageUp): () => _page(-1),
        const SingleActivator(LogicalKeyboardKey.arrowLeft): () => _page(s.comicRtl ? 1 : -1),
        const SingleActivator(LogicalKeyboardKey.space, shift: true): () => _page(-1),
        const SingleActivator(LogicalKeyboardKey.home): () => _jumpTo(0),
        const SingleActivator(LogicalKeyboardKey.end): () => _jumpTo(_count - 1),
        const SingleActivator(LogicalKeyboardKey.keyF, control: true): () => setState(() {
              _left = true;
              _leftTab = 2;
            }),
        const SingleActivator(LogicalKeyboardKey.keyF): _toggleFullscreen,
        const SingleActivator(LogicalKeyboardKey.keyB): () => s.toggleBookmark(item.id!, _current),
        const SingleActivator(LogicalKeyboardKey.equal, control: true): () => s.readerFontSize = (s.readerFontSize + 1).clamp(12, 40),
        const SingleActivator(LogicalKeyboardKey.minus, control: true): () => s.readerFontSize = (s.readerFontSize - 1).clamp(12, 40),
        const SingleActivator(LogicalKeyboardKey.escape): () {
          if (_right || (_left && !wide)) {
            setState(() => _right = _left = false);
          } else if (_fullscreen) {
            _toggleFullscreen();
          } else {
            Navigator.maybePop(context);
          }
        },
      },
      child: Focus(
        focusNode: _focus,
        autofocus: true,
        child: Scaffold(
          backgroundColor: viewerBg,
          body: SafeArea(
            child: Column(children: [
              if (_chrome) _topBar(s, wide),
              Expanded(
                child: wide
                    ? Row(children: [
                        if (_left) _leftPanel(s, theme),
                        Expanded(child: page),
                        if (_right) _settingsPanel(s),
                      ])
                    : Stack(children: [
                        Positioned.fill(child: page),
                        // 좁은 화면: 패널을 위에 겹쳐서
                        if (_left) Positioned(left: 0, top: 0, bottom: 0, child: Material(elevation: 8, child: _leftPanel(s, theme))),
                        if (_right) Positioned(right: 0, top: 0, bottom: 0, child: Material(elevation: 8, child: _settingsPanel(s))),
                      ]),
              ),
            ]),
          ),
        ),
      ),
    );
  }

  // ---------- 위 도구줄 ----------
  Widget _topBar(Settings s, bool wide) {
    final marked = s.bookmarks(item.id!).contains(_current);
    final toc = _doc?.toc ?? const <TocEntry>[];
    return Container(
      color: const Color(0xFF141414),
      padding: const EdgeInsets.fromLTRB(8, 6, 8, 6),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          IconButton(
            style: IconButton.styleFrom(backgroundColor: _left ? toolActive : toolBg),
            tooltip: '목차 · 하이라이트 · 검색',
            icon: const Icon(Icons.tune, color: Colors.white),
            onPressed: () => setState(() => _left = !_left),
          ),
          const SizedBox(width: 10),
          Flexible(
            child: Text(item.fileName,
                overflow: TextOverflow.ellipsis, style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w700, fontSize: 15)),
          ),
          const SizedBox(width: 8),
          Text(
            toc.isEmpty ? '${(_progress * 100).toStringAsFixed(1)}%' : '${_tocIndex + 1} / ${toc.length} · ${(_progress * 100).round()}%',
            style: const TextStyle(color: Colors.white60, fontSize: 12),
          ),
          NextVolumeButton(item: item),
          const Spacer(),
          IconButton(tooltip: '닫기', icon: const Icon(Icons.close, color: Colors.white70), onPressed: () => Navigator.maybePop(context)),
        ]),
        const SizedBox(height: 4),
        SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          reverse: wide,
          child: Row(children: [
            ToolGroup([
              ToolBtn(icon: Icons.keyboard_double_arrow_left, tooltip: '이전 장', onTap: toc.isEmpty ? null : () => _chapter(-1), enabled: toc.isNotEmpty),
              ToolBtn(icon: Icons.keyboard_double_arrow_right, tooltip: '다음 장', onTap: toc.isEmpty ? null : () => _chapter(1), enabled: toc.isNotEmpty),
            ]),
            ToolGroup([
              ToolBtn(icon: Icons.chevron_left, tooltip: '이전 화면 (PgUp)', onTap: () => _page(-1)),
              ToolBtn(icon: Icons.chevron_right, tooltip: '다음 화면 (PgDn)', onTap: () => _page(1)),
            ]),
            ToolGroup([
              ToolBtn(icon: Icons.text_decrease, tooltip: '글자 작게 (Ctrl -)', onTap: () => s.readerFontSize = (s.readerFontSize - 1).clamp(12, 40)),
              ToolBtn(label: '${(s.readerFontSize / 18 * 100).round()}%', tooltip: '글자 크기'),
              ToolBtn(icon: Icons.text_increase, tooltip: '글자 크게 (Ctrl +)', onTap: () => s.readerFontSize = (s.readerFontSize + 1).clamp(12, 40)),
            ]),
            ToolGroup([
              ToolBtn(
                icon: Icons.border_color,
                label: '선택',
                tooltip: '글자 선택 → 하이라이트 · 복사 · 검색',
                active: _selectMode,
                onTap: () => setState(() => _selectMode = !_selectMode),
              ),
            ]),
            ToolGroup([
              ToolBtn(icon: Icons.manage_search, tooltip: '책에서 찾기 (Ctrl+F)', onTap: () => setState(() {
                    _left = true;
                    _leftTab = 2;
                  })),
            ]),
            ToolGroup([
              ToolBtn(
                icon: marked ? Icons.bookmark : Icons.bookmark_border,
                tooltip: '책갈피 (B)',
                active: marked,
                onTap: () => s.toggleBookmark(item.id!, _current),
              ),
            ]),
            ToolGroup([ToolBtn(icon: _fullscreen ? Icons.fullscreen_exit : Icons.fullscreen, tooltip: '전체화면 (F)', onTap: _toggleFullscreen)]),
            ToolGroup([
              ToolBtn(
                icon: Icons.help_outline,
                tooltip: '단축키',
                onTap: () => showViewerHelp(context, const [
                  ('← → / PgUp PgDn', '한 화면씩 넘기기'),
                  ('Space / Shift+Space', '다음 / 이전 화면'),
                  ('Home / End', '처음 / 끝'),
                  ('Ctrl + / Ctrl -', '글자 크게 / 작게'),
                  ('Ctrl+F', '책에서 찾기'),
                  ('F', '전체화면'),
                  ('B', '책갈피'),
                  ('Esc', '패널 닫기 · 나가기'),
                ]),
              ),
            ]),
            ToolGroup([ToolBtn(icon: Icons.settings, tooltip: '뷰어 설정', active: _right, onTap: () => setState(() => _right = !_right))]),
          ]),
        ),
      ]),
    );
  }

  // ---------- 본문 ----------
  Widget _buildText(Settings s, ReaderTheme theme) {
    final blocks = _doc!.blocks;
    final base = TextStyle(fontSize: s.readerFontSize, height: s.readerLineHeight, color: theme.fg, fontFamily: _fontFamily);
    final screenH = MediaQuery.sizeOf(context).height;
    final hls = s.highlights(item.id!);

    Widget itemAt(int i) => _BlockItem(
          key: ValueKey(i),
          index: i,
          registry: _alive,
          child: _renderBlock(blocks[i], base, s, theme, screenH, hls),
        );

    return LayoutBuilder(builder: (context, c) {
      final hPad = ((c.maxWidth - s.readerMaxWidth) / 2).clamp(20.0, double.infinity);
      Widget list = NotificationListener<ScrollNotification>(
        onNotification: (n) {
          if (n is ScrollEndNotification) _updateCurrent();
          return false;
        },
        child: CustomScrollView(
          key: _viewKey,
          controller: _ctrl,
          center: _centerKey,
          slivers: [
            SliverPadding(
              padding: EdgeInsets.symmetric(horizontal: hPad),
              sliver: SliverList(delegate: SliverChildBuilderDelegate((_, i) => itemAt(_anchor - 1 - i), childCount: _anchor)),
            ),
            SliverPadding(
              key: _centerKey,
              padding: EdgeInsets.fromLTRB(hPad, 0, hPad, screenH * 0.5),
              sliver: SliverList(delegate: SliverChildBuilderDelegate((_, i) => itemAt(_anchor + i), childCount: blocks.length - _anchor)),
            ),
          ],
        ),
      );

      // 선택 모드: 글자를 끌어서 고르면 하이라이트 메뉴
      if (_selectMode) {
        return SelectionArea(
          onSelectionChanged: (c) => _selected = c?.plainText ?? '',
          contextMenuBuilder: (ctx, state) => AdaptiveTextSelectionToolbar(
            anchors: state.contextMenuAnchors,
            children: [_SelectionMenu(onPick: (action, color) => _onSelectionAction(action, color, state))],
          ),
          child: list,
        );
      }

      return GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTapUp: (d) {
          final x = d.localPosition.dx / c.maxWidth;
          final next = s.comicRtl ? -1 : 1;
          if (s.tapToTurn && x < 0.25) {
            _page(-next);
          } else if (s.tapToTurn && x > 0.75) {
            _page(next);
          } else {
            setState(() => _chrome = !_chrome);
          }
        },
        onHorizontalDragEnd: (d) {
          final v = d.primaryVelocity ?? 0;
          if (v.abs() < 250) return;
          _page((v < 0) != s.comicRtl ? 1 : -1);
        },
        child: list,
      );
    });
  }

  void _onSelectionAction(String action, int color, SelectableRegionState state) {
    final text = _selected.trim();
    state.hideToolbar();
    if (text.isEmpty) return;
    final s = context.read<Settings>();
    switch (action) {
      case 'hl':
        for (final line in text.split('\n').map((e) => e.trim()).where((e) => e.isNotEmpty)) {
          s.addHighlight(item.id!, color, line);
        }
      case 'copy':
        Clipboard.setData(ClipboardData(text: text));
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('복사했습니다')));
      case 'search':
        _searchCtrl.text = text;
        _search(text);
      case 'ai':
        _askAi(text);
    }
    state.clearSelection();
  }

  Future<void> _askAi(String text) async {
    if (!_app.ai.enabled) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('설정에서 Claude API 키를 넣으면 뜻풀이·번역을 쓸 수 있습니다')));
      return;
    }
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('AI 뜻풀이 / 번역'),
        content: SizedBox(
          width: 480,
          child: FutureBuilder<String>(
            future: _app.ai.chat('다음 문장의 뜻을 쉽게 풀이하고, 외국어면 한국어로 번역해줘:\n"$text"', const []),
            builder: (_, snap) => snap.hasData
                ? SingleChildScrollView(child: SelectableText(snap.data!))
                : snap.hasError
                    ? Text('실패: ${snap.error}')
                    : const Padding(padding: EdgeInsets.all(24), child: Center(child: CircularProgressIndicator())),
          ),
        ),
        actions: [TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('닫기'))],
      ),
    );
  }

  Widget _renderBlock(TextBlock b, TextStyle base, Settings s, ReaderTheme theme, double screenH, List<(int, String)> hls) {
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
        child: Text(text, style: base.copyWith(fontSize: s.readerFontSize * scale[b.heading], fontWeight: FontWeight.bold, height: 1.4)),
      );
    }
    final rich = Text.rich(_highlighted(text, base, hls));
    final t = Padding(padding: EdgeInsets.only(bottom: gap), child: rich);
    if (!b.quote) return t;
    return Container(
      margin: EdgeInsets.only(bottom: gap),
      padding: const EdgeInsets.only(left: 12),
      decoration: BoxDecoration(border: Border(left: BorderSide(color: theme.fg.withValues(alpha: 0.4), width: 3))),
      child: Text.rich(_highlighted(text, base.copyWith(fontStyle: FontStyle.italic), hls)),
    );
  }

  /// 저장된 하이라이트 문장이 이 문단에 있으면 색칠
  TextSpan _highlighted(String text, TextStyle base, List<(int, String)> hls) {
    final ranges = <(int, int, int)>[]; // start, end, color
    for (final (color, h) in hls) {
      if (h.length < 2) continue;
      var from = 0;
      while (true) {
        final at = text.indexOf(h, from);
        if (at < 0) break;
        ranges.add((at, at + h.length, color));
        from = at + h.length;
      }
    }
    if (ranges.isEmpty) return TextSpan(text: text, style: base);
    ranges.sort((a, b) => a.$1.compareTo(b.$1));
    final spans = <TextSpan>[];
    var pos = 0;
    for (final (st, en, color) in ranges) {
      if (st < pos) continue;
      if (st > pos) spans.add(TextSpan(text: text.substring(pos, st)));
      spans.add(TextSpan(
        text: text.substring(st, en),
        style: color >= hlColors.length
            ? const TextStyle(decoration: TextDecoration.underline, decorationThickness: 2)
            : TextStyle(backgroundColor: hlColors[color].withValues(alpha: 0.45)),
      ));
      pos = en;
    }
    if (pos < text.length) spans.add(TextSpan(text: text.substring(pos)));
    return TextSpan(style: base, children: spans);
  }

  // ---------- 아래 장(章) 줄 ----------
  Widget _chapterStrip() {
    final toc = _doc!.toc;
    final cur = _tocIndex;
    return Container(
      height: 86,
      color: const Color(0xFF141414),
      child: ListView.builder(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
        itemCount: toc.length,
        itemBuilder: (_, i) {
          final on = i == cur;
          return GestureDetector(
            onTap: () => _jumpTo(toc[i].block),
            child: Container(
              width: 120,
              margin: const EdgeInsets.symmetric(horizontal: 4),
              padding: const EdgeInsets.all(8),
              decoration: BoxDecoration(
                color: on ? toolActive.withValues(alpha: 0.25) : toolBg,
                borderRadius: BorderRadius.circular(6),
                border: Border.all(color: on ? toolActive : Colors.white12, width: on ? 2 : 1),
              ),
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text('${i + 1}', style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w800)),
                const SizedBox(height: 2),
                Expanded(
                  child: Text(toc[i].title, maxLines: 2, overflow: TextOverflow.ellipsis, style: const TextStyle(color: Colors.white70, fontSize: 11)),
                ),
              ]),
            ),
          );
        },
      ),
    );
  }

  // ---------- 왼쪽 패널 ----------
  Widget _leftPanel(Settings s, ReaderTheme theme) {
    final toc = _doc?.toc ?? const <TocEntry>[];
    final hls = s.highlights(item.id!);
    final marks = s.bookmarks(item.id!);
    final cur = _tocIndex;
    final blocks = _doc?.blocks ?? const <TextBlock>[];

    Widget tab(int i, String label) => Expanded(
          child: Material(
            color: _leftTab == i ? toolActive : toolBg,
            child: InkWell(
              onTap: () => setState(() => _leftTab = i),
              child: Padding(
                padding: const EdgeInsets.symmetric(vertical: 10),
                child: Text(label, textAlign: TextAlign.center, style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w600)),
              ),
            ),
          ),
        );

    Widget list;
    switch (_leftTab) {
      case 0:
        list = toc.isEmpty
            ? const Center(child: Text('목차를 찾지 못했습니다', style: TextStyle(color: Colors.white54)))
            : ListView.builder(
                itemCount: toc.length,
                itemBuilder: (_, i) => Material(
                  color: i == cur ? toolActive.withValues(alpha: 0.3) : Colors.transparent,
                  child: ListTile(
                    dense: true,
                    title: Text(toc[i].title, style: const TextStyle(color: Colors.white)),
                    trailing: Text('${(toc[i].block / blocks.length.clamp(1, 1 << 30) * 100).round()}%',
                        style: const TextStyle(color: Colors.white38, fontSize: 11)),
                    onTap: () => _jumpTo(toc[i].block),
                  ),
                ),
              );
      case 1:
        list = ListView(children: [
          if (marks.isNotEmpty) ...[
            const Padding(padding: EdgeInsets.fromLTRB(16, 12, 16, 4), child: Text('책갈피', style: TextStyle(color: Colors.white54))),
            for (final m in marks)
              ListTile(
                dense: true,
                leading: const Icon(Icons.bookmark, color: Colors.redAccent, size: 18),
                title: Text(
                  m < blocks.length ? (blocks[m].text ?? '(그림)') : '$m',
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(color: Colors.white),
                ),
                onTap: () => _jumpTo(m),
                trailing: IconButton(
                  icon: const Icon(Icons.close, size: 16, color: Colors.white38),
                  onPressed: () => s.toggleBookmark(item.id!, m),
                ),
              ),
          ],
          const Padding(padding: EdgeInsets.fromLTRB(16, 12, 16, 4), child: Text('하이라이트', style: TextStyle(color: Colors.white54))),
          if (hls.isEmpty)
            const Padding(
              padding: EdgeInsets.all(16),
              child: Text('도구줄의 "선택"을 켜고 글자를 끌어 고르면 색을 칠할 수 있습니다.', style: TextStyle(color: Colors.white38)),
            ),
          for (final (color, text) in hls)
            ListTile(
              dense: true,
              leading: Icon(color >= hlColors.length ? Icons.format_underline : Icons.circle,
                  size: 14, color: color >= hlColors.length ? Colors.white : hlColors[color]),
              title: Text(text, maxLines: 3, overflow: TextOverflow.ellipsis, style: const TextStyle(color: Colors.white)),
              onTap: () {
                final at = blocks.indexWhere((b) => (b.text ?? '').contains(text));
                if (at >= 0) _jumpTo(at);
              },
              trailing: IconButton(
                icon: const Icon(Icons.close, size: 16, color: Colors.white38),
                onPressed: () => s.removeHighlight(item.id!, text),
              ),
            ),
        ]);
      default:
        list = _hits.isEmpty
            ? const Center(child: Text('위 칸에 찾을 말을 넣고 Enter', style: TextStyle(color: Colors.white54)))
            : ListView.builder(
                itemCount: _hits.length,
                itemBuilder: (_, i) => ListTile(
                  dense: true,
                  title: Text(_hits[i].$2, maxLines: 2, overflow: TextOverflow.ellipsis, style: const TextStyle(color: Colors.white)),
                  onTap: () => _jumpTo(_hits[i].$1),
                ),
              );
    }

    return Container(
      width: 320,
      color: const Color(0xFF1C1C1C),
      child: Column(children: [
        Padding(
          padding: const EdgeInsets.all(14),
          child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
            SizedBox(width: 64, height: 92, child: ClipRRect(borderRadius: BorderRadius.circular(4), child: CoverImage(item: item))),
            const SizedBox(width: 12),
            Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Row(children: [
                  Expanded(
                    child: Text(item.title, maxLines: 2, overflow: TextOverflow.ellipsis,
                        style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w800)),
                  ),
                  InkWell(onTap: () => setState(() => _left = false), child: const Icon(Icons.close, color: Colors.white54, size: 20)),
                ]),
                if (item.author != null) Text(item.author!, style: const TextStyle(color: Colors.white54, fontSize: 12)),
                const SizedBox(height: 8),
                SizedBox(
                  height: 36,
                  child: TextField(
                    controller: _searchCtrl,
                    style: const TextStyle(color: Colors.white, fontSize: 13),
                    onSubmitted: _search,
                    decoration: InputDecoration(
                      isDense: true,
                      hintText: '책에서 찾기',
                      hintStyle: const TextStyle(color: Colors.white38),
                      filled: true,
                      fillColor: Colors.black26,
                      prefixIcon: const Icon(Icons.search, size: 18, color: Colors.white54),
                      border: OutlineInputBorder(borderRadius: BorderRadius.circular(6), borderSide: BorderSide.none),
                    ),
                  ),
                ),
              ]),
            ),
          ]),
        ),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12),
          child: ClipRRect(
            borderRadius: BorderRadius.circular(8),
            child: Row(children: [tab(0, '목차'), tab(1, '하이라이트'), tab(2, '검색결과')]),
          ),
        ),
        const SizedBox(height: 6),
        Expanded(child: list),
      ]),
    );
  }

  // ---------- 오른쪽 뷰어 설정 ----------
  Widget _settingsPanel(Settings s) => ViewerSettingsPanel(
        onClose: () => setState(() => _right = false),
        children: [
          const PanelSection('읽기'),
          const Text('테마', style: TextStyle(color: Colors.white70, fontSize: 13, fontWeight: FontWeight.w600)),
          const SizedBox(height: 6),
          GridView.count(
            crossAxisCount: 2,
            shrinkWrap: true,
            physics: const NeverScrollableScrollPhysics(),
            mainAxisSpacing: 8,
            crossAxisSpacing: 8,
            childAspectRatio: 3.4,
            children: [
              for (var i = 0; i < readerThemes.length; i++)
                Material(
                  color: toolBg,
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(8),
                    side: BorderSide(color: s.readerTheme == i ? toolActive : Colors.white12, width: s.readerTheme == i ? 2 : 1),
                  ),
                  child: InkWell(
                    onTap: () => s.readerTheme = i,
                    child: Row(children: [
                      const SizedBox(width: 12),
                      Container(
                        width: 22,
                        height: 22,
                        decoration: BoxDecoration(
                          shape: BoxShape.circle,
                          gradient: LinearGradient(colors: [readerThemes[i].bg, readerThemes[i].bg, readerThemes[i].fg, readerThemes[i].fg], stops: const [0, 0.5, 0.5, 1]),
                          border: Border.all(color: Colors.white38),
                        ),
                      ),
                      const SizedBox(width: 10),
                      Text(readerThemes[i].name, style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w600)),
                    ]),
                  ),
                ),
            ],
          ),
          const SizedBox(height: 14),
          SegmentRow<int>(
            title: '글꼴',
            value: s.readerFont,
            onChanged: (v) => s.readerFont = v,
            options: const [(0, null, '기본'), (1, null, '명조'), (2, null, '고딕')],
          ),
          _slider('글자 크기', s.readerFontSize, 12, 40, (v) => s.readerFontSize = v, digits: 0),
          _slider('줄 간격', s.readerLineHeight, 1.2, 2.6, (v) => s.readerLineHeight = v),
          _slider('문단 간격', s.readerParagraphGap, 0, 1.5, (v) => s.readerParagraphGap = v),
          _slider('본문 폭', s.readerMaxWidth, 420, 1600, (v) => s.readerMaxWidth = v, digits: 0),
          const Divider(color: Colors.white12, height: 28),
          const PanelSection('넘기기'),
          SegmentRow<bool>(
            title: '읽기방향 (좌우 밀기·방향키)',
            value: s.comicRtl,
            onChanged: (v) => s.comicRtl = v,
            options: const [(false, Icons.east, '왼쪽에서 오른쪽'), (true, Icons.west, '오른쪽에서 왼쪽')],
          ),
          SegmentRow<bool>(
            title: '화면 좌우 눌러 넘기기',
            value: s.tapToTurn,
            onChanged: (v) => s.tapToTurn = v,
            options: const [(true, null, '켜기'), (false, null, '끄기')],
          ),
          SegmentRow<bool>(
            title: '아래 장 탐색 바',
            value: s.viewerSlider,
            onChanged: (v) => s.viewerSlider = v,
            options: const [(true, Icons.view_carousel, '표시'), (false, Icons.visibility_off, '숨기기')],
          ),
          Text('인코딩: ${_doc?.encoding ?? '-'}', style: const TextStyle(color: Colors.white38, fontSize: 12)),
        ],
      );

  Widget _slider(String label, double value, double min, double max, ValueChanged<double> onChanged, {int digits = 1}) => Row(children: [
        SizedBox(width: 72, child: Text(label, style: const TextStyle(color: Colors.white70, fontSize: 13))),
        Expanded(child: Slider(value: value.clamp(min, max), min: min, max: max, onChanged: onChanged)),
        SizedBox(width: 40, child: Text(value.toStringAsFixed(digits), style: const TextStyle(color: Colors.white70))),
      ]);
}

/// 글자를 고르면 나오는 메뉴: 색 5가지 + 밑줄 / 복사 / 책에서 검색 / AI 뜻풀이
class _SelectionMenu extends StatelessWidget {
  final void Function(String action, int color) onPick;
  const _SelectionMenu({required this.onPick});

  @override
  Widget build(BuildContext context) => Material(
        color: const Color(0xFF2B2B2B),
        borderRadius: BorderRadius.circular(10),
        child: Padding(
          padding: const EdgeInsets.all(8),
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            Row(mainAxisSize: MainAxisSize.min, children: [
              for (var i = 0; i < hlColors.length; i++)
                IconButton(
                  tooltip: '하이라이트',
                  icon: Icon(Icons.circle, color: hlColors[i]),
                  onPressed: () => onPick('hl', i),
                ),
              IconButton(
                tooltip: '밑줄',
                icon: const Icon(Icons.format_underline, color: Colors.white),
                onPressed: () => onPick('hl', hlColors.length),
              ),
            ]),
            Row(mainAxisSize: MainAxisSize.min, children: [
              _btn(Icons.content_copy, '복사', () => onPick('copy', 0)),
              _btn(Icons.search, '검색', () => onPick('search', 0)),
              _btn(Icons.translate, 'AI 뜻풀이', () => onPick('ai', 0)),
            ]),
          ]),
        ),
      );

  Widget _btn(IconData icon, String label, VoidCallback f) => InkWell(
        onTap: f,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
          child: Column(children: [
            Icon(icon, color: Colors.white, size: 20),
            Text(label, style: const TextStyle(color: Colors.white, fontSize: 11)),
          ]),
        ),
      );
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
