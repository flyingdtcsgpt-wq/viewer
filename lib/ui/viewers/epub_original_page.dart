import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:webview_windows/webview_windows.dart';

import '../../app_state.dart';
import '../../models/media_item.dart';
import '../../services/epub_book.dart';
import '../../services/settings.dart';
import 'open_item.dart';
import 'text_reader_page.dart';
import 'viewer_chrome.dart';

/// EPUB "원본 스타일" 보기 — 출판사가 만든 모양(CSS · 글꼴 · 그림 배치) 그대로
/// Windows 에 들어 있는 WebView2 로 보여준다. (WebView2 가 없으면 읽기 최적화 보기로)
class EpubOriginalPage extends StatefulWidget {
  final MediaItem item;
  const EpubOriginalPage({super.key, required this.item});

  @override
  State<EpubOriginalPage> createState() => _EpubOriginalPageState();
}

class _EpubOriginalPageState extends State<EpubOriginalPage> {
  late final AppState _app = context.read<AppState>();
  late final Settings _s = context.read<Settings>();
  final _web = WebviewController();
  EpubBook? _book;
  EpubLocalServer? _server;
  int _port = 0;
  int _chapter = 0;
  double _ratio = 0;
  double _zoom = 1;
  bool _toc = false;
  Object? _error;
  bool _ready = false;

  MediaItem get item => widget.item;
  int get _n => _book?.spine.length ?? 0;
  double get _progress => _n == 0 ? 0 : ((_chapter + _ratio) / _n).clamp(0.0, 1.0);

  @override
  void initState() {
    super.initState();
    _app;
    _open();
  }

