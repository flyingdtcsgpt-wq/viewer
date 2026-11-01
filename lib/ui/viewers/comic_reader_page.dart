import 'dart:typed_data';

import 'package:archive/archive_io.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;
import 'package:provider/provider.dart';

import '../../app_state.dart';
import '../../models/media_item.dart';
import '../../services/settings.dart';

/// 만화(CBZ/ZIP) 뷰어
/// - 한 쪽 / 두 쪽 펼침 / 세로 스크롤(웹툰)
/// - 오른쪽→왼쪽(일본식) 넘김 전환
/// - 화면 좌/우 터치, 방향키, 휠로 넘김
class ComicReaderPage extends StatefulWidget {
  final MediaItem item;
  const ComicReaderPage({super.key, required this.item});

  @override
  State<ComicReaderPage> createState() => _ComicReaderPageState();
}

class _ComicReaderPageState extends State<ComicReaderPage> {
  late final AppState _app = context.read<AppState>();
  InputFileStream? _input;
  List<ArchiveFile> _files = [];
  final _cache = <int, Uint8List>{};
  Object? _error;
  bool _loaded = false;

  int _page = 0; // 0부터
  bool _showUi = false;
  PageController? _pager;
  final _retired = <PageController>[]; // 모드 전환 시 쓰던 컨트롤러 (화면에서 빠진 뒤 정리)
  final _scroll = ScrollController();
  final _pageKeys = <int, GlobalKey>{};

  MediaItem get item => widget.item;
  double get _progress => _files.length <= 1 ? 1 : _page / (_files.length - 1);

  @override
  void initState() {
    super.initState();
    _app;
    _open();
  }

  void _open() {
    try {
      _input = InputFileStream(item.path);
      final zip = ZipDecoder().decodeStream(_input!);
      _files = zip.files.where((f) => f.isFile && imageExts.contains(p.extension(f.name).toLowerCase())).toList()
        ..sort((a, b) => _natural(a.name, b.name));
      _page = (int.tryParse(item.position ?? '') ?? 0).clamp(0, _files.isEmpty ? 0 : _files.length - 1);
    } catch (e) {
      _error = e;
    }
    _loaded = true;
  }

  @override
  void dispose() {
    if (_files.isNotEmpty) _app.saveProgress(item, '$_page', _progress).then((_) => _app.refresh());
    _input?.closeSync();
    _pager?.dispose();
    for (final c in _retired) {
      c.dispose();
    }
    _scroll.dispose();
    super.dispose();
  }

  Uint8List _bytes(int i) {
    final hit = _cache[i];
    if (hit != null) return hit;
    final b = _files[i].content;
    _cache[i] = b;
    if (_cache.length > 16) _cache.remove(_cache.keys.first); // 메모리 제한
    return b;
  }

  // ---------- 쪽 묶음 (두 쪽 모드) ----------
  List<List<int>> _spreads(Settings s) {
    if (s.comicMode != 1) return [for (var i = 0; i < _files.length; i++) [i]];
    final out = <List<int>>[];
    var i = 0;
    if (s.comicCoverAlone && _files.isNotEmpty) out.add([i++]);
    for (; i < _files.length; i += 2) {
      out.add([i, if (i + 1 < _files.length) i + 1]);
    }
    return out;
  }

  int _spreadOf(List<List<int>> spreads, int page) => spreads.indexWhere((g) => g.contains(page)).clamp(0, spreads.length - 1);

  void _setPage(int page) {
    _page = page.clamp(0, _files.length - 1);
    _app.saveProgress(item, '$_page', _progress);
  }

  /// dir: +1 다음, -1 이전 (읽는 방향 기준)
  void _turn(int dir, Settings s) {
    if (s.comicMode == 2) {
      if (!_scroll.hasClients) return;
      final pos = _scroll.position;
      _scroll.animateTo((pos.pixels + dir * pos.viewportDimension * 0.85).clamp(0.0, pos.maxScrollExtent),
          duration: const Duration(milliseconds: 200), curve: Curves.easeOut);
      return;
    }
    final spreads = _spreads(s);
    final target = _spreadOf(spreads, _page) + dir;
    if (target < 0 || target >= spreads.length) return;
    _pager?.animateToPage(target, duration: const Duration(milliseconds: 200), curve: Curves.easeOut);
  }

