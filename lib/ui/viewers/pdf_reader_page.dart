
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:pdfrx/pdfrx.dart';
import 'package:provider/provider.dart';

import '../../app_state.dart';
import '../../models/media_item.dart';
import '../../services/settings.dart';
import '../../services/pdf_text.dart';
import 'open_item.dart';
import 'read_aloud.dart';
import 'viewer_chrome.dart';

/// PDF 뷰어 — 만화/텍스트 뷰어와 같은 도구줄 + 아래 썸네일 줄
class PdfReaderPage extends StatefulWidget {
  final MediaItem item;
  const PdfReaderPage({super.key, required this.item});

  @override
  State<PdfReaderPage> createState() => _PdfReaderPageState();
}

class _PdfReaderPageState extends State<PdfReaderPage> {
  final _ctrl = PdfViewerController();
  final _strip = ScrollController();
  late final AppState _app = context.read<AppState>();
  PdfDocument? _doc;
  int _page = 1;
  int _pages = 0;
  bool _chrome = true;
  bool _fullscreen = false;
  bool _readAloud = false;

  /// 쪽의 글: PDF 안의 글자를 쓰고, 없으면(스캔본) 그림으로 그려서 글자 인식
  Future<String> _pageText(int i) async {
    final doc = _doc;
    if (doc == null || i < 0 || i >= doc.pages.length) return '';
    return PdfText.pageText(doc.pages[i]);
  }

  MediaItem get item => widget.item;
  double get _progress => _pages <= 1 ? 1 : (_page - 1) / (_pages - 1);

  @override
  void initState() {
    super.initState();
    _app;
    _page = int.tryParse(item.position ?? '') ?? 1;
  }

  @override
  void dispose() {
    if (_pages > 0) _app.saveProgress(item, '$_page', _progress).then((_) => _app.refresh());
    if (_fullscreen) SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
    _strip.dispose();
    super.dispose();
  }

  void _go(int page) {
    if (_pages == 0) return;
    _ctrl.goToPage(pageNumber: page.clamp(1, _pages));
  }

  void _toggleFullscreen() {
    setState(() {
      _fullscreen = !_fullscreen;
      _chrome = !_fullscreen;
    });
    SystemChrome.setEnabledSystemUIMode(_fullscreen ? SystemUiMode.immersiveSticky : SystemUiMode.edgeToEdge);
  }

  void _scrollStrip() {
    if (!_strip.hasClients) return;
    const w = 98.0;
    final pos = _strip.position;
    _strip.animateTo(((_page - 1) * w - pos.viewportDimension / 2 + w / 2).clamp(0.0, pos.maxScrollExtent),
        duration: const Duration(milliseconds: 200), curve: Curves.easeOut);
  }

