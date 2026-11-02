import 'dart:convert';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:archive/archive_io.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;
import 'package:provider/provider.dart';

import '../../app_state.dart';
import '../../models/media_item.dart';
import '../../services/ext_archive.dart';
import '../../services/ocr_service.dart';
import '../../services/settings.dart';
import 'open_item.dart';
import 'read_aloud.dart';
import 'viewer_chrome.dart';

/// 만화(CBZ/ZIP) 뷰어 — BookManager 스타일
/// 위: 도구줄 / 가운데: 쪽 / 오른쪽: 뷰어 설정 / 아래: 썸네일 줄
class ComicReaderPage extends StatefulWidget {
  final MediaItem item;
  const ComicReaderPage({super.key, required this.item});

  @override
  State<ComicReaderPage> createState() => _ComicReaderPageState();
}

class _ComicReaderPageState extends State<ComicReaderPage> {
  late final AppState _app = context.read<AppState>();
  late final Settings _s = context.read<Settings>();
  InputFileStream? _input;
  List<ArchiveFile> _files = [];
  List<String>? _ext; // RAR/7Z: 압축 안 이미지 이름들 (풀지 않고 한 쪽씩 꺼내 읽음)
  PageLoader? _loader;
  // 아직 안 읽힌 쪽 자리에 잠깐 보여줄 투명 그림
  static final _blank = base64Decode('iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNkYAAAAAYAAjCB0C8AAAAASUVORK5CYII=');
  bool _loading = true;
  int get _n => _ext?.length ?? _files.length;
  final _cache = <int, Uint8List>{};
  Object? _error;

  int _page = 0; // 0부터
  int _dir = 1; // 마지막 이동 방향 (애니메이션용)
  bool _panel = false; // 오른쪽 설정 패널
  bool _chrome = true; // 위/아래 막대
  bool _fullscreen = false;
  bool _readAloud = false;
  final _zoom = TransformationController();
  final _strip = ScrollController();
  final _scroll = ScrollController(); // 세로 스크롤(웹툰) 모드
  final _pageKeys = <int, GlobalKey>{};
  final _focus = FocusNode();

  MediaItem get item => widget.item;
  double get _progress => _n <= 1 ? 1 : _page / (_n - 1);
  double get _scale => _zoom.value.getMaxScaleOnAxis();

  @override
  void initState() {
    super.initState();
    _app;
    _s;
    _open();
    _zoom.addListener(() => setState(() {}));
  }

  Future<void> _open() async {
    try {
      if (ExtArchive.handles(item.path)) {
        // RAR / 7Z: Windows 내장 tar 로 임시 폴더에 풀어서 읽는다
        _ext = await ExtArchive.listImages(item.path);
        _loader = PageLoader(item.path, _ext!, (i, b) {
          if (!mounted) return;
          setState(() => _cache[i] = b);
          _trim();
        });
      } else {
        _input = InputFileStream(item.path);
        final zip = ZipDecoder().decodeStream(_input!);
        _files = zip.files.where((f) => f.isFile && imageExts.contains(p.extension(f.name).toLowerCase())).toList()
          ..sort((a, b) => _natural(a.name, b.name));
      }
      _page = (int.tryParse(item.position ?? '') ?? 0).clamp(0, _n == 0 ? 0 : _n - 1);
    } catch (e) {
      _error = e;
    }
    if (mounted) setState(() => _loading = false);
  }

  @override
  void dispose() {
    if (_n > 0) _app.saveProgress(item, '$_page', _progress).then((_) => _app.refresh());
    if (_fullscreen) SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
    _input?.closeSync();
    _loader?.close();
    _zoom.dispose();
    _strip.dispose();
    _scroll.dispose();
    _focus.dispose();
    super.dispose();
  }

  Uint8List _bytes(int i) {
    final hit = _cache[i];
    if (hit != null) return hit;
    if (_loader != null) {
      // 꿀뷰 방식: 지금 쪽을 먼저, 다음 몇 쪽은 미리 꺼내 둔다
      _loader!.want(i, urgent: (i - _page).abs() <= 2);
      return _blank;
    }
    final b = _files[i].content;
    _cache[i] = b;
    _trim();
    return b;
  }

