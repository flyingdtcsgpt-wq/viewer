import 'dart:async';
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../../app_state.dart';
import '../../models/media_item.dart';
import '../../services/background_reading.dart';
import '../../services/settings.dart';
import '../detail_page.dart';

/// 그림 뷰어
///
/// 보기 방식 세 가지 ([Settings.imageViewMode], 위쪽 단추나 설정 › 뷰어에서 고른다):
/// - 0 좌우로 넘기기: 한 장씩, 옆으로 밀어 넘긴다
/// - 1 위아래로 넘기기: 한 장씩, 위아래로 밀어 넘긴다
/// - 2 위아래로 이어 보기: 그림을 세로로 이어 붙여 죽 내려 본다 (긴 그림 · 이어지는 그림)
///
/// 한 장씩 보는 방식에서는 확대/이동(두 손가락 · 두 번 탭 · 휠)이 되고, 슬라이드쇼는 세 방식 모두 된다.
class ImageViewerPage extends StatefulWidget {
  final List<MediaItem> images;
  final int initialIndex;
  const ImageViewerPage({super.key, required this.images, required this.initialIndex});

  @override
  State<ImageViewerPage> createState() => _ImageViewerPageState();
}

class _ImageViewerPageState extends State<ImageViewerPage> {
  late final AppState _app = context.read<AppState>();
  late final Settings _s = context.read<Settings>();
  late int _index = widget.initialIndex;
  int _mode = 0;

  // 한 장씩 (좌우 · 위아래)
  late PageController _pages = PageController(initialPage: _index);
  final _zoom = <int, TransformationController>{};
  bool _zoomed = false;
  DateTime _lastWheel = DateTime(0);

  // 이어 보기: 처음에 맨 위에 둘 그림(_anchor)을 가운데 기준으로 위 · 아래에 이어 붙인다 → 높이를 몰라도 그 그림에서 시작한다
  late int _anchor = _index;
  ScrollController _strip = ScrollController();
  final _centerKey = GlobalKey();
  final _itemKeys = <int, GlobalKey>{};
  bool _trackPending = false;

  bool _showUi = true;
  Timer? _slideshow;

  int get _n => widget.images.length;
  MediaItem get _item => widget.images[_index];

  @override
  void initState() {
    super.initState();
    _mode = _s.imageViewMode.clamp(0, 2);
    _s.addListener(_onSettings);
    _touch();
  }

  @override
  void dispose() {
    _slideshow?.cancel();
    _s.removeListener(_onSettings);
    for (final z in _zoom.values) {
      z.dispose();
    }
    _pages.dispose();
    _strip.dispose();
    // 화면을 닫는 중에는 알림을 보낼 수 없어서 다음 순간에
    Future.microtask(_app.refresh);
    super.dispose();
  }

  void _touch() => _app.saveProgress(_item, '0', 0); // '최근 본' 기록용

  /// 보기 방식을 바꾸면 보던 그림에서 그대로 이어 간다
  void _onSettings() {
    final m = _s.imageViewMode.clamp(0, 2);
    if (m == _mode || !mounted) return;
    final oldPages = _pages, oldStrip = _strip;
    setState(() {
      _mode = m;
      _zoomed = false;
      _anchor = _index;
      _pages = PageController(initialPage: _index);
      _strip = ScrollController();
      _itemKeys.clear();
    });
    for (final z in _zoom.values) {
      z.value = Matrix4.identity();
    }
    // 앞 방식의 화면이 사라진 뒤에 치운다
    WidgetsBinding.instance.addPostFrameCallback((_) {
      oldPages.dispose();
      oldStrip.dispose();
    });
  }

  // 닿아 있는 손가락 (번호로 기억해야 떼는 신호를 한 번 놓쳐도 숫자가 어긋나지 않는다)
  final _fingers = <int>{};
  void _lift(int pointer) {
    final was = _fingers.length;
    _fingers.remove(pointer);
    if (was >= 2 && _fingers.length < 2 && mounted) setState(() {});
  }