  @override
  Widget build(BuildContext context) {
    final s = context.watch<Settings>();
    final marked = s.bookmarks(item.id!).contains(_page);
    final zoom = _pages == 0 ? 1.0 : _ctrl.currentZoom;

    return CallbackShortcuts(
      bindings: {
        const SingleActivator(LogicalKeyboardKey.arrowRight): () => _go(_page + 1),
        const SingleActivator(LogicalKeyboardKey.pageDown): () => _go(_page + 1),
        const SingleActivator(LogicalKeyboardKey.arrowLeft): () => _go(_page - 1),
        const SingleActivator(LogicalKeyboardKey.pageUp): () => _go(_page - 1),
        const SingleActivator(LogicalKeyboardKey.home): () => _go(1),
        const SingleActivator(LogicalKeyboardKey.end): () => _go(_pages),
        const SingleActivator(LogicalKeyboardKey.keyF): _toggleFullscreen,
        const SingleActivator(LogicalKeyboardKey.keyB): () => s.toggleBookmark(item.id!, _page),
        const SingleActivator(LogicalKeyboardKey.escape): () {
          if (_fullscreen) {
            _toggleFullscreen();
          } else {
            Navigator.maybePop(context);
          }
        },
      },
      child: Focus(
        autofocus: true,
        child: Scaffold(
          backgroundColor: viewerBg,
          body: SafeArea(
            child: Column(children: [
              if (_chrome)
                Container(
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
                      Text('$_page / $_pages · ${(_progress * 100).round()}%', style: const TextStyle(color: Colors.white60, fontSize: 12)),
                      NextVolumeButton(item: item),
                      if (MediaQuery.sizeOf(context).width < 900) ...[
                        IconButton(
                          tooltip: '소리 내어 읽기',
                          icon: Icon(Icons.record_voice_over, color: _readAloud ? toolActive : Colors.white),
                          onPressed: () => setState(() => _readAloud = !_readAloud),
                        ),
                      ],
                    ]),
                    const SizedBox(height: 4),
                    SingleChildScrollView(
                      scrollDirection: Axis.horizontal,
                      reverse: MediaQuery.sizeOf(context).width >= 900,
                      child: Row(children: [
                        ToolGroup([
                          ToolBtn(icon: Icons.keyboard_double_arrow_left, tooltip: '처음 (Home)', onTap: () => _go(1)),
                          ToolBtn(icon: Icons.keyboard_double_arrow_right, tooltip: '끝 (End)', onTap: () => _go(_pages)),
                        ]),
                        ToolGroup([
                          ToolBtn(icon: Icons.chevron_left, tooltip: '이전 쪽', onTap: () => _go(_page - 1)),
                          ToolBtn(icon: Icons.chevron_right, tooltip: '다음 쪽', onTap: () => _go(_page + 1)),
                        ]),
                        ToolGroup([
                          ToolBtn(icon: Icons.zoom_out, tooltip: '축소', onTap: () => _ctrl.zoomDown().then((_) => setState(() {}))),
                          ToolBtn(label: '${(zoom * 100).round()}%', tooltip: '배율'),
                          ToolBtn(icon: Icons.zoom_in, tooltip: '확대', onTap: () => _ctrl.zoomUp().then((_) => setState(() {}))),
                        ]),
                        ToolGroup([
                          ToolBtn(
                            icon: Icons.view_carousel,
                            tooltip: '썸네일 줄',
                            active: s.viewerSlider,
                            onTap: () => s.viewerSlider = !s.viewerSlider,
                          ),
                        ]),
                        ToolGroup([
                          ToolBtn(
                            icon: marked ? Icons.bookmark : Icons.bookmark_border,
                            tooltip: '책갈피 (B)',
                            active: marked,
                            onTap: () => s.toggleBookmark(item.id!, _page),
                          ),
                        ]),
                        ToolGroup([
                          ToolBtn(
                            icon: Icons.record_voice_over,
                            tooltip: '소리 내어 읽기 (스캔본은 글자 인식)',
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
                              ('← → / PgUp PgDn', '이전 / 다음 쪽'),
                              ('Home / End', '처음 / 끝'),
                              ('Ctrl+휠', '확대 / 축소'),
                              ('F', '전체화면'),
                              ('B', '책갈피'),
                            ]),
                          ),
                        ]),
                      ]),
                    ),
                  ]),
                ),
              Expanded(
                child: Stack(children: [
                  Positioned.fill(
                    child: PdfViewer.file(
                  item.path,
                  controller: _ctrl,
                  initialPageNumber: _page,
                  params: PdfViewerParams(
                    backgroundColor: viewerBg,
                    onViewerReady: (doc, ctrl) => setState(() {
                      _doc = doc;
                      _pages = doc.pages.length;
                    }),
                    onPageChanged: (p) {
                      if (p == null) return;
                      setState(() => _page = p);
                      _app.saveProgress(item, '$p', _progress);
                      _scrollStrip();
                    },
                  ),
                ),
                  ),
                  if (_readAloud && _doc != null)
                    Positioned(
                      left: 12,
                      right: 12,
                      bottom: 12,
                      child: Center(
                        child: ReadAloudBar(
                          pageCount: _pages,
                          currentPage: () => _page - 1,
                          textOf: _pageText,
                          goTo: (i) => _go(i + 1),
                          onClose: () => setState(() => _readAloud = false),
                        ),
                      ),
                    ),
                ]),
              ),
              if (_chrome && s.viewerSlider && _doc != null)
                Container(
                  height: 128,
                  color: const Color(0xFF141414),
                  child: ListView.builder(
                    controller: _strip,
                    scrollDirection: Axis.horizontal,
                    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
                    itemCount: _pages,
                    itemBuilder: (_, i) {
                      final on = i + 1 == _page;
                      return GestureDetector(
                        onTap: () => _go(i + 1),
                        child: Container(
                          width: 88,
                          margin: const EdgeInsets.symmetric(horizontal: 5),
                          padding: const EdgeInsets.all(4),
                          decoration: BoxDecoration(
                            color: toolBg,
                            borderRadius: BorderRadius.circular(6),
                            border: Border.all(color: on ? toolActive : Colors.white12, width: on ? 2 : 1),
                          ),
                          child: Column(children: [
                            Expanded(child: PdfPageView(document: _doc, pageNumber: i + 1)),
                            const SizedBox(height: 2),
                            Text('${i + 1}', style: const TextStyle(color: Colors.white70, fontSize: 11)),
                          ]),
                        ),
                      );
                    },
                  ),
                ),
            ]),
          ),
        ),
      ),
    );
  }
}
