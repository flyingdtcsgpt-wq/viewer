import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../../app_state.dart';
import '../../models/media_item.dart';
import '../../services/background_reading.dart';
import '../../services/ext_archive.dart';
import '../../services/zip_pages.dart';
import '../../services/settings.dart';
import 'open_item.dart';
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
  ZipPages? _zip; // CBZ/ZIP: 따로 도는 일꾼이 압축을 열어 두고 쪽을 꺼내 준다
  final Set<int> _asked = {}; // 꺼내 달라고 이미 부탁한 쪽
  List<String>? _ext; // RAR/7Z: 압축 안 이미지 이름들 (풀지 않고 한 쪽씩 꺼내 읽음)
  PageLoader? _loader;
  // 아직 안 읽힌 쪽 자리에 잠깐 보여줄 투명 그림
  static final _blank = base64Decode('iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNkYAAAAAYAAjCB0C8AAAAASUVORK5CYII=');
  bool _loading = true;
  int get _n => _ext?.length ?? _zip?.names.length ?? 0;
  final _cache = <int, Uint8List>{};
  Object? _error;

  int _page = 0; // 0부터
  int _dir = 1; // 마지막 이동 방향 (애니메이션용)
  bool _panel = false; // 오른쪽 설정 패널
  bool _chrome = true; // 위/아래 막대
  bool _awake = false; // 화면 켜 두기를 걸었는가
  bool _fullscreen = false;
  final _zoom = TransformationController();
  final _strip = ScrollController();
  final _scroll = ScrollController(); // 세로 스크롤(웹툰) 모드
  final _pageKeys = <int, GlobalKey>{};
  final _focus = FocusNode();

  MediaItem get item => widget.item;
  /// 읽은 정도: 지금 화면에 보이는 마지막 쪽 기준 (두 장 보기에서 마지막 화면이면 100%)
  double get _progress {
    if (_n <= 1) return 1;
    if (_s.comicMode == 2) return _page / (_n - 1);
    final sp = _spreads;
    if (sp.isEmpty) return 0;
    return sp[_spread].last / (_n - 1);
  }
  double get _scale => _zoom.value.getMaxScaleOnAxis();
  bool _zoomed = false; // 확대 중 (바뀔 때만 다시 그린다. 두 손가락으로 움직이는 동안 매 프레임 화면 전체를 다시 그리지 않게)

  // 손가락 추적 (탭 · 밀기를 직접 판단해 확대 제스처와 다투지 않게)
  final _touches = <int>{};
  Offset? _downAt;
  Duration _downTime = Duration.zero;
  bool _multi = false; // 이번 손짓에 손가락이 둘 이상이었다 → 확대/축소만
  Timer? _tapTimer;
  Offset? _tapPos;

  Size _view = Size.zero; // 쪽이 그려지는 자리의 크기
  Size _content = Size.zero; // 지금 쪽의 크기 (터치 기기의 가로/높이 맞춤에서 끌어 움직일 수 있는 범위)
  DateTime _lastMove = DateTime(0); // 화면(확대 · 이동)이 마지막으로 움직인 때
  DateTime _holdUntil = DateTime(0); // 쪽을 넘긴 직후: 앞 쪽에서 밀던 관성이 새 쪽을 움직이지 못하게
  bool _stopTap = false; // 움직이던 화면을 멈추려고 댄 손가락 (탭으로 보지 않는다)
  Timer? _snapTimer;
  int _fitSeen = 2, _modeSeen = 0; // initState 에서 지금 값으로

  /// 터치 기기의 가로/높이 맞춤: 안쪽 스크롤 없이 확대 화면이 이동까지 맡는다
  bool _freePan(Settings s) => _touch && (s.viewerFit == 0 || s.viewerFit == 1);

  // 스크롤(웹툰) 보기: 처음에 맨 위에 둘 쪽(_vAnchor)을 기준으로 위 · 아래에 이어 붙인다.
  // 쪽 높이를 아직 몰라도 그 쪽에서 정확히 시작하고(이어 보기), 위쪽 그림이 늦게 불려 와도 보던 자리가 밀리지 않는다.
  int _vAnchor = 0;
  Key _vCenter = UniqueKey();
  final _aspect = <int, double>{}; // 쪽마다 알아낸 세로/가로 비율 (메모리에서 내렸다 다시 불러와도 자리가 흔들리지 않게)
  bool _vTrackPending = false;

  /// 스크롤 보기를 [page] 에서 다시 시작한다 (탐색 줄 · 책갈피로 이동, 보기 방식 바꿈)
  void _vRestart(int page) {
    _vAnchor = page.clamp(0, math.max(0, _n - 1));
    _vCenter = UniqueKey();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && _scroll.hasClients) _scroll.jumpTo(0);
    });
  }

  void _onZoom() {
    final now = DateTime.now();
    // 쪽을 넘긴 직후, 손을 뗀 채로 화면이 움직이면(앞 쪽에서 밀던 관성) 되돌린다. 손가락으로 끄는 것은 막지 않는다
    if (now.isBefore(_holdUntil) && _touches.isEmpty && !_zoom.value.isIdentity()) {
      _zoom.value = Matrix4.identity();
      return;
    }
    _lastMove = now;
    final z = _scale > 1.01;
    if (z != _zoomed && mounted) setState(() => _zoomed = z);
  }

  /// 맞춤 · 보기 방식을 바꾸면 확대 · 이동을 처음으로 (앞 방식에서 내려 둔 위치가 남아 빈 화면이 되지 않게)
  void _onSettings() {
    if (_s.viewerFit == _fitSeen && _s.comicMode == _modeSeen) return;
    final toScroll = _s.comicMode == 2 && _modeSeen != 2;
    _fitSeen = _s.viewerFit;
    _modeSeen = _s.comicMode;
    _zoom.value = Matrix4.identity();
    // 스크롤 보기로 바꾸면 보던 쪽에서 시작
    if (toScroll && mounted) setState(() => _vRestart(_page));
  }

  @override
  void initState() {
    super.initState();
    _app;
    _s;
    if (_s.keepScreenOn) {
      _awake = true;
      ScreenAwake.hold();
    }
    _open();
    _fitSeen = _s.viewerFit;
    _modeSeen = _s.comicMode;
    _zoom.addListener(_onZoom);
    _s.addListener(_onSettings);
  }

  Future<void> _open() async {
    try {
      if (ExtArchive.handles(item.path) && !ExtArchive.supported) {
        throw 'RAR · 7Z 만화는 아직 PC 버전에서만 열 수 있습니다. (ZIP · CBZ 는 휴대폰에서도 열립니다)';
      }
      if (ExtArchive.handles(item.path)) {
        // RAR / 7Z: Windows 내장 tar 로 임시 폴더에 풀어서 읽는다
        _ext = await ExtArchive.listImages(item.path);
        _loader = PageLoader(item.path, _ext!, (i, b) {
          if (!mounted) return;
          setState(() => _cache[i] = b);
          _trim();
        });
      } else {
        _zip = await ZipPages.open(item.path);
      }
      _page = (int.tryParse(item.position ?? '') ?? 0).clamp(0, _n == 0 ? 0 : _n - 1);
      _vAnchor = _page; // 스크롤 보기: 읽던 쪽에서 시작
    } catch (e) {
      _error = e;
    }
    if (mounted) setState(() => _loading = false);
  }

  @override
  void dispose() {
    if (_n > 0) _app.saveProgress(item, '$_page', _progress).then((_) => _app.refresh());
    if (_awake) ScreenAwake.release();
    if (_fullscreen) SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
    _zip?.close();
    _loader?.close();
    _tapTimer?.cancel();
    _snapTimer?.cancel();
    _s.removeListener(_onSettings);
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
    _want(i);
    return _blank;
  }

  /// CBZ/ZIP 쪽을 일꾼에게 부탁 (오면 화면을 다시 그린다)
  void _want(int i) {
    final z = _zip;
    if (z == null || i < 0 || i >= _n || _cache.containsKey(i) || !_asked.add(i)) return;
    z.read(i).then((b) {
      _asked.remove(i);
      if (!mounted || b == null) return;
      setState(() => _cache[i] = b);
      _trim();
    });
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
    if (_zip != null) {
      for (var k = 1; k <= 4; k++) {
        _want(_page + k * (_dir >= 0 ? 1 : -1));
      }
      return;
    }
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
    _holdUntil = DateTime.now().add(const Duration(milliseconds: 400));
    _lastMove = DateTime(0); // 방금 것은 쪽 넘김이지 밀던 화면이 아니다 (바로 이어 누르는 탭을 놓치지 않게)
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
    // 마지막 쪽에서 더 넘기면: 다음 권으로 갈지 묻는다 (없으면 "마지막 권입니다")
    if (d > 0 && _s.comicMode != 2 && _spread >= _spreads.length - 1) {
      _app.saveProgress(item, '$_page', _progress);
      askNextVolume(context, item, rightIsNext: !(_s.viewerArrowNatural && _s.comicRtl));
      return;
    }
    if (_s.comicMode == 2) {
      if (!_scroll.hasClients) return;
      final pos = _scroll.position;
      if (d > 0 && pos.pixels >= pos.maxScrollExtent - 2) {
        askNextVolume(context, item, rightIsNext: !(_s.viewerArrowNatural && _s.comicRtl));
        return;
      }
      // (시작 쪽보다 위는 음수 위치다 → 0 이 아니라 맨 위 한계까지)
      _scroll.animateTo((pos.pixels + d * pos.viewportDimension * 0.85).clamp(pos.minScrollExtent, pos.maxScrollExtent),
          duration: const Duration(milliseconds: 220), curve: Curves.easeOut);
      return;
    }
    _goSpread(_spread + d);
  }

  /// 화면에서 왼쪽/오른쪽 (읽기방향이 오른쪽→왼쪽이면 왼쪽이 다음)
  void _visual(bool left) => _turn((left ? -1 : 1) * (_s.comicRtl ? -1 : 1));

  void _jumpPage(int page) {
    if (_s.comicMode == 2) {
      // 스크롤 보기: 그 쪽을 맨 위에 두고 다시 시작한다 (높이를 몰라도 정확히 그 쪽)
      setState(() {
        _page = page.clamp(0, math.max(0, _n - 1));
        _vRestart(_page);
      });
      _prefetch();
      _app.saveProgress(item, '$_page', _progress);
      _scrollStripTo(_spread);
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
    if (_s.viewerFit == 3) return; // 원본 크기: 안쪽 화면이 따로 확대를 맡는다
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
        ...volumeKeyBindings(s.volumeKeyTurn, _turn),
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
                      Expanded(child: _stage(s, rtl)),
                      if (_chrome && s.viewerSlider) _thumbStrip(s, rtl),
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
                child: ValueListenableBuilder<Matrix4>(
                  valueListenable: _zoom,
                  builder: (_, m, _) => ToolBtn(icon: Icons.zoom_in, label: '${(m.getMaxScaleOnAxis() * 100).round()}%', tooltip: '확대 (두 손가락 / Ctrl+휠)'),
                ),
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
                  tooltip: '책갈피 (B): 지금 쪽을 표시 · 다시 누르면 지움',
                  active: marked,
                  onTap: () => s.toggleBookmark(item.id!, _page),
                ),
                // 책갈피한 곳으로 바로 가기
                BookmarkListBtn(count: s.bookmarks(item.id!).length, onTap: () => _showBookmarks(s)),
              ]),
            ),
            const ToolGroup([EyeCareBtn()]),
            ToolGroup([ToolBtn(icon: _fullscreen ? Icons.fullscreen_exit : Icons.fullscreen, tooltip: '전체화면 (F)', onTap: _toggleFullscreen)]),
            ToolGroup([
              ToolBtn(
                icon: Icons.help_outline,
                tooltip: '조작법 · 단축키',
                onTap: () => showViewerHelp(context, const [
                  ('← →', '쪽 넘기기 (읽기방향 설정을 따름)'),
                  ('↑ ↓ / PgUp PgDn', '이전 / 다음'),
                  ('Space', '다음'),
                  ('Home / End', '처음 / 끝'),
                  ('F', '전체화면'),
                  ('B', '책갈피'),
                  ('Esc', '설정 닫기 · 나가기'),
                  ('더블클릭', '확대 / 원래대로'),
                  ('Ctrl+휠 · 끌기', '확대 · 축소 / 확대 중 이동'),
                  ('마지막 쪽에서 한 번 더', '다음 권으로 (없으면 "마지막 권" 안내)'),
                ], touch: const [
                  ('가장자리 누르기 · 옆으로 밀기', '쪽 넘기기'),
                  ('가운데 누르기', '위아래 메뉴 보이기 · 숨기기'),
                  ('두 손가락 벌리기', '확대 · 축소'),
                  ('두 번 누르기', '그 자리 확대 ↔ 원래 크기'),
                  ('확대 중 한 손가락', '끌어서 움직이기 (한 번 누르기는 무시)'),
                  ('마지막 쪽에서 한 번 더', '다음 권으로 (없으면 "마지막 권" 안내)'),
                  ('책갈피 단추', '지금 쪽을 표시 · 다시 누르면 지움'),
                  ('책갈피 목록 단추 (옆)', '책갈피한 쪽 목록 → 누르면 그 쪽으로'),
                  ('눈 보호 단추', '푸른빛 줄이기 (세기는 ⚙ 뷰어 설정)'),
                  ('볼륨 버튼', '쪽 넘기기 (설정 › 뷰어에서 켜기)'),
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
      // 눈 보호: 쪽과 배경을 함께 따뜻한 색으로
      return EyeCare(
          child: Stack(children: [
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
        if (_chrome)
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
      ]));
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
        // 휴대폰: 안쪽 스크롤 없이 확대 화면이 직접 끌어 움직인다 (스크롤이 첫 손가락을 가져가 두 손가락 확대가 안 먹던 문제)
        if (_touch) {
          return _Measure(
            onSize: (z) {
              if (g.contains(_page)) _content = z;
            },
            child: ConstrainedBox(
              constraints: BoxConstraints(minWidth: c.maxWidth, minHeight: c.maxHeight),
              child: Align(
                // 화면보다 짧은 쪽은 가운데에
                alignment: Alignment.center,
                child: Row(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
                  for (final i in order) _img(i, fit: BoxFit.fitWidth, width: c.maxWidth / n),
                ]),
              ),
            ),
          );
        }
        return SingleChildScrollView(
          child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
            for (final i in order) _img(i, fit: BoxFit.fitWidth, width: c.maxWidth / n),
          ]),
        );
      case 1: // 높이 맞춤 → 가로로 스크롤
        if (_touch) {
          return _Measure(
            onSize: (z) {
              if (g.contains(_page)) _content = z;
            },
            child: ConstrainedBox(
              constraints: BoxConstraints(minWidth: c.maxWidth, maxHeight: c.maxHeight, minHeight: c.maxHeight),
              child: Row(mainAxisSize: MainAxisSize.min, mainAxisAlignment: MainAxisAlignment.center, children: [
                for (final i in order) _img(i, fit: BoxFit.fitHeight, height: c.maxHeight),
              ]),
            ),
          );
        }
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
      // 전체 맞춤: 확대했을 때만 끌어서 이동 (아닐 때는 좌우로 밀어 쪽 넘김)
      // 휴대폰의 가로/높이 맞춤: 확대 화면이 스크롤까지 맡는다 (한 손가락 = 이동, 두 손가락 = 확대)
      final freePan = _freePan(s);
      _view = Size(c.maxWidth, c.maxHeight);
      view = InteractiveViewer(
        transformationController: _zoom,
        minScale: 1,
        maxScale: 6,
        constrained: !freePan,
        panEnabled: freePan || _zoomed,
        // 마우스 휠은 아래에서 직접 다룬다 (휠 = 쪽 넘김, Ctrl+휠 = 확대).
        // 그대로 두면 휠을 위로 굴릴 때 이전 쪽으로 가지 않고 확대가 되어 버린다.
        scaleFactor: 1e9,
        child: view,
      );
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

    // 탭 · 밀기는 손가락 움직임을 직접 보고 판단한다.
    // (예전에는 GestureDetector 의 밀기 · 두 번 탭 인식기가 확대(InteractiveViewer)와 같은 손가락을 두고 다퉈서,
    //  두 번째 손가락이 조금 늦게 닿으면 첫 손가락이 "밀기"로 잡혀 두 손가락 확대가 무시되곤 했다)
    return Listener(
      behavior: HitTestBehavior.translucent,
      onPointerDown: (e) {
        if (e.kind == PointerDeviceKind.mouse && e.buttons != kPrimaryMouseButton) return; // 오른쪽 · 가운데 단추는 무시
        _touches.add(e.pointer);
        _snapTimer?.cancel();
        if (_touches.length == 1) {
          // 밀려 움직이던 화면을 멈추려고 댄 손가락은 탭(쪽 넘김 · 메뉴)으로 보지 않는다
          _stopTap = DateTime.now().difference(_lastMove) < const Duration(milliseconds: 120);
          _downAt = e.localPosition;
          _downTime = e.timeStamp;
          _multi = false;
        } else {
          _multi = true; // 두 손가락: 확대/축소만 (탭 · 쪽 넘김으로 보지 않는다)
          _tapTimer?.cancel();
        }
      },
      onPointerCancel: (e) {
        _touches.remove(e.pointer);
        _multi = true;
      },
      onPointerUp: (e) {
        _touches.remove(e.pointer);
        final start = _downAt;
        if (_touches.isNotEmpty || start == null) return; // 아직 다른 손가락이 닿아 있음
        _downAt = null;
        if (_multi) {
          // 두 손가락을 뗐는데 거의 원래 크기(1 ~ 1.08배)로 남았으면 원래 크기로 맞춘다
          // (살짝 확대된 채 남으면 탭 · 밀기가 "확대 중"으로 막혀 먹통처럼 보인다)
          _snapTimer?.cancel();
          _snapTimer = Timer(const Duration(milliseconds: 300), () {
            if (mounted && _touches.isEmpty && _scale > 1.0 && _scale < 1.08) _unzoom(_s);
          });
          return;
        }
        if (_stopTap) return;
        final d = e.localPosition - start;
        final ms = (e.timeStamp - _downTime).inMilliseconds;
        if (d.distance < 18 && ms < 500) {
          _onTap(e.localPosition, c, s);
        } else if (!_zoomed && s.viewerFit != 1 && s.viewerFit != 3 && ms < 700 && d.dx.abs() > 48 && d.dx.abs() > d.dy.abs() * 1.4) {
          _visual(d.dx > 0); // 오른쪽으로 밀면 왼쪽 쪽이 나온다
        }
      },
      // 마우스 휠: Ctrl+휠 = 그 자리 확대 · 축소, 확대 중 = 위아래로 움직이기, 그 밖에는(전체 맞춤) 쪽 넘기기
      onPointerSignal: (e) {
        if (e is! PointerScrollEvent || e.scrollDelta.dy == 0 || s.viewerFit == 3) return;
        final ctrl = HardwareKeyboard.instance.isControlPressed || HardwareKeyboard.instance.isMetaPressed;
        if (ctrl) {
          _wheelZoom(e.localPosition, e.scrollDelta.dy, c, s);
        } else if (_zoomed) {
          _moveZoomed(Offset(0, -e.scrollDelta.dy), c, s);
        } else if (s.viewerFit == 2) {
          _turn(e.scrollDelta.dy > 0 ? 1 : -1);
        }
      },
      child: ClipRect(child: switcher),
    );
  }

  static final _touch = Platform.isAndroid || Platform.isIOS;

  /// 한 번 탭: 가장자리 = 쪽 넘김, 가운데 = 메뉴 보이기/숨기기. 두 번 탭 = 그 자리 확대 ↔ 원래 크기
  /// 확대 중에는 한 번 탭으로 아무것도 하지 않는다 (메뉴가 사라지며 화면이 밀리거나 쪽이 넘어가지 않게)
  void _onTap(Offset p, BoxConstraints c, Settings s) {
    final prev = _tapPos;
    // 원본 크기는 안쪽 화면이 따로 확대를 맡는다 → 두 번 탭 확대 없이 한 번 탭을 바로 처리
    if (s.viewerFit == 3) {
      final x = p.dx / c.maxWidth;
      if (s.tapToTurn && (x < 0.3 || x > 0.7)) {
        _visual(x < 0.3);
      } else {
        setState(() => _chrome = !_chrome);
      }
      return;
    }
    if (_tapTimer?.isActive == true && prev != null && (p - prev).distance < 48) {
      _tapTimer!.cancel();
      _tapPos = null;
      _zoomed ? _unzoom(s) : _zoomAt(p, 2.5);
      return;
    }
    final x = p.dx / c.maxWidth;
    if (!_zoomed && s.tapToTurn && (x < 0.3 || x > 0.7)) {
      _tapPos = null;
      _visual(x < 0.3); // 가장자리는 기다리지 않고 바로 넘긴다
      return;
    }
    _tapPos = p;
    _tapTimer?.cancel();
    _tapTimer = Timer(const Duration(milliseconds: 260), () {
      _tapPos = null;
      if (!mounted || _zoomed) return;
      setState(() => _chrome = !_chrome);
    });
  }

  void _zoomAt(Offset p, double z) {
    final m = Matrix4.identity()
      ..translateByDouble(p.dx, p.dy, 0, 1)
      ..scaleByDouble(z, z, 1, 1)
      ..translateByDouble(-p.dx, -p.dy, 0, 1);
    _zoom.value = m.multiplied(_zoom.value);
  }

  /// 확대한 화면이 가장자리 밖으로 밀려나지 않게 (화면 크기에 맞춘 내용일 때)
  Matrix4 _inBounds(Matrix4 m, BoxConstraints c) {
    final z = m.getMaxScaleOnAxis();
    final t = m.getTranslation();
    final minX = math.min(0.0, -(z - 1) * c.maxWidth), minY = math.min(0.0, -(z - 1) * c.maxHeight);
    return m..setTranslationRaw(t.x.clamp(minX, 0.0), t.y.clamp(minY, 0.0), 0);
  }

  /// Ctrl+휠: 마우스가 있는 자리를 중심으로 확대 · 축소 (1 ~ 6배)
  void _wheelZoom(Offset p, double dy, BoxConstraints c, Settings s) {
    final cur = _scale;
    final next = (cur * math.exp(-dy / 300)).clamp(1.0, 6.0);
    if (next <= 1.001) {
      if (cur > 1.001) _unzoom(s);
      return;
    }
    final r = next / cur;
    final m = Matrix4.identity()
      ..translateByDouble(p.dx, p.dy, 0, 1)
      ..scaleByDouble(r, r, 1, 1)
      ..translateByDouble(-p.dx, -p.dy, 0, 1);
    final out = m.multiplied(_zoom.value);
    _zoom.value = _freePan(s) ? out : _inBounds(out, c);
  }

  /// 확대 중 휠: 위아래로 움직인다
  void _moveZoomed(Offset d, BoxConstraints c, Settings s) {
    final out = (Matrix4.identity()..translateByDouble(d.dx, d.dy, 0, 1)).multiplied(_zoom.value);
    _zoom.value = _freePan(s) ? out : _inBounds(out, c);
  }

  /// 원래 크기로. 터치 기기의 가로/높이 맞춤에서는 보던 자리를 그대로 두되, 쪽 밖으로 나가지 않게 한다
  void _unzoom(Settings s) {
    if (!_freePan(s)) {
      _zoom.value = Matrix4.identity();
      return;
    }
    final sc = _scale;
    final t = _zoom.value.getTranslation();
    double fit(double v, double content, double view) => v.clamp(math.min(0.0, view - math.max(content, view)), 0.0);
    _zoom.value = Matrix4.identity()
      ..translateByDouble(fit(t.x / sc, _content.width, _view.width), fit(t.y / sc, _content.height, _view.height), 0, 1);
  }

  /// 스크롤 보기: 화면 위쪽 1/3 지점에 걸친 쪽을 "지금 쪽" 으로 삼아 저장한다.
  /// 스크롤 알림은 화면을 다시 배치하기 전에 오므로(그때 재면 옛 위치가 나온다) 이번 화면이 그려진 뒤에 잰다.
  void _trackVertical() {
    if (_vTrackPending) return;
    _vTrackPending = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _vTrackPending = false;
      if (!mounted || _s.comicMode != 2 || !_scroll.hasClients || _n == 0) return;
      final pos = _scroll.position;
      int? found;
      // 맨 아래까지 내렸으면 마지막 쪽까지 본 것 (마지막 그림이 짧아도 100%)
      if (pos.pixels >= pos.maxScrollExtent - 8 && _pageKeys[_n - 1]?.currentContext != null) {
        found = _n - 1;
      } else {
        final view = pos.context.storageContext.findRenderObject();
        if (view is! RenderBox || !view.attached) return;
        final line = view.localToGlobal(Offset.zero).dy + view.size.height / 3;
        bool at(int i) {
          final box = _pageKeys[i]?.currentContext?.findRenderObject();
          if (box is! RenderBox || !box.attached || !box.hasSize) return false;
          final y = box.localToGlobal(Offset.zero).dy;
          return y <= line && y + box.size.height > line;
        }

        for (var d = 0; d <= 6 && found == null; d++) {
          if (at(_page + d)) {
            found = _page + d;
          } else if (d > 0 && at(_page - d)) {
            found = _page - d;
          }
        }
        if (found == null) {
          for (final k in _pageKeys.keys) {
            if (at(k)) {
              found = k;
              break;
            }
          }
        }
      }
      if (found == null || found == _page) return;
      final to = found;
      setState(() {
        _dir = to > _page ? 1 : -1;
        _page = to;
      });
      _prefetch();
      _app.saveProgress(item, '$_page', _progress);
      _scrollStripTo(_spread);
    });
  }

  Widget _vertical(BoxConstraints c, Settings s) {
    final maxW = s.viewerFit == 0 ? c.maxWidth : math.min(c.maxWidth, 900.0);
    final dpr = MediaQuery.devicePixelRatioOf(context);

    // 아직 못 읽었거나 그리는 중인 쪽의 자리. 한 번 본 쪽은 알아 둔 비율 그대로 → 불러오는 동안 자리가 흔들리지 않는다
    Widget hold(int i) => SizedBox(
          width: maxW,
          height: maxW * (_aspect[i] ?? 1.42),
          child: _aspect.containsKey(i) ? null : const Center(child: SizedBox(width: 24, height: 24, child: CircularProgressIndicator(strokeWidth: 2))),
        );

    Widget page(int i) {
      final bytes = _cache[i];
      if (bytes == null) _bytes(i); // 불러오기를 부탁해 둔다 (오면 다시 그린다)
      return KeyedSubtree(
        key: _pageKeys.putIfAbsent(i, () => GlobalKey()),
        child: bytes == null
            ? hold(i)
            : Image.memory(
                bytes,
                fit: BoxFit.fitWidth,
                width: maxW,
                // 화면에 보이는 크기로만 풀어 메모리를 아낀다 (스크롤 보기는 확대가 없다)
                cacheWidth: (maxW * dpr).round(),
                gaplessPlayback: true,
                filterQuality: FilterQuality.medium,
                frameBuilder: (_, child, frame, sync) => frame == null && !sync
                    ? hold(i)
                    : _Measure(
                        onSize: (z) {
                          if (z.width > 0 && z.height > 0) _aspect[i] = z.height / z.width;
                        },
                        child: child,
                      ),
                errorBuilder: (_, _, _) => SizedBox(width: maxW, height: 200, child: const Icon(Icons.broken_image, color: Colors.white38)),
              ),
      );
    }

    return NotificationListener<ScrollNotification>(
      onNotification: (n) {
        if (n is ScrollUpdateNotification || n is ScrollEndNotification) _trackVertical();
        return false;
      },
      child: GestureDetector(
        onTap: () => setState(() => _chrome = !_chrome),
        child: Center(
          child: SizedBox(
            width: maxW,
            child: CustomScrollView(
              controller: _scroll,
              center: _vCenter,
              slivers: [
                // 시작 쪽보다 앞의 쪽들 (위로 올리면 나온다)
                SliverList(delegate: SliverChildBuilderDelegate((_, k) => page(_vAnchor - 1 - k), childCount: _vAnchor.clamp(0, _n))),
                SliverList(key: _vCenter, delegate: SliverChildBuilderDelegate((_, k) => page(_vAnchor + k), childCount: math.max(0, _n - _vAnchor))),
                // 웹툰은 마지막 그림 아래로 이어서 다음 화 안내
                SliverToBoxAdapter(
                  child: Padding(padding: const EdgeInsets.fromLTRB(12, 32, 12, 120), child: Center(child: VolumeEndCard(item: item))),
                ),
              ],
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
            onTap: () => s.comicMode == 2 ? _jumpPage(g.first) : _goSpread(i),
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
          const Divider(color: Colors.white12, height: 28),
          const EyeCarePanel(),
          const SizedBox(height: 8),
          OutlinedButton(
            style: OutlinedButton.styleFrom(foregroundColor: Colors.white, side: const BorderSide(color: Colors.white24)),
            onPressed: s.resetViewer,
            child: const Text('초기화'),
          ),
        ],
      );

  void _showBookmarks(Settings s) => showBookmarkSheet(
        context,
        marks: s.bookmarks(item.id!),
        label: (m) => '${m + 1}쪽',
        onGo: _jumpPage,
        onRemove: (m) => s.toggleBookmark(item.id!, m),
      );
}

/// 자식의 크기를 알려 준다 (그릴 때마다. 화면을 다시 그리지는 않는다)
class _Measure extends SingleChildRenderObjectWidget {
  final ValueChanged<Size> onSize;
  const _Measure({required this.onSize, super.child});
  @override
  RenderObject createRenderObject(BuildContext context) => _RenderMeasure(onSize);
  @override
  void updateRenderObject(BuildContext context, covariant _RenderMeasure renderObject) => renderObject.onSize = onSize;
}

class _RenderMeasure extends RenderProxyBox {
  ValueChanged<Size> onSize;
  _RenderMeasure(this.onSize);
  @override
  void performLayout() {
    super.performLayout();
    onSize(size);
  }
}
