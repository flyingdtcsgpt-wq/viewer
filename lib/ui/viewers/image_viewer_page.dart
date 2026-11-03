import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../../app_state.dart';
import '../../models/media_item.dart';
import '../../services/settings.dart';
import '../detail_page.dart';

/// 그림 뷰어: 좌우 넘기기, 확대/이동(두 손가락·휠·더블탭), 슬라이드쇼
class ImageViewerPage extends StatefulWidget {
  final List<MediaItem> images;
  final int initialIndex;
  const ImageViewerPage({super.key, required this.images, required this.initialIndex});

  @override
  State<ImageViewerPage> createState() => _ImageViewerPageState();
}

class _ImageViewerPageState extends State<ImageViewerPage> {
  late final PageController _pages = PageController(initialPage: widget.initialIndex);
  late int _index = widget.initialIndex;
  late final AppState _app = context.read<AppState>();
  final _zoom = <int, TransformationController>{};
  bool _zoomed = false;
  bool _showUi = true;
  Timer? _slideshow;

  MediaItem get _item => widget.images[_index];

  @override
  void initState() {
    super.initState();
    _touch();
  }

  @override
  void dispose() {
    _slideshow?.cancel();
    for (final z in _zoom.values) {
      z.dispose();
    }
    _pages.dispose();
    // 화면을 닫는 중에는 알림을 보낼 수 없어서 다음 순간에
    Future.microtask(_app.refresh);
    super.dispose();
  }

  void _touch() => _app.saveProgress(_item, '0', 0); // '최근 본' 기록용

  TransformationController _zoomFor(int i) => _zoom.putIfAbsent(i, () {
        final c = TransformationController();
        c.addListener(() {
          final z = c.value.getMaxScaleOnAxis() > 1.01;
          if (i == _index && z != _zoomed) setState(() => _zoomed = z);
        });
        return c;
      });

  void _go(int delta) {
    final target = _index + delta;
    if (target < 0 || target >= widget.images.length) {
      if (_slideshow != null) _toggleSlideshow();
      return;
    }
    _pages.animateToPage(target, duration: const Duration(milliseconds: 220), curve: Curves.easeOut);
  }

  void _toggleSlideshow() {
    setState(() {
      if (_slideshow != null) {
        _slideshow!.cancel();
        _slideshow = null;
      } else {
        final sec = context.read<Settings>().slideshowSeconds;
        _slideshow = Timer.periodic(Duration(seconds: sec), (_) => _go(1));
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

  @override
  Widget build(BuildContext context) {
    TapDownDetails? lastDown;
    return CallbackShortcuts(
      bindings: {
        const SingleActivator(LogicalKeyboardKey.arrowRight): () => _go(1),
        const SingleActivator(LogicalKeyboardKey.arrowLeft): () => _go(-1),
        const SingleActivator(LogicalKeyboardKey.space): _toggleSlideshow,
        const SingleActivator(LogicalKeyboardKey.escape): () => Navigator.maybePop(context),
      },
      child: Focus(
        autofocus: true,
        child: Scaffold(
          backgroundColor: Colors.black,
          body: Stack(children: [
            PageView.builder(
              controller: _pages,
              physics: _zoomed ? const NeverScrollableScrollPhysics() : const PageScrollPhysics(),
              itemCount: widget.images.length,
              onPageChanged: (i) {
                setState(() {
                  _index = i;
                  _zoomed = false;
                });
                _touch();
              },
              itemBuilder: (_, i) => GestureDetector(
                onTap: () => setState(() => _showUi = !_showUi),
                onDoubleTapDown: (d) => lastDown = d,
                onDoubleTap: () => _toggleZoom(i, lastDown),
                child: InteractiveViewer(
                  transformationController: _zoomFor(i),
                  minScale: 1,
                  maxScale: 8,
                  child: SizedBox.expand(
                    child: Image.file(
                      File(widget.images[i].path),
                      fit: BoxFit.contain,
                      filterQuality: FilterQuality.medium,
                      errorBuilder: (_, e, _) =>
                          Center(child: Text('열 수 없는 이미지\n$e', style: const TextStyle(color: Colors.white70))),
                    ),
                  ),
                ),
              ),
            ),
            if (_showUi) ...[
              Positioned(
                top: 0,
                left: 0,
                right: 0,
                child: AppBar(
                  backgroundColor: Colors.black54,
                  foregroundColor: Colors.white,
                  title: Text('${_item.title}  (${_index + 1}/${widget.images.length})', overflow: TextOverflow.ellipsis),
                  actions: [
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
              if (MediaQuery.sizeOf(context).width >= 600) ...[
                Positioned(left: 8, top: 0, bottom: 0, child: Center(child: _NavButton(Icons.chevron_left, () => _go(-1)))),
                Positioned(right: 8, top: 0, bottom: 0, child: Center(child: _NavButton(Icons.chevron_right, () => _go(1)))),
              ],
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
