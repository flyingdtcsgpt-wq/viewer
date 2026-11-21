import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:pdfrx/pdfrx.dart';
import 'package:provider/provider.dart';

import '../../edition.dart';
import '../../app_state.dart';
import '../../models/media_item.dart';
import '../../services/settings.dart';
import '../../services/background_reading.dart';
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
    // (진행률을 초기화한 책은 위치가 0 으로 남아 있다 → 첫 쪽)
    final saved = int.tryParse(item.position ?? '') ?? 1;
    _page = saved < 1 ? 1 : saved;
    if (context.read<Settings>().keepScreenOn) {
      _awake = true;
      ScreenAwake.hold();
    }
  }

  bool _awake = false; // 화면 켜 두기를 걸었는가

  @override
  void dispose() {
    if (_pages > 0) _app.saveProgress(item, '$_page', _progress).then((_) => _app.refresh());
    if (_awake) ScreenAwake.release();
    if (_fullscreen) setViewerFullscreen(false);
    _strip.dispose();
    super.dispose();
  }

  void _go(int page) {
    if (_pages == 0) return;
    // 마지막 쪽에서 더 넘기면: 다음 권으로 갈지 묻는다 (없으면 "마지막 권입니다")
    if (page > _pages) {
      _app.saveProgress(item, '$_pages', 1.0);
      askNextVolume(context, item);
      return;
    }
    _ctrl.goToPage(pageNumber: page.clamp(1, _pages));
  }

  /// 책갈피 목록 (눌러서 그 쪽으로, × 로 지우기)
  void _showBookmarks(Settings s) => showBookmarkSheet(
        context,
        marks: s.bookmarks(item.id!),
        label: (m) => '$m쪽',
        onGo: _go,
        onRemove: (m) => s.toggleBookmark(item.id!, m),
      );

  static final _touch = Platform.isAndroid || Platform.isIOS;

  void _toggleFullscreen() {
    setState(() {
      _fullscreen = !_fullscreen;
      _chrome = !_fullscreen;
    });
    setViewerFullscreen(_fullscreen);
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

    return CallbackShortcuts(
      bindings: {
        ...volumeKeyBindings(s.volumeKeyTurn, (d) => _go(_page + d)),
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
        // 전체화면에서 "뒤로" 는 먼저 전체화면을 끝낸다 (PDF 는 화면을 눌러 메뉴를 되살릴 수 없다)
        child: PopScope(
          canPop: !_fullscreen,
          onPopInvokedWithResult: (didPop, _) {
            if (!didPop && _fullscreen) _toggleFullscreen();
          },
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
                      if (MediaQuery.sizeOf(context).width < 900 && !kStore) ...[
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
                          ToolBtn(icon: Icons.zoom_out, tooltip: '축소', onTap: () => _ctrl.zoomDown()),
                          // 두 손가락 · Ctrl+휠로 바꾼 배율도 바로 따라간다
                          ListenableBuilder(
                            listenable: _ctrl,
                            builder: (_, _) => ToolBtn(label: '${((_ctrl.isReady ? _ctrl.currentZoom : 1.0) * 100).round()}%', tooltip: '지금 배율'),
                          ),
                          ToolBtn(icon: Icons.zoom_in, tooltip: '확대', onTap: () => _ctrl.zoomUp()),
                        ]),
                        ToolGroup([
                          ToolBtn(
                            icon: Icons.view_carousel,
                            tooltip: '썸네일 줄',
                            active: s.viewerSlider,
                            onTap: () => s.viewerSlider = !s.viewerSlider,
                          ),
                        ]),
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
                        if (!kStore)
                        ToolGroup([
                          ToolBtn(
                            icon: Icons.record_voice_over,
                            tooltip: '소리 내어 읽기 (스캔본은 글자 인식)',
                            active: _readAloud,
                            onTap: () => setState(() => _readAloud = !_readAloud),
                          ),
                        ]),
                        // 어두운 화면(색 뒤집기) · 눈 보호
                        ToolGroup([
                          ToolBtn(
                            icon: Icons.invert_colors,
                            label: '다크',
                            tooltip: '어두운 화면: 흰 종이를 검은 바탕으로 (색 뒤집기)',
                            active: s.pdfInvert,
                            onTap: () => s.pdfInvert = !s.pdfInvert,
                          ),
                          const EyeCareBtn(panel: false),
                        ]),
                        ToolGroup([ToolBtn(icon: _fullscreen ? Icons.fullscreen_exit : Icons.fullscreen, tooltip: '전체화면 (F)', onTap: _toggleFullscreen)]),
                        ToolGroup([
                          ToolBtn(
                            icon: Icons.help_outline,
                            tooltip: '조작법 · 단축키',
                            onTap: () => showViewerHelp(context, const [
                              ('← → / PgUp PgDn', '이전 / 다음 쪽'),
                              ('Home / End', '처음 / 끝'),
                              ('Ctrl+휠', '확대 / 축소'),
                              ('F', '전체화면 (끝낼 때: F · Esc · 오른쪽 위 단추)'),
                              ('B', '책갈피: 지금 쪽 표시 (옆의 목록 단추로 책갈피한 쪽에 바로 가기)'),
                              ('마지막 쪽에서 한 번 더', '다음 권으로 (없으면 "마지막 권" 안내)'),
                            ], touch: const [
                              ('좌우 가장자리 누르기', '이전 / 다음 쪽 (설정 › 뷰어에서 끄기 · 왼손잡이용 고르기)'),
                              ('가운데 누르기', '위아래 메뉴 보이기 · 숨기기'),
                              ('책갈피 단추', '지금 쪽을 표시 · 다시 누르면 지움'),
                              ('책갈피 목록 단추 (옆)', '책갈피한 쪽 목록 → 누르면 그 쪽으로'),
                              ('위아래로 밀기', '쪽 넘기기'),
                              ('두 손가락 벌리기 · 두 번 누르기', '확대 · 축소'),
                              ('아래 썸네일 줄', '원하는 쪽으로 바로 가기'),
                              ('다크 · 눈 보호 단추', '어두운 화면(색 뒤집기) / 푸른빛 줄이기'),
                              ('마지막 쪽의 "다음 권 보기"', '다음 권으로'),
                              ('볼륨 버튼', '쪽 넘기기 (설정 › 뷰어에서 켜기)'),
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
                    // 눈 보호 → (어두운 화면이면) 색 뒤집기 순서로 겹친다
                    child: EyeCare(
                        child: StableFilter(
                      // 어두운 화면: 색상은 두고 밝기만 뒤집는다 (흰 종이 → 검은 바탕, 검은 글 → 밝은 글)
                      filter: s.pdfInvert ? invertKeepHue : null,
                      child: PdfViewer.file(
                  item.path,
                  controller: _ctrl,
                  initialPageNumber: _page,
                  params: PdfViewerParams(
                    // 색을 뒤집을 때는 바탕도 함께 뒤집히므로 미리 밝은 회색을 준다 (뒤집히면 원래의 어두운 바탕)
                    backgroundColor: s.pdfInvert ? const Color(0xFFE4E4E4) : viewerBg,
                    // 터치 기기: 좌우 가장자리를 누르면 쪽 넘김, 가운데를 누르면 위아래 메뉴 보이기 · 숨기기 (만화 · 책과 같게)
                    onGeneralTap: !_touch
                        ? null
                        : (ctx, ctrl, d) {
                            if (d.type != PdfViewerGeneralTapType.tap || d.tapOn == PdfViewerPart.selectedText) return false;
                            final x = d.localPosition.dx / MediaQuery.sizeOf(context).width;
                            if (s.tapToTurn && (x < 0.25 || x > 0.75)) {
                              _go(_page + ((x < 0.25) == s.tapLeftIsNext ? 1 : -1));
                            } else {
                              setState(() => _chrome = !_chrome);
                            }
                            return false; // (글자 선택 풀기 같은 기본 동작은 그대로)
                          },
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
                    )),
                  ),
                  // 마지막 쪽에 오면 아래에 작게 안내 (넘기지 않고도 다음 권으로)
                  if (_pages > 1 && _page >= _pages)
                    Positioned(
                      right: 16,
                      bottom: 16,
                      child: Material(
                        color: const Color(0xE0202020),
                        borderRadius: BorderRadius.circular(24),
                        child: InkWell(
                          borderRadius: BorderRadius.circular(24),
                          onTap: () => askNextVolume(context, item),
                          child: Padding(
                            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
                            child: Text(
                              _app.nextVolume(item) == null ? '마지막 쪽 · 다음 권이 없습니다' : '마지막 쪽 · 다음 권 보기 ›',
                              style: const TextStyle(color: Colors.white),
                            ),
                          ),
                        ),
                      ),
                    ),
                  if (_fullscreen && !_chrome) FullscreenExitBtn(onTap: _toggleFullscreen),
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
                      final mark = s.bookmarks(item.id!).contains(i + 1);
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
                            Expanded(
                              child: Stack(children: [
                                Positioned.fill(child: PdfPageView(document: _doc, pageNumber: i + 1)),
                                // 책갈피를 해 둔 쪽
                                if (mark) const Positioned(right: 0, top: 0, child: Icon(Icons.bookmark, color: Colors.redAccent, size: 18)),
                              ]),
                            ),
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
      ),
    );
  }
}