  /// 쪽 그림 데이터 (RAR/7Z 는 꺼내질 때까지 기다림)
  Future<Uint8List?> _bytesAsync(int i) async {
    if (i < 0 || i >= _n) return null;
    if (_loader == null) return _bytes(i);
    _loader!.want(i, urgent: true);
    for (var t = 0; t < 150 && mounted; t++) {
      final hit = _cache[i];
      if (hit != null) return hit;
      await Future<void>.delayed(const Duration(milliseconds: 100));
    }
    return _cache[i];
  }

  /// 만화 쪽의 글자 인식 (말풍선 순서는 정확하지 않을 수 있음)
  Future<String> _pageText(int i) async {
    final b = await _bytesAsync(i);
    if (b == null) return '';
    return OcrService.tidy(await OcrService.recognizeBytes(b));
  }

  /// 메모리 제한: 지금 쪽에서 먼 것부터 버린다
  void _trim() {
    const keep = 40;
    if (_cache.length <= keep) return;
    final far = _cache.keys.toList()..sort((a, b) => (b - _page).abs().compareTo((a - _page).abs()));
    for (final k in far.take(_cache.length - keep)) {
      _cache.remove(k);
      _loader?.forget(k);
    }
  }

  /// 다음 쪽 미리 읽기
  void _prefetch() {
    if (_loader == null) return;
    for (var k = 1; k <= 4; k++) {
      _loader!.want(_page + k * (_dir >= 0 ? 1 : -1));
    }
  }

  // ---------------- 쪽 묶음 ----------------

  /// 두장보기: 커버 단독이면 [0], [1,2], [3,4]… / 커버 포함이면 [0,1], [2,3]…
  List<List<int>> get _spreads {
    if (_s.comicMode != 1) return [for (var i = 0; i < _n; i++) [i]];
    final out = <List<int>>[];
    var i = 0;
    if (_s.comicCoverAlone && _n > 0) out.add([i++]);
    for (; i < _n; i += 2) {
      out.add([i, if (i + 1 < _n) i + 1]);
    }
    return out;
  }

  int get _spread => _spreads.indexWhere((g) => g.contains(_page)).clamp(0, math.max(0, _spreads.length - 1));

  String _label(List<int> g) => g.length == 1 ? (g.first == 0 ? 'Cover' : '${g.first + 1}') : '${g.first + 1}-${g.last + 1}';

  // ---------------- 이동 ----------------

  void _goSpread(int i) {
    final sp = _spreads;
    if (sp.isEmpty) return;
    final t = i.clamp(0, sp.length - 1);
    if (t == _spread) return;
    _zoom.value = Matrix4.identity();
    setState(() {
      _dir = t > _spread ? 1 : -1;
      _page = sp[t].first;
    });
    _prefetch();
    _app.saveProgress(item, '$_page', _progress);
    _scrollStripTo(t);
  }

  /// +1 다음, -1 이전 (읽는 순서 기준)
  void _turn(int d) {
    if (_s.comicMode == 2) {
      if (!_scroll.hasClients) return;
      final pos = _scroll.position;
      _scroll.animateTo((pos.pixels + d * pos.viewportDimension * 0.85).clamp(0.0, pos.maxScrollExtent),
          duration: const Duration(milliseconds: 220), curve: Curves.easeOut);
      return;
    }
    _goSpread(_spread + d);
  }

  /// 화면에서 왼쪽/오른쪽 (읽기방향이 오른쪽→왼쪽이면 왼쪽이 다음)
  void _visual(bool left) => _turn((left ? -1 : 1) * (_s.comicRtl ? -1 : 1));

  void _jumpPage(int page) {
    if (_s.comicMode == 2) {
      setState(() => _page = page);
      final ctx = _pageKeys[page]?.currentContext;
      if (ctx != null) {
        Scrollable.ensureVisible(ctx);
      } else if (_scroll.hasClients) {
        _scroll.jumpTo(_scroll.position.maxScrollExtent * (page / math.max(1, _n - 1)));
      }
      return;
    }
    _goSpread(_spreads.indexWhere((g) => g.contains(page)));
  }

  void _scrollStripTo(int i) {
    if (!_strip.hasClients) return;
    const w = 150.0;
    final pos = _strip.position;
    final target = (i * w - pos.viewportDimension / 2 + w / 2).clamp(0.0, pos.maxScrollExtent);
    _strip.animateTo(target, duration: const Duration(milliseconds: 250), curve: Curves.easeOut);
  }