  void _jump(int page, Settings s) {
    setState(() => _setPage(page));
    if (s.comicMode == 2) {
      final ctx = _pageKeys[page]?.currentContext;
      if (ctx != null) {
        Scrollable.ensureVisible(ctx);
      } else if (_scroll.hasClients) {
        // 아직 안 그려진 쪽이면 비율로 대략 이동
        _scroll.jumpTo(_scroll.position.maxScrollExtent * _progress);
      }
    } else {
      _pager?.jumpToPage(_spreadOf(_spreads(s), page));
    }
  }

  @override
  Widget build(BuildContext context) {
    final s = context.watch<Settings>();
    if (!_loaded) return const Scaffold(body: Center(child: CircularProgressIndicator()));
    if (_error != null || _files.isEmpty) {
      return Scaffold(
        appBar: AppBar(title: Text(item.title)),
        body: Center(child: Text(_error != null ? '열 수 없습니다: $_error' : '이미지가 없는 압축 파일입니다')),
      );
    }

    final rtl = s.comicRtl;
    // 화면 왼쪽/오른쪽이 "다음"인지는 읽는 방향에 따라 다르다
    void tapSide(bool leftSide) => _turn((leftSide ? -1 : 1) * (rtl && s.comicMode != 2 ? -1 : 1), s);

    final content = s.comicMode == 2 ? _vertical() : _paged(s, rtl);

    return CallbackShortcuts(
      bindings: {
        const SingleActivator(LogicalKeyboardKey.arrowLeft): () => tapSide(true),
        const SingleActivator(LogicalKeyboardKey.arrowRight): () => tapSide(false),
        const SingleActivator(LogicalKeyboardKey.arrowDown): () => _turn(1, s),
        const SingleActivator(LogicalKeyboardKey.arrowUp): () => _turn(-1, s),
        const SingleActivator(LogicalKeyboardKey.space): () => _turn(1, s),
        const SingleActivator(LogicalKeyboardKey.pageDown): () => _turn(1, s),
        const SingleActivator(LogicalKeyboardKey.pageUp): () => _turn(-1, s),
        const SingleActivator(LogicalKeyboardKey.escape): () => Navigator.maybePop(context),
      },
      child: Focus(
        autofocus: true,
        child: Scaffold(
          backgroundColor: Colors.black,
          body: Stack(children: [
            Positioned.fill(
              child: LayoutBuilder(
                builder: (context, c) => GestureDetector(
                  behavior: HitTestBehavior.translucent,
                  onTapUp: (d) {
                    final x = d.localPosition.dx / c.maxWidth;
                    if (x < 0.3) {
                      tapSide(true);
                    } else if (x > 0.7) {
                      tapSide(false);
                    } else {
                      setState(() => _showUi = !_showUi);
                    }
                  },
                  child: content,
                ),
              ),
            ),
            if (_showUi) ..._overlay(s, rtl),
          ]),
        ),
      ),
    );
  }

  Widget _paged(Settings s, bool rtl) {
    final spreads = _spreads(s);
    final start = _spreadOf(spreads, _page);
    _pager ??= PageController(initialPage: start);
    return PageView.builder(
      key: ValueKey('paged-${s.comicMode}-${s.comicCoverAlone}'),
      controller: _pager,
      reverse: rtl, // 오른쪽→왼쪽
      itemCount: spreads.length,
      onPageChanged: (i) => setState(() => _setPage(spreads[i].first)),
      itemBuilder: (_, i) {
        final g = spreads[i];
        if (g.length == 1) {
          return InteractiveViewer(maxScale: 6, child: Center(child: _img(g.first, BoxFit.contain)));
        }
        // 두 쪽: 읽는 순서상 첫 쪽이 rtl 이면 오른쪽에 온다
        final first = Expanded(child: Align(alignment: rtl ? Alignment.centerLeft : Alignment.centerRight, child: _img(g[0], BoxFit.contain)));
        final second = Expanded(child: Align(alignment: rtl ? Alignment.centerRight : Alignment.centerLeft, child: _img(g[1], BoxFit.contain)));
        return InteractiveViewer(maxScale: 6, child: Row(children: rtl ? [second, first] : [first, second]));
      },
    );
  }