  TransformationController _zoomFor(int i) => _zoom.putIfAbsent(i, () {
        final c = TransformationController();
        c.addListener(() {
          final z = c.value.getMaxScaleOnAxis() > 1.01;
          if (i == _index && z != _zoomed && mounted) setState(() => _zoomed = z);
        });
        return c;
      });

  /// +1 다음 그림, -1 이전 그림
  void _go(int delta) {
    final target = _index + delta;
    if (target < 0 || target >= _n) {
      if (_slideshow != null) _toggleSlideshow();
      return;
    }
    if (_mode == 2) {
      // 이어 보기: 지금 그림이 화면 밖으로 더 남아 있으면 한 화면만 움직이고(긴 그림을 건너뛰지 않게),
      // 다 봤으면 다음(이전) 그림의 맨 위로 간다
      final cur = _itemKeys[_index]?.currentContext?.findRenderObject();
      final viewH = context.size?.height ?? 900;
      if (cur is RenderBox && cur.attached && cur.hasSize) {
        final top = cur.localToGlobal(Offset.zero).dy - _stripTop();
        if (delta > 0 ? top + cur.size.height > viewH + 4 : top < -4) {
          _scrollBy(delta * 0.85);
          return;
        }
      }
      // 다음(이전) 그림의 맨 위가 화면 맨 위에 오도록 그만큼 움직인다 (아직 안 그려진 그림이면 한 화면)
      final next = _itemKeys[target]?.currentContext?.findRenderObject();
      if (next is RenderBox && next.attached && next.hasSize && _strip.hasClients) {
        final pos = _strip.position;
        final to = pos.pixels + next.localToGlobal(Offset.zero).dy - _stripTop();
        _strip.animateTo(to.clamp(pos.minScrollExtent, pos.maxScrollExtent), duration: const Duration(milliseconds: 260), curve: Curves.easeOut);
      } else {
        _scrollBy(delta * 0.85);
      }
      return;
    }
    _pages.animateToPage(target, duration: const Duration(milliseconds: 220), curve: Curves.easeOut);
  }

  /// 이어 보기 화면의 맨 위 (화면 좌표)
  double _stripTop() {
    final box = context.findRenderObject();
    return box is RenderBox && box.attached ? box.localToGlobal(Offset.zero).dy : 0;
  }

  /// 이어 보기: 화면 높이의 [screens] 배만큼 내리거나 올린다
  void _scrollBy(double screens) {
    if (!_strip.hasClients) return;
    final pos = _strip.position;
    _strip.animateTo(
      (pos.pixels + screens * pos.viewportDimension).clamp(pos.minScrollExtent, pos.maxScrollExtent),
      duration: const Duration(milliseconds: 220),
      curve: Curves.easeOut,
    );
  }