  Future<void> _open() async {
    try {
      final version = await WebviewController.getWebViewVersion();
      if (version == null) throw Exception('WebView2 런타임이 없습니다');
      _book = EpubBook.open(item.path);
      _server = EpubLocalServer(_book!);
      _port = await _server!.start();
      // 저장된 위치: "장:비율"
      final saved = (_s.epubPosition(item.id!)).split(':');
      _chapter = (int.tryParse(saved.first) ?? 0).clamp(0, _n - 1);
      _ratio = double.tryParse(saved.length > 1 ? saved[1] : '0') ?? 0;
      await _web.initialize();
      await _web.setBackgroundColor(Colors.white);
      _web.webMessage.listen(_onMessage);
      await _load(_chapter, _ratio);
      if (mounted) setState(() => _ready = true);
    } catch (e) {
      if (!mounted) return;
      // WebView2 가 없거나 깨진 EPUB → 읽기 최적화 보기로 연다
      _error = e;
      Navigator.pushReplacement(context, MaterialPageRoute(builder: (_) => TextReaderPage(item: item)));
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('원본 스타일로 열 수 없어 읽기 최적화로 엽니다 ($e)')));
    }
  }

  Future<void> _load(int chapter, double ratio) async {
    _chapter = chapter.clamp(0, _n - 1);
    _ratio = ratio;
    final path = _book!.spine[_chapter].split('/').map(Uri.encodeComponent).join('/');
    await _web.loadUrl('http://127.0.0.1:$_port/$path?r=$ratio');
    _save();
    if (mounted) setState(() {});
  }

  void _onMessage(dynamic m) {
    try {
      final d = jsonDecode(m is String ? m : '$m') as Map<String, dynamic>;
      if (d['t'] == 'scroll') {
        _ratio = (d['r'] as num).toDouble().clamp(0.0, 1.0);
        _save();
        if (mounted) setState(() {});
      } else if (d['t'] == 'key') {
        // WebView 안에 포커스가 있어도 장 이동은 되게
        if (d['k'] == 'PageDown' && _ratio > 0.98) _next(1);
        if (d['k'] == 'Escape') Navigator.maybePop(context);
      }
    } catch (_) {}
  }

  void _save() {
    _s.setEpubPosition(item.id!, '$_chapter:${_ratio.toStringAsFixed(3)}');
    _app.saveProgress(item, '$_chapter', _progress);
  }

  void _next(int d) {
    final t = _chapter + d;
    if (t < 0 || t >= _n) return;
    _load(t, 0);
  }

  @override
  void dispose() {
    _save();
    _app.refresh();
    _web.dispose();
    _server?.stop();
    _book?.close();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final toc = _book?.toc ?? const <(String, int)>[];
    var curToc = -1;
    for (var i = 0; i < toc.length; i++) {
      if (toc[i].$2 <= _chapter) curToc = i;
    }
    return Scaffold(
      backgroundColor: viewerBg,
      body: SafeArea(
        child: Column(children: [
          Container(
            color: const Color(0xFF141414),
            padding: const EdgeInsets.fromLTRB(8, 6, 8, 6),
            child: Row(children: [
              IconButton(
                style: IconButton.styleFrom(backgroundColor: _toc ? toolActive : toolBg),
                tooltip: '목차',
                icon: const Icon(Icons.toc, color: Colors.white),
                onPressed: () => setState(() => _toc = !_toc),
              ),
              const SizedBox(width: 10),
              Flexible(
                child: Text(item.fileName,
                    overflow: TextOverflow.ellipsis, style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w700, fontSize: 15)),
              ),
              const SizedBox(width: 8),
              Text('${_chapter + 1} / $_n · ${(_progress * 100).round()}%', style: const TextStyle(color: Colors.white60, fontSize: 12)),
              const SizedBox(width: 8),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                decoration: BoxDecoration(color: toolActive.withValues(alpha: 0.3), borderRadius: BorderRadius.circular(4)),
                child: const Text('원본 스타일', style: TextStyle(color: Colors.white, fontSize: 11)),
              ),
              NextVolumeButton(item: item),
              const Spacer(),
              ToolGroup([
                ToolBtn(icon: Icons.chevron_left, tooltip: '이전 장', onTap: _chapter > 0 ? () => _next(-1) : null, enabled: _chapter > 0),
                ToolBtn(icon: Icons.chevron_right, tooltip: '다음 장', onTap: _chapter < _n - 1 ? () => _next(1) : null, enabled: _chapter < _n - 1),
              ]),
              ToolGroup([
                ToolBtn(icon: Icons.zoom_out, tooltip: '작게', onTap: () => _setZoom(_zoom - 0.1)),
                ToolBtn(label: '${(_zoom * 100).round()}%', tooltip: '배율'),
                ToolBtn(icon: Icons.zoom_in, tooltip: '크게', onTap: () => _setZoom(_zoom + 0.1)),
              ]),
              ToolGroup([
                ToolBtn(
                  label: '읽기 최적화',
                  tooltip: '앱 글꼴·테마로 보기 (하이라이트 · TTS)',
                  onTap: () {
                    _s.epubOriginal = false;
                    Navigator.pushReplacement(context, MaterialPageRoute(builder: (_) => TextReaderPage(item: item)));
                  },
                ),
              ]),
              IconButton(tooltip: '닫기', icon: const Icon(Icons.close, color: Colors.white70), onPressed: () => Navigator.maybePop(context)),
            ]),
          ),
          Expanded(
            child: Row(children: [
              if (_toc)
                Container(
                  width: 300,
                  color: const Color(0xFF1C1C1C),
                  child: ListView.builder(
                    itemCount: toc.length,
                    itemBuilder: (_, i) => Material(
                      color: i == curToc ? toolActive.withValues(alpha: 0.3) : Colors.transparent,
                      child: ListTile(
                        dense: true,
                        title: Text(toc[i].$1, style: const TextStyle(color: Colors.white)),
                        onTap: () => _load(toc[i].$2, 0),
                      ),
                    ),
                  ),
                ),
              Expanded(
                child: !_ready
                    ? Center(child: _error == null ? const CircularProgressIndicator() : Text('$_error', style: const TextStyle(color: Colors.white)))
                    : Webview(_web),
              ),
            ]),
          ),
          // 아래 진행 막대
          Container(
            color: const Color(0xFF141414),
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: Row(children: [
              Expanded(
                child: Slider(
                  value: _chapter.toDouble(),
                  min: 0,
                  max: (_n - 1).clamp(1, 1 << 20).toDouble(),
                  divisions: _n > 1 ? _n - 1 : null,
                  label: toc.where((t) => t.$2 <= _chapter).lastOrNull?.$1 ?? '${_chapter + 1}',
                  onChanged: (v) => setState(() => _chapter = v.round()),
                  onChangeEnd: (v) => _load(v.round(), 0),
                ),
              ),
              Text('${(_progress * 100).toStringAsFixed(1)}%', style: const TextStyle(color: Colors.white70)),
            ]),
          ),
        ]),
      ),
    );
  }

  Future<void> _setZoom(double z) async {
    _zoom = z.clamp(0.5, 3.0);
    await _web.setZoomFactor(_zoom);
    setState(() {});
  }
}