  Widget _vertical() {
    final initial = _page;
    return NotificationListener<ScrollEndNotification>(
      onNotification: (_) {
        // 화면 위쪽에 걸친 쪽 찾기
        for (final e in _pageKeys.entries) {
          final box = e.value.currentContext?.findRenderObject() as RenderBox?;
          if (box == null || !box.attached) continue;
          final y = box.localToGlobal(Offset.zero).dy;
          if (y <= 80 && y + box.size.height > 80) {
            if (e.key != _page) setState(() => _setPage(e.key));
            break;
          }
        }
        return false;
      },
      child: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 900),
          child: ListView.builder(
            controller: _scroll,
            cacheExtent: 3000,
            itemCount: _files.length,
            itemBuilder: (_, i) {
              final key = _pageKeys.putIfAbsent(i, () => GlobalKey());
              if (i == 0 && initial > 0) {
                // 처음 열 때 저장된 쪽으로 이동
                WidgetsBinding.instance.addPostFrameCallback((_) => _jumpToInitial(initial));
              }
              return KeyedSubtree(key: key, child: _img(i, BoxFit.fitWidth));
            },
          ),
        ),
      ),
    );
  }

  void _retirePager() {
    if (_pager != null) _retired.add(_pager!);
    _pager = null;
  }

  bool _initialDone = false;
  Future<void> _jumpToInitial(int page) async {
    if (_initialDone || !_scroll.hasClients) return;
    _initialDone = true;
    // 목표 쪽이 그려질 때까지 조금씩 내려간다
    for (var tries = 0; tries < 200; tries++) {
      final ctx = _pageKeys[page]?.currentContext;
      if (ctx != null) {
        if (ctx.mounted) Scrollable.ensureVisible(ctx);
        return;
      }
      final pos = _scroll.position;
      if (pos.pixels >= pos.maxScrollExtent) return;
      _scroll.jumpTo((pos.pixels + pos.viewportDimension * 2).clamp(0.0, pos.maxScrollExtent));
      await Future<void>.delayed(const Duration(milliseconds: 16));
    }
  }

  Widget _img(int i, BoxFit fit) => Image.memory(
        _bytes(i),
        fit: fit,
        gaplessPlayback: true,
        filterQuality: FilterQuality.medium,
        errorBuilder: (_, _, _) => const SizedBox(height: 200, child: Icon(Icons.broken_image, color: Colors.white54)),
      );

  List<Widget> _overlay(Settings s, bool rtl) => [
        Positioned(
          top: 0,
          left: 0,
          right: 0,
          child: AppBar(
            backgroundColor: Colors.black87,
            foregroundColor: Colors.white,
            title: Text(item.title, overflow: TextOverflow.ellipsis),
            actions: [
              SegmentedButton<int>(
                style: SegmentedButton.styleFrom(foregroundColor: Colors.white, selectedForegroundColor: Colors.black),
                showSelectedIcon: false,
                segments: const [
                  ButtonSegment(value: 0, icon: Icon(Icons.crop_portrait), tooltip: '한 쪽'),
                  ButtonSegment(value: 1, icon: Icon(Icons.menu_book), tooltip: '두 쪽'),
                  ButtonSegment(value: 2, icon: Icon(Icons.view_day), tooltip: '세로 스크롤'),
                ],
                selected: {s.comicMode},
                onSelectionChanged: (v) {
                  _retirePager();
                  _initialDone = false;
                  s.comicMode = v.first;
                },
              ),
              PopupMenuButton<String>(
                iconColor: Colors.white,
                onSelected: (v) {
                  _retirePager();
                  if (v == 'rtl') s.comicRtl = !s.comicRtl;
                  if (v == 'cover') s.comicCoverAlone = !s.comicCoverAlone;
                },
                itemBuilder: (_) => [
                  CheckedPopupMenuItem(value: 'rtl', checked: s.comicRtl, child: const Text('오른쪽→왼쪽 넘김 (일본식)')),
                  CheckedPopupMenuItem(value: 'cover', checked: s.comicCoverAlone, child: const Text('두 쪽 모드에서 표지 따로')),
                ],
              ),
            ],
          ),
        ),
        Positioned(
          left: 0,
          right: 0,
          bottom: 0,
          child: Container(
            color: Colors.black87,
            child: SafeArea(
              top: false,
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
                child: Row(children: [
                  Expanded(
                    child: Directionality(
                      textDirection: rtl && s.comicMode != 2 ? TextDirection.rtl : TextDirection.ltr,
                      child: Slider(
                        value: _page.toDouble(),
                        min: 0,
                        max: (_files.length - 1).toDouble().clamp(0.0001, double.infinity),
                        onChanged: (v) => setState(() => _page = v.round()),
                        onChangeEnd: (v) => _jump(v.round(), s),
                      ),
                    ),
                  ),
                  Text('${_page + 1} / ${_files.length}', style: const TextStyle(color: Colors.white)),
                ]),
              ),
            ),
          ),
        ),
      ];
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