  void _setZoom(double z) {
    final size = context.size ?? const Size(800, 600);
    final cx = size.width / 2, cy = size.height / 2;
    _zoom.value = Matrix4.identity()
      ..translateByDouble(-(z - 1) * cx, -(z - 1) * cy, 0, 1)
      ..scaleByDouble(z, z, 1, 1);
  }

  void _toggleFullscreen() {
    setState(() {
      _fullscreen = !_fullscreen;
      _chrome = !_fullscreen;
    });
    SystemChrome.setEnabledSystemUIMode(_fullscreen ? SystemUiMode.immersiveSticky : SystemUiMode.edgeToEdge);
  }

  // ---------------- 화면 ----------------

  @override
  Widget build(BuildContext context) {
    final s = context.watch<Settings>();
    if (_loading) return const Scaffold(backgroundColor: viewerBg, body: Center(child: CircularProgressIndicator()));
    if (_error != null || _n == 0) {
      return Scaffold(
        appBar: AppBar(title: Text(item.title)),
        body: Center(child: Text(_error != null ? '열 수 없습니다: $_error' : '이미지가 없는 압축 파일입니다')),
      );
    }
    final wide = MediaQuery.sizeOf(context).width >= 900;
    final rtl = s.comicRtl;
    final natural = s.viewerArrowNatural;

    return CallbackShortcuts(
      bindings: {
        const SingleActivator(LogicalKeyboardKey.arrowLeft): () => natural ? _visual(true) : _turn(-1),
        const SingleActivator(LogicalKeyboardKey.arrowRight): () => natural ? _visual(false) : _turn(1),
        const SingleActivator(LogicalKeyboardKey.arrowDown): () => _turn(1),
        const SingleActivator(LogicalKeyboardKey.arrowUp): () => _turn(-1),
        const SingleActivator(LogicalKeyboardKey.pageDown): () => _turn(1),
        const SingleActivator(LogicalKeyboardKey.pageUp): () => _turn(-1),
        const SingleActivator(LogicalKeyboardKey.space): () => _turn(1),
        const SingleActivator(LogicalKeyboardKey.home): () => _goSpread(0),
        const SingleActivator(LogicalKeyboardKey.end): () => _goSpread(_spreads.length - 1),
        const SingleActivator(LogicalKeyboardKey.keyF): _toggleFullscreen,
        const SingleActivator(LogicalKeyboardKey.keyB): () => s.toggleBookmark(item.id!, _page),
        const SingleActivator(LogicalKeyboardKey.escape): () {
          if (_panel) {
            setState(() => _panel = false);
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
                child: Row(children: [
                  Expanded(
                    child: Column(children: [
                      Expanded(
                        child: Stack(children: [
                          Positioned.fill(child: _stage(s, rtl)),
                          if (_readAloud && _n > 0)
                            Positioned(
                              left: 12,
                              right: 12,
                              bottom: 12,
                              child: Center(
                                child: ReadAloudBar(
                                  pageCount: _n,
                                  currentPage: () => _page,
                                  textOf: _pageText,
                                  goTo: (i) => _goSpread(_spreads.indexWhere((g) => g.contains(i))),
                                  onClose: () => setState(() => _readAloud = false),
                                ),
                              ),
                            ),
                        ]),
                      ),
                      if (_chrome && s.viewerSlider && s.comicMode != 2) _thumbStrip(s, rtl),
                    ]),
                  ),
                  if (_panel) _settingsPanel(s),
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
    final sp = _spreads;
    final marked = s.bookmarks(item.id!).contains(_page);
    final pct = '${(_progress * 100).round()}%';
    return Container(
      color: const Color(0xFF141414),
      padding: const EdgeInsets.fromLTRB(8, 6, 8, 6),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          IconButton(
            style: IconButton.styleFrom(backgroundColor: toolActive),
            tooltip: '닫기',
            icon: const Icon(Icons.arrow_back, color: Colors.white),
            onPressed: () => Navigator.maybePop(context),
          ),
          const SizedBox(width: 10),
          Flexible(
            child: Text(item.fileName,
                overflow: TextOverflow.ellipsis, style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w700, fontSize: 15)),
          ),
          const SizedBox(width: 8),
          Text('${_page + 1} / $_n · $pct', style: const TextStyle(color: Colors.white60, fontSize: 12)),
          NextVolumeButton(item: item),
        ]),
        const SizedBox(height: 4),
        SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          reverse: wide,
          child: Row(children: [
            ToolGroup([
              ToolBtn(icon: Icons.keyboard_double_arrow_left, tooltip: '처음 (Home)', onTap: () => _goSpread(0)),
              ToolBtn(icon: Icons.keyboard_double_arrow_right, tooltip: '끝 (End)', onTap: () => _goSpread(sp.length - 1)),
            ]),
            ToolGroup([
              ToolBtn(icon: Icons.chevron_left, tooltip: '왼쪽 쪽', onTap: () => _visual(true)),
              ToolBtn(icon: Icons.chevron_right, tooltip: '오른쪽 쪽', onTap: () => _visual(false)),
            ]),
            ToolGroup([
              ToolBtn(icon: Icons.swap_horiz, tooltip: '가로 맞춤', active: s.viewerFit == 0, onTap: () => s.viewerFit = 0),
              ToolBtn(icon: Icons.swap_vert, tooltip: '높이 맞춤', active: s.viewerFit == 1, onTap: () => s.viewerFit = 1),
              ToolBtn(icon: Icons.fit_screen, tooltip: '전체 맞춤', active: s.viewerFit == 2, onTap: () => s.viewerFit = 2),
              ToolBtn(icon: Icons.crop_free, tooltip: '원본 크기', active: s.viewerFit == 3, onTap: () => s.viewerFit = 3),
            ]),
            ToolGroup([
              PopupMenuButton<double>(
                tooltip: '확대',
                color: toolBg,
                onSelected: _setZoom,
                itemBuilder: (_) => [
                  for (final z in const [1.0, 1.25, 1.5, 2.0, 3.0])
                    PopupMenuItem(value: z, child: Text('${(z * 100).round()}%', style: const TextStyle(color: Colors.white))),
                ],
                child: ToolBtn(icon: Icons.zoom_in, label: '${(_scale * 100).round()}%', tooltip: '확대 (두 손가락 / Ctrl+휠)'),
              ),
            ]),
            ToolGroup([
              ToolBtn(icon: Icons.crop_portrait, tooltip: '한장보기', active: s.comicMode == 0, onTap: () => s.comicMode = 0),
              ToolBtn(icon: Icons.menu_book, tooltip: '두장보기', active: s.comicMode == 1, onTap: () => s.comicMode = 1),
              ToolBtn(icon: Icons.view_day, tooltip: '스크롤 (웹툰)', active: s.comicMode == 2, onTap: () => s.comicMode = 2),
            ]),
            ToolGroup([
              ToolBtn(
                icon: s.comicRtl ? Icons.keyboard_double_arrow_left : Icons.keyboard_double_arrow_right,
                tooltip: s.comicRtl ? '읽기방향: 오른쪽에서 왼쪽' : '읽기방향: 왼쪽에서 오른쪽',
                active: s.comicRtl,
                onTap: () => s.comicRtl = !s.comicRtl,
              ),
              ToolBtn(icon: Icons.view_carousel, tooltip: '슬라이드 탐색 바', active: s.viewerSlider, onTap: () => s.viewerSlider = !s.viewerSlider),
            ]),
            ToolGroup([ToolBtn(label: _label(sp[_spread]), tooltip: '현재 쪽')]),
            GestureDetector(
              onLongPress: () => _showBookmarks(s),
              child: ToolGroup([
                ToolBtn(
                  icon: marked ? Icons.bookmark : Icons.bookmark_border,
                  tooltip: '책갈피 (B) · 길게 누르면 목록',
                  active: marked,
                  onTap: () => s.toggleBookmark(item.id!, _page),
                ),
              ]),
            ),
            if (OcrService.supported)
              ToolGroup([
                ToolBtn(
                  icon: Icons.record_voice_over,
                  tooltip: '소리 내어 읽기 (글자 인식 · 시험 기능)',
                  active: _readAloud,
                  onTap: () => setState(() => _readAloud = !_readAloud),
                ),
              ]),
            ToolGroup([ToolBtn(icon: _fullscreen ? Icons.fullscreen_exit : Icons.fullscreen, tooltip: '전체화면 (F)', onTap: _toggleFullscreen)]),
            ToolGroup([
              ToolBtn(
                icon: Icons.help_outline,
                tooltip: '단축키',
                onTap: () => showViewerHelp(context, const [
                  ('← →', '쪽 넘기기 (읽기방향 설정을 따름)'),
                  ('↑ ↓ / PgUp PgDn', '이전 / 다음'),
                  ('Space', '다음'),
                  ('Home / End', '처음 / 끝'),
                  ('F', '전체화면'),
                  ('B', '책갈피'),
                  ('Esc', '설정 닫기 · 나가기'),
                  ('더블클릭', '확대 / 원래대로'),
                ]),
              ),
            ]),
            ToolGroup([ToolBtn(icon: Icons.settings, tooltip: '뷰어 설정', active: _panel, onTap: () => setState(() => _panel = !_panel))]),
          ]),
        ),
      ]),
    );
  }

