import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:pdfrx/pdfrx.dart';
import 'package:provider/provider.dart';

import '../../app_state.dart';
import '../../models/media_item.dart';
import 'open_item.dart';

class PdfReaderPage extends StatefulWidget {
  final MediaItem item;
  const PdfReaderPage({super.key, required this.item});

  @override
  State<PdfReaderPage> createState() => _PdfReaderPageState();
}

class _PdfReaderPageState extends State<PdfReaderPage> {
  final _ctrl = PdfViewerController();
  late final AppState _app = context.read<AppState>();
  int _page = 1;
  int _pages = 0;

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
    super.dispose();
  }

  void _go(int page) {
    if (_pages == 0) return;
    _ctrl.goToPage(pageNumber: page.clamp(1, _pages));
  }

  @override
  Widget build(BuildContext context) {
    return CallbackShortcuts(
      bindings: {
        const SingleActivator(LogicalKeyboardKey.arrowRight): () => _go(_page + 1),
        const SingleActivator(LogicalKeyboardKey.pageDown): () => _go(_page + 1),
        const SingleActivator(LogicalKeyboardKey.arrowLeft): () => _go(_page - 1),
        const SingleActivator(LogicalKeyboardKey.pageUp): () => _go(_page - 1),
        const SingleActivator(LogicalKeyboardKey.home): () => _go(1),
        const SingleActivator(LogicalKeyboardKey.end): () => _go(_pages),
        const SingleActivator(LogicalKeyboardKey.escape): () => Navigator.maybePop(context),
      },
      child: Focus(
        autofocus: true,
        child: Scaffold(
          appBar: AppBar(
            title: Text(item.title, overflow: TextOverflow.ellipsis),
            actions: [
              IconButton(tooltip: '확대', icon: const Icon(Icons.zoom_in), onPressed: () => _ctrl.zoomUp()),
              IconButton(tooltip: '축소', icon: const Icon(Icons.zoom_out), onPressed: () => _ctrl.zoomDown()),
              NextVolumeButton(item: item),
            ],
          ),
          body: PdfViewer.file(
            item.path,
            controller: _ctrl,
            initialPageNumber: _page,
            params: PdfViewerParams(
              onViewerReady: (doc, ctrl) => setState(() => _pages = doc.pages.length),
              onPageChanged: (p) {
                if (p == null) return;
                setState(() => _page = p);
                _app.saveProgress(item, '$p', _progress);
              },
            ),
          ),
          bottomNavigationBar: _pages == 0
              ? null
              : SafeArea(
                  child: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 16),
                    child: Row(children: [
                      IconButton(icon: const Icon(Icons.chevron_left), onPressed: () => _go(_page - 1)),
                      Expanded(
                        child: Slider(
                          value: _page.clamp(1, _pages).toDouble(),
                          min: 1,
                          max: _pages.toDouble().clamp(1.0001, double.infinity),
                          onChanged: (v) => setState(() => _page = v.round()),
                          onChangeEnd: (v) => _go(v.round()),
                        ),
                      ),
                      IconButton(icon: const Icon(Icons.chevron_right), onPressed: () => _go(_page + 1)),
                      Text('$_page / $_pages'),
                    ]),
                  ),
                ),
        ),
      ),
    );
  }
}