  /// 이어 보기: 화면 위쪽 1/3 지점에 걸친 그림을 "지금 그림" 으로 (제목의 몇 번째 · 즐겨찾기 · 정보가 이 그림을 가리킨다).
  /// 스크롤 알림은 화면을 다시 배치하기 전에 오므로(그때 재면 옛 위치가 나온다) 이번 화면이 그려진 뒤에 잰다.
  void _trackStrip() {
    if (_trackPending) return;
    _trackPending = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _trackPending = false;
      if (!mounted || _mode != 2) return;
      final found = _stripIndexNow();
      if (found != null && found != _index) {
        setState(() => _index = found);
        _touch();
      }
    });
  }

  int? _stripIndexNow() {
    final line = (context.size?.height ?? 900) / 3;
    final top = _stripTop();
    bool at(int i) {
      final box = _itemKeys[i]?.currentContext?.findRenderObject();
      if (box is! RenderBox || !box.attached || !box.hasSize) return false;
      final y = box.localToGlobal(Offset.zero).dy - top;
      return y <= line && y + box.size.height > line;
    }

    // 보통은 지금 그림 근처다. 못 찾으면(빠르게 멀리 움직였을 때) 그려져 있는 것을 모두 본다
    for (var d = 0; d <= 6; d++) {
      if (at(_index + d)) return _index + d;
      if (d > 0 && at(_index - d)) return _index - d;
    }
    for (final i in _itemKeys.keys) {
      if (at(i)) return i;
    }
    return null;
  }

  void _toggleSlideshow() {
    setState(() {
      if (_slideshow != null) {
        _slideshow!.cancel();
        _slideshow = null;
      } else {
        _slideshow = Timer.periodic(Duration(seconds: _s.slideshowSeconds), (_) => _go(1));
        _showUi = false;
      }
    });
  }

  void _toggleZoom(int i, TapDownDetails? at) {
    final c = _zoomFor(i);
    if (c.value.getMaxScaleOnAxis() > 1.01) {
      c.value = Matrix4.identity();
    } else {
      // 탭한 지점을 중심으로 2.5배 확대
      final p = at?.localPosition ?? Offset.zero;
      c.value = Matrix4.identity()
        ..translateByDouble(-p.dx * 1.5, -p.dy * 1.5, 0, 1)
        ..scaleByDouble(2.5, 2.5, 1, 1);
    }
  }

  /// 위아래로 넘기기에서 마우스 휠: 한 칸 = 한 장. Ctrl+휠(또는 확대 중)은 그 자리 확대 · 축소
  void _wheelPaged(PointerScrollEvent e, int i, Size view) {
    final dy = e.scrollDelta.dy;
    if (dy == 0) return;
    final ctrl = HardwareKeyboard.instance.isControlPressed || HardwareKeyboard.instance.isMetaPressed;
    if (ctrl || _zoomed) {
      final c = _zoomFor(i);
      final cur = c.value.getMaxScaleOnAxis();
      final next = (cur * math.exp(-dy / 300)).clamp(1.0, 8.0);
      if (next <= 1.001) {
        c.value = Matrix4.identity();
        return;
      }
      final r = next / cur, p = e.localPosition;
      final out = (Matrix4.identity()
            ..translateByDouble(p.dx, p.dy, 0, 1)
            ..scaleByDouble(r, r, 1, 1)
            ..translateByDouble(-p.dx, -p.dy, 0, 1))
          .multiplied(c.value);
      // 가장자리 밖으로 밀려나지 않게
      final t = out.getTranslation();
      out.setTranslationRaw(
        t.x.clamp(math.min(0.0, -(next - 1) * view.width), 0.0),
        t.y.clamp(math.min(0.0, -(next - 1) * view.height), 0.0),
        0,
      );
      c.value = out;
      return;
    }
    // 터치패드는 잘게 여러 번 보내므로 잠깐 사이에는 한 장만 넘긴다
    final now = DateTime.now();
    if (now.difference(_lastWheel) < const Duration(milliseconds: 180)) return;
    _lastWheel = now;
    _go(dy > 0 ? 1 : -1);
  }

  // ---------------- 화면 ----------------

  /// 한 장씩 (좌우 · 위아래)
  Widget _paged() {
    TapDownDetails? lastDown;
    final vertical = _mode == 1;
    final view = MediaQuery.sizeOf(context);
    // 두 손가락이 닿으면 넘기기를 잠깐 멈춘다 (넘기기가 첫 손가락을 가져가 확대가 안 먹던 문제)
    return Listener(
      onPointerDown: (e) {
        _fingers.add(e.pointer);
        if (_fingers.length == 2) setState(() {});
      },
      onPointerUp: (e) => _lift(e.pointer),
      onPointerCancel: (e) => _lift(e.pointer),
      child: PageView.builder(
        key: ValueKey('pages-$_mode'),
        controller: _pages,
        scrollDirection: vertical ? Axis.vertical : Axis.horizontal,
        physics: _zoomed || _fingers.length >= 2 ? const NeverScrollableScrollPhysics() : const PageScrollPhysics(),
        itemCount: _n,
        onPageChanged: (i) {
          setState(() {
            _index = i;
            _zoomed = false;
          });
          _touch();
        },
        itemBuilder: (_, i) => Listener(
          // 위아래로 넘기기: 휠을 직접 받는다 (그대로 두면 쪽 사이에 어중간하게 멈추고, 동시에 확대도 된다)
          onPointerSignal: !vertical
              ? null
              : (e) {
                  if (e is PointerScrollEvent) {
                    GestureBinding.instance.pointerSignalResolver.register(e, (ev) => _wheelPaged(ev as PointerScrollEvent, i, view));
                  }
                },
          child: GestureDetector(
            onTap: () => setState(() => _showUi = !_showUi),
            onDoubleTapDown: (d) => lastDown = d,
            onDoubleTap: () => _toggleZoom(i, lastDown),
            child: InteractiveViewer(
              transformationController: _zoomFor(i),
              minScale: 1,
              maxScale: 8,
              // 위아래로 넘기기에서는 휠 확대를 끄고 위에서 직접 다룬다
              scaleFactor: vertical ? 1e9 : kDefaultMouseScrollToScaleFactor,
              child: SizedBox.expand(
                child: Image.file(
                  File(widget.images[i].path),
                  fit: BoxFit.contain,
                  filterQuality: FilterQuality.medium,
                  errorBuilder: (_, e, _) => Center(child: Text('열 수 없는 이미지\n$e', style: const TextStyle(color: Colors.white70))),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  /// 위아래로 이어 보기: 그림을 화면 폭에 맞춰 세로로 이어 붙인다
  Widget _continuous() {
    final view = MediaQuery.sizeOf(context);
    final w = math.min(view.width, 1100.0);
    final dpr = MediaQuery.devicePixelRatioOf(context);
    Widget item(int i) => KeyedSubtree(
          key: _itemKeys.putIfAbsent(i, () => GlobalKey()),
          child: Center(
            child: Image.file(
              File(widget.images[i].path),
              width: w,
              fit: BoxFit.fitWidth,
              // 화면에 보이는 크기로만 풀어 메모리를 아낀다 (큰 사진 여러 장이 한꺼번에 올라오므로)
              cacheWidth: (w * dpr).round(),
              filterQuality: FilterQuality.medium,
              gaplessPlayback: true,
              // 아직 못 읽은 그림은 자리를 잡아 둔다 (높이 0 이면 뒤 그림들이 한꺼번에 불려 온다)
              frameBuilder: (_, child, frame, sync) => sync || frame != null
                  ? child
                  : SizedBox(width: w, height: w * 1.3, child: const Center(child: CircularProgressIndicator(strokeWidth: 2))),
              errorBuilder: (_, e, _) => SizedBox(
                width: w,
                height: 160,
                child: Center(child: Text('열 수 없는 이미지: ${widget.images[i].fileName}', style: const TextStyle(color: Colors.white70))),
              ),
            ),
          ),
        );
    return GestureDetector(
      onTap: () => setState(() => _showUi = !_showUi),
      child: NotificationListener<ScrollNotification>(
        onNotification: (n) {
          if (n is ScrollUpdateNotification || n is ScrollEndNotification) _trackStrip();
          return false;
        },
        child: CustomScrollView(
          key: ValueKey('strip-$_anchor'),
          controller: _strip,
          center: _centerKey,
          slivers: [
            // 시작 그림보다 앞의 그림들 (위로 올리면 나온다)
            SliverList(delegate: SliverChildBuilderDelegate((_, i) => item(_anchor - 1 - i), childCount: _anchor)),
            SliverList(key: _centerKey, delegate: SliverChildBuilderDelegate((_, i) => item(_anchor + i), childCount: _n - _anchor)),
            const SliverToBoxAdapter(child: SizedBox(height: 80)),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final strip = _mode == 2;
    return CallbackShortcuts(
      bindings: {
        ...volumeKeyBindings(_s.volumeKeyTurn, (d) => strip ? _scrollBy(d * 0.85) : _go(d)),
        const SingleActivator(LogicalKeyboardKey.arrowRight): () => _go(1),
        const SingleActivator(LogicalKeyboardKey.arrowLeft): () => _go(-1),
        // 위아래 키: 이어 보기에서는 화면을 내리고, 한 장씩 볼 때는 다음 · 이전 그림
        const SingleActivator(LogicalKeyboardKey.arrowDown): () => strip ? _scrollBy(0.5) : _go(1),
        const SingleActivator(LogicalKeyboardKey.arrowUp): () => strip ? _scrollBy(-0.5) : _go(-1),
        const SingleActivator(LogicalKeyboardKey.pageDown): () => strip ? _scrollBy(0.85) : _go(1),
        const SingleActivator(LogicalKeyboardKey.pageUp): () => strip ? _scrollBy(-0.85) : _go(-1),
        const SingleActivator(LogicalKeyboardKey.space): _toggleSlideshow,
        const SingleActivator(LogicalKeyboardKey.escape): () => Navigator.maybePop(context),
      },
      child: Focus(
        autofocus: true,
        child: Scaffold(
          backgroundColor: Colors.black,
          body: Stack(children: [
            Positioned.fill(child: strip ? _continuous() : _paged()),
            if (_showUi) ...[
              Positioned(
                top: 0,
                left: 0,
                right: 0,
                child: AppBar(
                  backgroundColor: Colors.black54,
                  foregroundColor: Colors.white,
                  title: Text('${_item.title}  (${_index + 1}/$_n)', overflow: TextOverflow.ellipsis),
                  actions: [
                    // 보기 방식: 좌우 / 위아래 한 장씩 / 위아래 이어 보기
                    PopupMenuButton<int>(
                      tooltip: '보기 방식 (넘기는 방향)',
                      icon: Icon(switch (_mode) { 1 => Icons.swap_vert, 2 => Icons.view_day_outlined, _ => Icons.swap_horiz }),
                      onSelected: (v) => _s.imageViewMode = v,
                      itemBuilder: (_) => [
                        CheckedPopupMenuItem(value: 0, checked: _mode == 0, child: const Text('좌우로 넘기기 (한 장씩)')),
                        CheckedPopupMenuItem(value: 1, checked: _mode == 1, child: const Text('위아래로 넘기기 (한 장씩)')),
                        CheckedPopupMenuItem(value: 2, checked: _mode == 2, child: const Text('위아래로 이어 보기 (스크롤)')),
                      ],
                    ),
                    IconButton(
                      tooltip: _slideshow == null ? '슬라이드쇼 (Space)' : '멈춤',
                      icon: Icon(_slideshow == null ? Icons.slideshow : Icons.pause),
                      onPressed: _toggleSlideshow,
                    ),
                    IconButton(
                      tooltip: '즐겨찾기',
                      icon: Icon(_item.favorite ? Icons.favorite : Icons.favorite_border),
                      onPressed: () {
                        setState(() => _item.favorite = !_item.favorite);
                        _app.save(_item);
                      },
                    ),
                    IconButton(
                      tooltip: '정보 / 태그',
                      icon: const Icon(Icons.info_outline),
                      onPressed: () => Navigator.push(context, MaterialPageRoute(builder: (_) => DetailPage(item: _item))),
                    ),
                  ],
                ),
              ),
              // 넓은 화면: 넘기기 단추 (좌우로 넘길 때는 양옆, 위아래로 넘길 때는 오른쪽에 위 · 아래)
              if (MediaQuery.sizeOf(context).width >= 600 && _mode == 0) ...[
                Positioned(left: 8, top: 0, bottom: 0, child: Center(child: _NavButton(Icons.chevron_left, () => _go(-1)))),
                Positioned(right: 8, top: 0, bottom: 0, child: Center(child: _NavButton(Icons.chevron_right, () => _go(1)))),
              ],
              if (MediaQuery.sizeOf(context).width >= 600 && _mode != 0)
                Positioned(
                  right: 8,
                  top: 0,
                  bottom: 0,
                  child: Center(
                    child: Column(mainAxisSize: MainAxisSize.min, children: [
                      _NavButton(Icons.expand_less, () => _go(-1)),
                      const SizedBox(height: 12),
                      _NavButton(Icons.expand_more, () => _go(1)),
                    ]),
                  ),
                ),
            ],
          ]),
        ),
      ),
    );
  }
}

class _NavButton extends StatelessWidget {
  final IconData icon;
  final VoidCallback onTap;
  const _NavButton(this.icon, this.onTap);
  @override
  Widget build(BuildContext context) => IconButton.filled(
        style: IconButton.styleFrom(backgroundColor: Colors.black45, foregroundColor: Colors.white),
        iconSize: 32,
        icon: Icon(icon),
        onPressed: onTap,
      );
}