  // ---------- 가운데 ----------
  Widget _stage(Settings s, bool rtl) {
    final current = _bytes(_page);
    return LayoutBuilder(builder: (context, c) {
      Widget content;
      if (s.comicMode == 2) {
        content = _vertical(c, s);
      } else {
        content = _paged(c, s, rtl);
      }
      return Stack(children: [
        // 배경: 단색 / 몰입형(현재 쪽을 크게 흐리게)
        Positioned.fill(
          child: s.viewerImmersive
              ? Stack(fit: StackFit.expand, children: [
                  ImageFiltered(
                    imageFilter: ui.ImageFilter.blur(sigmaX: 50, sigmaY: 50),
                    child: Image.memory(current, fit: BoxFit.cover, gaplessPlayback: true, cacheWidth: 200),
                  ),
                  Container(color: Colors.black.withValues(alpha: 0.55)),
                ])
              : Container(color: viewerBg),
        ),
        Positioned.fill(child: content),
        // 썸네일 줄 접기/펼치기 탭
        if (_chrome && s.comicMode != 2)
          Positioned(
            bottom: 0,
            left: 0,
            right: 0,
            child: Center(
              child: Material(
                color: Colors.black54,
                borderRadius: const BorderRadius.vertical(top: Radius.circular(8)),
                child: InkWell(
                  onTap: () => s.viewerSlider = !s.viewerSlider,
                  child: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 2),
                    child: Icon(s.viewerSlider ? Icons.expand_more : Icons.expand_less, color: Colors.white),
                  ),
                ),
              ),
            ),
          ),
      ]);
    });
  }

  Widget _img(int i, {BoxFit fit = BoxFit.contain, double? width, double? height, Alignment align = Alignment.center}) => Image.memory(
        _bytes(i),
        fit: fit,
        width: width,
        height: height,
        alignment: align,
        gaplessPlayback: true,
        filterQuality: FilterQuality.medium,
        errorBuilder: (_, _, _) => const SizedBox(width: 200, height: 300, child: Icon(Icons.broken_image, color: Colors.white38)),
      );

  /// 한 화면(한 쪽 또는 두 쪽)을 맞춤 방식대로 그린다
  Widget _spreadView(List<int> g, BoxConstraints c, Settings s) {
    final order = s.comicRtl ? g.reversed.toList() : g; // 오른쪽→왼쪽이면 첫 쪽이 오른쪽
    final n = order.length;
    switch (s.viewerFit) {
      case 0: // 가로 맞춤 → 세로로 스크롤
        return SingleChildScrollView(
          child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
            for (final i in order) _img(i, fit: BoxFit.fitWidth, width: c.maxWidth / n),
          ]),
        );
      case 1: // 높이 맞춤 → 가로로 스크롤
        return SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          child: ConstrainedBox(
            constraints: BoxConstraints(minWidth: c.maxWidth),
            child: Row(mainAxisAlignment: MainAxisAlignment.center, children: [
              for (final i in order) _img(i, fit: BoxFit.fitHeight, height: c.maxHeight),
            ]),
          ),
        );
      case 3: // 원본 크기
        return InteractiveViewer(
          constrained: false,
          minScale: 0.2,
          maxScale: 8,
          child: Row(children: [for (final i in order) _img(i, fit: BoxFit.none)]),
        );
      default: // 전체 맞춤
        if (n == 1) return Padding(padding: const EdgeInsets.all(12), child: Center(child: _img(order.first)));
        return Padding(
          padding: const EdgeInsets.symmetric(vertical: 12),
          child: Row(children: [
            Expanded(child: _img(order[0], align: Alignment.centerRight)), // 가운데(제본선) 쪽으로 붙임
            Expanded(child: _img(order[1], align: Alignment.centerLeft)),
          ]),
        );
    }
  }

  Widget _paged(BoxConstraints c, Settings s, bool rtl) {
    final sp = _spreads;
    final idx = _spread;
    final effect = s.viewerEffect;
    // 화면상 이동 방향: 오른쪽→왼쪽 읽기면 다음 쪽이 왼쪽에서 들어온다
    final sign = _dir * (rtl ? -1.0 : 1.0);

    Widget view = KeyedSubtree(key: ValueKey('${s.comicMode}-${s.comicCoverAlone}-$idx'), child: _spreadView(sp[idx], c, s));
    if (s.viewerFit != 3) {
      // 확대했을 때만 끌어서 이동 (아닐 때는 좌우로 밀어 쪽 넘김)
      view = InteractiveViewer(transformationController: _zoom, minScale: 1, maxScale: 6, panEnabled: _scale > 1.01, child: view);
    }

    final switcher = AnimatedSwitcher(
      duration: Duration(milliseconds: effect == 0 ? 0 : (effect == 3 ? 420 : 260)),
      switchInCurve: Curves.easeOutCubic,
      switchOutCurve: Curves.easeInCubic,
      transitionBuilder: (child, anim) {
        final incoming = child.key == ValueKey('${s.comicMode}-${s.comicCoverAlone}-$idx');
        switch (effect) {
          case 1: // 슬라이드
            final from = Offset(incoming ? sign : -sign, 0);
            return SlideTransition(position: Tween(begin: from, end: Offset.zero).animate(anim), child: child);
          case 2: // 페이드
            return FadeTransition(opacity: anim, child: child);
          case 3: // 책 넘김 (제본선 기준으로 회전)
            return AnimatedBuilder(
              animation: anim,
              child: child,
              builder: (_, ch) {
                final angle = (1 - anim.value) * math.pi / 2 * (incoming ? sign : -sign);
                return Transform(
                  alignment: (incoming ? sign : -sign) > 0 ? Alignment.centerLeft : Alignment.centerRight,
                  transform: Matrix4.identity()
                    ..setEntry(3, 2, 0.0012)
                    ..rotateY(angle),
                  child: Opacity(opacity: anim.value.clamp(0.0, 1.0), child: ch),
                );
              },
            );
          default:
            return child;
        }
      },
      child: KeyedSubtree(key: ValueKey('${s.comicMode}-${s.comicCoverAlone}-$idx'), child: view),
    );

    return GestureDetector(
      behavior: HitTestBehavior.translucent,
      // 좌우로 밀기 (확대 중에는 이동만)
      onHorizontalDragEnd: s.viewerFit == 1 || _scale > 1.01
          ? null
          : (d) {
              final v = d.primaryVelocity ?? 0;
              if (v.abs() < 250) return;
              _visual(v > 0); // 오른쪽으로 밀면 왼쪽 쪽이 나온다
            },
      onTapUp: (d) {
        final x = d.localPosition.dx / c.maxWidth;
        if (s.tapToTurn && x < 0.3) {
          _visual(true);
        } else if (s.tapToTurn && x > 0.7) {
          _visual(false);
        } else {
          setState(() => _chrome = !_chrome);
        }
      },
      onDoubleTap: () => _scale > 1.01 ? _zoom.value = Matrix4.identity() : _setZoom(2),
      child: Listener(
        // 마우스 휠: 확대 중이 아니면 쪽 넘기기
        onPointerSignal: (e) {
          if (e is PointerScrollEvent && _scale <= 1.01 && s.viewerFit == 2) {
            _turn(e.scrollDelta.dy > 0 ? 1 : -1);
          }
        },
        child: ClipRect(child: switcher),
      ),
    );
  }

  bool _initialDone = false;
  Widget _vertical(BoxConstraints c, Settings s) {
    final maxW = s.viewerFit == 0 ? c.maxWidth : math.min(c.maxWidth, 900.0);
    if (!_initialDone && _page > 0) {
      _initialDone = true;
      WidgetsBinding.instance.addPostFrameCallback((_) async {
        for (var tries = 0; tries < 200; tries++) {
          final ctx = _pageKeys[_page]?.currentContext;
          if (ctx != null) {
            if (ctx.mounted) Scrollable.ensureVisible(ctx);
            return;
          }
          if (!_scroll.hasClients) return;
          final pos = _scroll.position;
          if (pos.pixels >= pos.maxScrollExtent) return;
          _scroll.jumpTo((pos.pixels + pos.viewportDimension * 2).clamp(0.0, pos.maxScrollExtent));
          await Future<void>.delayed(const Duration(milliseconds: 16));
        }
      });
    }
    return NotificationListener<ScrollEndNotification>(
      onNotification: (_) {
        for (final e in _pageKeys.entries) {
          final box = e.value.currentContext?.findRenderObject() as RenderBox?;
          if (box == null || !box.attached) continue;
          final y = box.localToGlobal(Offset.zero).dy;
          if (y <= 140 && y + box.size.height > 140) {
            if (e.key != _page) {
              setState(() => _page = e.key);
              _app.saveProgress(item, '$_page', _progress);
            }
            break;
          }
        }
        return false;
      },
      child: GestureDetector(
        onTap: () => setState(() => _chrome = !_chrome),
        child: Center(
          child: SizedBox(
            width: maxW,
            child: ListView.builder(
              controller: _scroll,
              itemCount: _n,
              itemBuilder: (_, i) => KeyedSubtree(
                key: _pageKeys.putIfAbsent(i, () => GlobalKey()),
                child: _img(i, fit: BoxFit.fitWidth, width: maxW),
              ),
            ),
          ),
        ),
      ),
    );
  }

  // ---------- 아래 썸네일 줄 ----------
  Widget _thumbStrip(Settings s, bool rtl) {
    final sp = _spreads;
    final cur = _spread;
    final marks = s.bookmarks(item.id!);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_strip.hasClients && _strip.offset == 0 && cur > 3) _scrollStripTo(cur);
    });
    return Container(
      height: 128,
      color: const Color(0xFF141414),
      child: ListView.builder(
        controller: _strip,
        scrollDirection: Axis.horizontal,
        reverse: rtl, // 오른쪽→왼쪽이면 첫 쪽이 오른쪽 끝
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
        itemCount: sp.length,
        itemBuilder: (_, i) {
          final g = sp[i];
          final order = rtl ? g.reversed.toList() : g;
          final on = i == cur;
          return GestureDetector(
            onTap: () => _goSpread(i),
            child: Container(
              width: 140,
              margin: const EdgeInsets.symmetric(horizontal: 5),
              padding: const EdgeInsets.all(4),
              decoration: BoxDecoration(
                color: on ? toolActive.withValues(alpha: 0.25) : toolBg,
                borderRadius: BorderRadius.circular(6),
                border: Border.all(color: on ? toolActive : Colors.white12, width: on ? 2 : 1),
              ),
              child: Column(children: [
                Expanded(
                  child: Stack(children: [
                    Row(mainAxisAlignment: MainAxisAlignment.center, children: [
                      for (final pg in order)
                        Flexible(
                          child: Image.memory(_bytes(pg), fit: BoxFit.contain, cacheWidth: 140, gaplessPlayback: true,
                              errorBuilder: (_, _, _) => const SizedBox()),
                        ),
                    ]),
                    if (g.any(marks.contains))
                      const Positioned(right: 0, top: 0, child: Icon(Icons.bookmark, color: Colors.redAccent, size: 18)),
                  ]),
                ),
                const SizedBox(height: 3),
                Text(_label(g), style: const TextStyle(color: Colors.white70, fontSize: 11)),
              ]),
            ),
          );
        },
      ),
    );
  }

  // ---------- 오른쪽 뷰어 설정 ----------
  Widget _settingsPanel(Settings s) => ViewerSettingsPanel(
        onClose: () => setState(() => _panel = false),
        children: [
          const PanelSection('기본 보기'),
          SegmentRow<int>(
            title: '페이지 맞춤',
            value: s.viewerFit,
            onChanged: (v) => s.viewerFit = v,
            options: const [
              (0, Icons.swap_horiz, '가로 맞춤'),
              (1, Icons.swap_vert, '높이 맞춤'),
              (2, Icons.fit_screen, '전체 맞춤'),
              (3, Icons.crop_free, '원본 크기'),
            ],
          ),
          SegmentRow<int>(
            title: '보기 모드',
            value: s.comicMode,
            onChanged: (v) => s.comicMode = v,
            options: const [(0, Icons.crop_portrait, '한장보기'), (1, Icons.menu_book, '두장보기'), (2, Icons.view_day, '스크롤')],
          ),
          SegmentRow<bool>(
            title: '커버 표시',
            value: s.comicCoverAlone,
            onChanged: (v) => s.comicCoverAlone = v,
            options: const [(false, Icons.menu_book, '두장보기에 포함'), (true, Icons.crop_portrait, '단독 표시')],
          ),
          SegmentRow<bool>(
            title: '읽기방향',
            value: s.comicRtl,
            onChanged: (v) => s.comicRtl = v,
            options: const [(false, Icons.east, '왼쪽에서 오른쪽'), (true, Icons.west, '오른쪽에서 왼쪽')],
          ),
          SegmentRow<bool>(
            title: '슬라이드 탐색 바',
            value: s.viewerSlider,
            onChanged: (v) => s.viewerSlider = v,
            options: const [(true, Icons.view_carousel, '표시'), (false, Icons.visibility_off, '숨기기')],
          ),
          const Divider(color: Colors.white12, height: 28),
          SegmentRow<bool>(
            title: '배경',
            value: s.viewerImmersive,
            onChanged: (v) => s.viewerImmersive = v,
            options: const [(false, null, '단색'), (true, null, '몰입형')],
          ),
          const Divider(color: Colors.white12, height: 28),
          const PanelSection('표시'),
          SegmentRow<bool>(
            title: '좌/우 방향키',
            value: s.viewerArrowNatural,
            onChanged: (v) => s.viewerArrowNatural = v,
            options: const [(true, null, '읽기방향에 자연스럽게'), (false, null, '왼쪽에서 오른쪽')],
          ),
          SegmentRow<bool>(
            title: '화면 좌우 눌러 넘기기',
            value: s.tapToTurn,
            onChanged: (v) => s.tapToTurn = v,
            options: const [(true, null, '켜기'), (false, null, '끄기')],
          ),
          SegmentRow<int>(
            title: '넘김효과',
            value: s.viewerEffect,
            onChanged: (v) => s.viewerEffect = v,
            options: const [(0, null, '효과없음'), (1, null, '슬라이드'), (2, null, '페이드'), (3, null, '책 넘김')],
          ),
          const SizedBox(height: 8),
          OutlinedButton(
            style: OutlinedButton.styleFrom(foregroundColor: Colors.white, side: const BorderSide(color: Colors.white24)),
            onPressed: s.resetViewer,
            child: const Text('초기화'),
          ),
        ],
      );

  void _showBookmarks(Settings s) {
    final marks = s.bookmarks(item.id!);
    showModalBottomSheet(
      context: context,
      builder: (ctx) => ListView(shrinkWrap: true, children: [
        const ListTile(title: Text('책갈피')),
        if (marks.isEmpty) const ListTile(title: Text('책갈피가 없습니다. B 키나 책갈피 버튼으로 추가하세요.')),
        for (final m in marks)
          ListTile(
            leading: const Icon(Icons.bookmark),
            title: Text('${m + 1}쪽'),
            onTap: () {
              Navigator.pop(ctx);
              _jumpPage(m);
            },
            trailing: IconButton(icon: const Icon(Icons.close), onPressed: () {
              s.toggleBookmark(item.id!, m);
              Navigator.pop(ctx);
            }),
          ),
      ]),
    );
  }
}

int _natural(String a, String b) {
  final re = RegExp(r'(\d+)|(\D+)');
  final ma = re.allMatches(a.toLowerCase()).toList();
  final mb = re.allMatches(b.toLowerCase()).toList();
  for (var i = 0; i < ma.length && i < mb.length; i++) {
    final x = ma[i].group(0)!, y = mb[i].group(0)!;
    final nx = int.tryParse(x), ny = int.tryParse(y);
    final c = (nx != null && ny != null) ? nx.compareTo(ny) : x.compareTo(y);
    if (c != 0) return c;
  }
  return ma.length.compareTo(mb.length);
}
