import 'dart:io';

import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;
import 'package:pdfrx/pdfrx.dart';
import 'package:provider/provider.dart';

import '../../app_state.dart';
import '../../models/media_item.dart';
import '../../services/ext_archive.dart';
import '../../services/file_tools.dart';
import '../../services/image_pdf.dart';
import '../../services/zip_pages.dart';
import '../browser.dart' show fileSize;
import '../cover_tile.dart';
import 'archive_tool_pages.dart' show ToolRunner;

/// 겹치지 않는 새 파일 이름
Future<String> _free(String path) async {
  if (!await File(path).exists()) return path;
  final stem = p.withoutExtension(path), ext = p.extension(path);
  for (var n = 2;; n++) {
    final c = '$stem ($n)$ext';
    if (!await File(c).exists()) return c;
  }
}

String _pct(int before, int after) => before == 0 ? '' : ' (${((1 - after / before) * 100).round()}% 줄임)';

/// 고른 항목 목록 (체크 상자)
Widget _checkList(List<MediaItem> items, Set<MediaItem> checked, bool running, void Function(VoidCallback) set, {String Function(MediaItem)? sub}) =>
    ListView(children: [
      for (final e in items)
        CheckboxListTile(
          value: checked.contains(e),
          onChanged: running ? null : (v) => set(() => v! ? checked.add(e) : checked.remove(e)),
          secondary: SizedBox(width: 36, height: 50, child: CoverImage(item: e)),
          title: Text(e.title, maxLines: 1, overflow: TextOverflow.ellipsis),
          subtitle: Text(sub?.call(e) ?? '${e.fileName} · ${fileSize(e.size)}', maxLines: 1, overflow: TextOverflow.ellipsis),
        ),
    ]);

/// 고르기 칩 줄
Widget _chips<T>(String label, List<(T, String)> options, T value, bool enabled, void Function(T) onPick) => Padding(
      padding: const EdgeInsets.fromLTRB(16, 4, 16, 4),
      child: Row(children: [
        SizedBox(width: 92, child: Text(label, style: const TextStyle(fontWeight: FontWeight.w600))),
        Expanded(
          child: Wrap(spacing: 6, runSpacing: 4, children: [
            for (final (v, l) in options) ChoiceChip(label: Text(l), selected: v == value, onSelected: enabled ? (_) => onPick(v) : null),
          ]),
        ),
      ]),
    );

const _sides = [(1200, '1200px'), (1600, '1600px'), (2000, '2000px'), (2560, '2560px'), (0, '크기 그대로')];
const _qualities = [(70, '70 (작게)'), (82, '82 (권장)'), (90, '90 (선명)')];

// =====================================================================
//  이미지 → PDF
// =====================================================================
class ImageToPdfPage extends StatefulWidget {
  final List<MediaItem> items; // 그림 · 만화 압축 파일
  const ImageToPdfPage({super.key, required this.items});
  @override
  State<ImageToPdfPage> createState() => _ImageToPdfPageState();
}

class _ImageToPdfPageState extends State<ImageToPdfPage> with ToolRunner {
  late final Set<MediaItem> _checked = {...widget.items};
  bool _add = true;
  String _now = '';

  bool _isComic(MediaItem e) => e.kind != MediaKind.image;
  List<MediaItem> get _images => widget.items.where((e) => !_isComic(e) && _checked.contains(e)).toList();
  List<MediaItem> get _comics => widget.items.where((e) => _isComic(e) && _checked.contains(e)).toList();

  Future<void> _go() async {
    final app = context.read<AppState>();
    final made = <String>[];
    setState(() {
      running = true;
      progress = 0;
      log = '';
    });
    final comics = _comics, images = _images..sort((a, b) => a.path.compareTo(b.path));
    final jobs = comics.length + (images.isEmpty ? 0 : 1);
    var job = 0;
    void tick(String what, int d, int n) {
      if (!mounted) return;
      setState(() {
        _now = '$what · $d / $n쪽';
        progress = (job + (n == 0 ? 1 : d / n)) / jobs;
      });
    }

    // 만화 한 권 → PDF 한 개
    for (final e in comics) {
      try {
        final out = await _free(p.setExtension(e.path, '.pdf'));
        int n;
        if (ExtArchive.handles(e.path)) {
          final names = await ExtArchive.listImages(e.path);
          n = await ImagePdf.write(out, names.length, (i) => ExtArchive.readOne(e.path, names[i]),
              title: e.title, onPage: (d, t) => tick(e.fileName, d, t));
        } else {
          final z = await ZipPages.open(e.path);
          try {
            n = await ImagePdf.write(out, z.names.length, z.read, title: e.title, onPage: (d, t) => tick(e.fileName, d, t));
          } finally {
            z.close();
          }
        }
        if (n == 0) {
          await File(out).delete();
          throw '넣을 그림이 없습니다';
        }
        made.add(out);
        log = '${e.fileName} → ${p.basename(out)} ($n쪽, ${fileSize(await File(out).length())})\n$log';
      } catch (err) {
        log = '${e.fileName}: 실패 — $err\n$log';
      }
      job++;
    }
    // 고른 그림들 → PDF 한 개 (이름 순)
    if (images.isNotEmpty) {
      final dir = p.dirname(images.first.path);
      try {
        final out = await _free(p.join(dir, '${p.basename(dir).isEmpty ? '그림 모음' : p.basename(dir)}.pdf'));
        final n = await ImagePdf.write(out, images.length, (i) => File(images[i].path).readAsBytes(),
            title: p.basename(dir), onPage: (d, t) => tick('그림 ${images.length}장', d, t));
        made.add(out);
        log = '그림 ${images.length}장 → ${p.basename(out)} ($n쪽, ${fileSize(await File(out).length())})\n$log';
      } catch (err) {
        log = '그림 → PDF 실패 — $err\n$log';
      }
    }
    if (_add && made.isNotEmpty) await app.importFiles(made);
    if (!mounted) return;
    setState(() {
      running = false;
      progress = 1;
      _now = '';
    });
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('완료: PDF ${made.length}개')));
  }

  @override
  Widget build(BuildContext context) {
    final comics = _comics.length, images = _images.length;
    final what = [if (comics > 0) '만화 $comics권', if (images > 0) '그림 $images장 → 1개'].join(' · ');
    return Scaffold(
      appBar: AppBar(title: const Text('이미지 → PDF')),
      body: Column(children: [
        const Padding(
          padding: EdgeInsets.all(16),
          child: Text('만화 압축 파일은 한 권마다 PDF 하나로, 고른 그림 파일들은 이름 순서대로 PDF 하나로 묶습니다. '
              'JPEG 그림은 다시 압축하지 않아 화질이 그대로입니다. 원본은 그대로 둡니다.'),
        ),
        SwitchListTile(
          title: const Text('만든 PDF 를 라이브러리에 추가'),
          value: _add,
          onChanged: running ? null : (v) => setState(() => _add = v),
        ),
        const Divider(),
        Expanded(child: _checkList(widget.items, _checked, running, setState)),
        if (_now.isNotEmpty) Padding(padding: const EdgeInsets.symmetric(horizontal: 16), child: Text(_now, style: const TextStyle(fontSize: 12))),
        bottomBar(
          what.isEmpty ? 'PDF 만들기' : 'PDF 만들기 ($what)',
          comics + images == 0 ? null : _go,
          showBackup: false,
        ),
      ]),
    );
  }
}

// =====================================================================
//  이미지 해상도 변경 (만화 압축 파일 · 그림 파일)
// =====================================================================
class ImageResizePage extends StatefulWidget {
  final List<MediaItem> items;
  const ImageResizePage({super.key, required this.items});
  @override
  State<ImageResizePage> createState() => _ImageResizePageState();
}

class _ImageResizePageState extends State<ImageResizePage> with ToolRunner {
  late final Set<MediaItem> _checked = {...widget.items};
  int _side = 1600, _quality = 82;
  bool _toJpeg = true;
  String _now = '';

  @override
  Widget build(BuildContext context) => Scaffold(
        appBar: AppBar(title: const Text('이미지 해상도 변경')),
        body: Column(children: [
          const Padding(
            padding: EdgeInsets.fromLTRB(16, 16, 16, 8),
            child: Text('큰 그림을 줄여 용량을 아낍니다 (휴대폰 · 태블릿에 넣을 때 좋음). 만화 압축 파일은 안의 그림을 모두, 그림 파일은 그 파일을 줄입니다. '
                '더 작아지지 않는 그림은 그대로 둡니다.'),
          ),
          _chips('긴 변 최대', _sides, _side, !running, (v) => setState(() => _side = v)),
          _chips('JPEG 품질', _qualities, _quality, !running, (v) => setState(() => _quality = v)),
          SwitchListTile(
            title: const Text('만화 속 PNG · BMP · GIF 도 JPEG 로'),
            subtitle: const Text('크게 줄어듭니다. 그림 파일 자체는 형식을 바꾸지 않습니다'),
            value: _toJpeg,
            onChanged: running ? null : (v) => setState(() => _toJpeg = v),
          ),
          const Divider(),
          Expanded(child: _checkList(widget.items, _checked, running, setState)),
          if (_now.isNotEmpty) Padding(padding: const EdgeInsets.symmetric(horizontal: 16), child: Text(_now, style: const TextStyle(fontSize: 12))),
          bottomBar('줄이기 (${_checked.length}개)', _checked.isEmpty ? null : () {
            final o = ShrinkOptions(maxSide: _side, quality: _quality, toJpeg: _toJpeg);
            runAll(_checked.toList(), (e) async {
              final r = e.kind == MediaKind.image
                  ? await FileTools.shrinkImageFile(e.path, o, backup: backup)
                  : await FileTools.shrinkZip(e.path, o, backup: backup, onProgress: (d, n) {
                      if (mounted) setState(() => _now = '${e.fileName} · $d / $n');
                    });
              if (r.changed == 0) return '바꿀 그림 없음 (이미 작음)';
              return '그림 ${r.changed}/${r.images}개 줄임, ${fileSize(r.before)} → ${fileSize(r.after)}${_pct(r.before, r.after)}';
            }).then((_) {
              if (mounted) setState(() => _now = '');
            });
          }),
        ]),
      );
}

// =====================================================================
//  EPUB 용량 최적화
// =====================================================================
class EpubOptimizePage extends StatefulWidget {
  final List<MediaItem> items;
  const EpubOptimizePage({super.key, required this.items});
  @override
  State<EpubOptimizePage> createState() => _EpubOptimizePageState();
}

class _EpubOptimizePageState extends State<EpubOptimizePage> with ToolRunner {
  late final Set<MediaItem> _checked = {...widget.items};
  int _side = 1600, _quality = 82;
  String _now = '';

  @override
  Widget build(BuildContext context) => Scaffold(
        appBar: AppBar(title: const Text('EPUB 용량 최적화')),
        body: Column(children: [
          const Padding(
            padding: EdgeInsets.fromLTRB(16, 16, 16, 8),
            child: Text('EPUB 안의 큰 그림(표지 · 삽화)을 줄이고, 글과 스타일은 가장 세게 다시 압축합니다. '
                '그림 이름은 그대로라 본문은 바뀌지 않습니다. 더 작아지지 않으면 원본을 그대로 둡니다.'),
          ),
          _chips('긴 변 최대', _sides, _side, !running, (v) => setState(() => _side = v)),
          _chips('JPEG 품질', _qualities, _quality, !running, (v) => setState(() => _quality = v)),
          const Divider(),
          Expanded(child: _checkList(widget.items, _checked, running, setState)),
          if (_now.isNotEmpty) Padding(padding: const EdgeInsets.symmetric(horizontal: 16), child: Text(_now, style: const TextStyle(fontSize: 12))),
          bottomBar('최적화 (${_checked.length}개)', _checked.isEmpty ? null : () {
            final o = ShrinkOptions(maxSide: _side, quality: _quality);
            runAll(_checked.toList(), (e) async {
              final r = await FileTools.optimizeEpub(e.path, o, backup: backup, onProgress: (d, n) {
                if (mounted) setState(() => _now = '${e.fileName} · $d / $n');
              });
              if (r.after >= r.before) return '더 줄일 것이 없음';
              return '그림 ${r.changed}/${r.images}개 줄임, ${fileSize(r.before)} → ${fileSize(r.after)}${_pct(r.before, r.after)}';
            }).then((_) {
              if (mounted) setState(() => _now = '');
            });
          }),
        ]),
      );
}

// =====================================================================
//  PDF 나누기 · 합치기
// =====================================================================
class PdfSplitMergePage extends StatefulWidget {
  final List<MediaItem> items;
  const PdfSplitMergePage({super.key, required this.items});
  @override
  State<PdfSplitMergePage> createState() => _PdfSplitMergePageState();
}

class _PdfSplitMergePageState extends State<PdfSplitMergePage> with ToolRunner {
  late final List<MediaItem> _order = [...widget.items];
  late final Set<MediaItem> _checked = {...widget.items};
  late int _mode = widget.items.length > 1 ? 0 : 1; // 0 합치기, 1 나누기
  int _splitHow = 0; // 0 N쪽마다, 1 범위
  final _every = TextEditingController(text: '10');
  final _ranges = TextEditingController(text: '1-10, 11-');
  late final _name = TextEditingController(text: widget.items.isEmpty ? '합본' : '${widget.items.first.title} 합본');
  bool _add = true;

  @override
  void dispose() {
    _every.dispose();
    _ranges.dispose();
    _name.dispose();
    super.dispose();
  }

  Future<void> _merge() async {
    final app = context.read<AppState>();
    final list = _order.where(_checked.contains).toList();
    if (list.length < 2) return;
    setState(() {
      running = true;
      progress = 0;
      log = '';
    });
    try {
      final base = _name.text.trim().replaceAll(RegExp(r'[\\/:*?"<>|]'), ' ').trim();
      final out = await _free(p.join(p.dirname(list.first.path), '${base.isEmpty ? '합본' : base}.pdf'));
      final n = await FileTools.mergePdf([for (final e in list) e.path], out);
      log = '${list.length}개 → ${p.basename(out)} ($n쪽, ${fileSize(await File(out).length())})';
      if (_add) await app.importFiles([out]);
    } catch (err) {
      log = '합치기 실패 — $err';
    }
    if (!mounted) return;
    setState(() {
      running = false;
      progress = 1;
    });
  }

  Future<void> _split() async {
    final app = context.read<AppState>();
    final list = _order.where(_checked.contains).toList();
    final made = <String>[];
    setState(() {
      running = true;
      progress = 0;
      log = '';
    });
    for (var i = 0; i < list.length; i++) {
      final e = list[i];
      try {
        final doc = await PdfDocument.openFile(e.path);
        final pages = doc.pages.length;
        doc.dispose();
        final groups = _splitHow == 0
            ? FileTools.everyN((int.tryParse(_every.text.trim()) ?? 0).clamp(1, 100000), pages)
            : FileTools.parseRanges(_ranges.text, pages);
        if (groups == null) throw '쪽 범위를 알아볼 수 없습니다 (이 파일은 $pages쪽)';
        final out = await FileTools.splitPdf(e.path, groups, onProgress: (d, n) {
          if (mounted) setState(() => progress = (i + d / n) / list.length);
        });
        made.addAll(out);
        log = '${e.fileName} → ${out.length}개 (${out.map(p.basename).take(3).join(', ')}${out.length > 3 ? ' …' : ''})\n$log';
      } catch (err) {
        log = '${e.fileName}: 실패 — $err\n$log';
      }
    }
    if (_add && made.isNotEmpty) await app.importFiles(made);
    if (!mounted) return;
    setState(() {
      running = false;
      progress = 1;
    });
  }

  @override
  Widget build(BuildContext context) {
    final count = _order.where(_checked.contains).length;
    return Scaffold(
      appBar: AppBar(title: const Text('PDF 나누기 · 합치기')),
      body: Column(children: [
        _chips('하는 일', [(0, '합치기 (차례대로 한 파일로)'), (1, '나누기')], _mode, !running, (v) => setState(() => _mode = v)),
        if (_mode == 0)
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 4, 16, 4),
            child: TextField(controller: _name, enabled: !running, decoration: const InputDecoration(labelText: '새 파일 이름', suffixText: '.pdf')),
          )
        else ...[
          _chips('나누는 방법', [(0, 'N쪽마다'), (1, '쪽 범위')], _splitHow, !running, (v) => setState(() => _splitHow = v)),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 4),
            child: _splitHow == 0
                ? TextField(
                    controller: _every,
                    enabled: !running,
                    keyboardType: TextInputType.number,
                    decoration: const InputDecoration(labelText: '몇 쪽마다', suffixText: '쪽'),
                  )
                : TextField(
                    controller: _ranges,
                    enabled: !running,
                    decoration: const InputDecoration(labelText: '쪽 범위', helperText: '예: 1-10, 11-20, 21-  (쉼표로 나눈 묶음마다 파일 하나)'),
                  ),
          ),
        ],
        SwitchListTile(title: const Text('만든 PDF 를 라이브러리에 추가'), value: _add, onChanged: running ? null : (v) => setState(() => _add = v)),
        const Divider(),
        Expanded(
          child: _mode == 0
              ? ReorderableListView(
                  buildDefaultDragHandles: !running,
                  onReorderItem: (a, b) => setState(() => _order.insert(b, _order.removeAt(a))),
                  children: [
                    for (final e in _order)
                      CheckboxListTile(
                        key: ValueKey(e.path),
                        value: _checked.contains(e),
                        onChanged: running ? null : (v) => setState(() => v! ? _checked.add(e) : _checked.remove(e)),
                        title: Text(e.title, maxLines: 1, overflow: TextOverflow.ellipsis),
                        subtitle: Text('${e.fileName}${e.pages == null ? '' : ' · ${e.pages}쪽'} · 끌어서 순서 바꾸기'),
                      ),
                  ],
                )
              : _checkList(_order, _checked, running, setState, sub: (e) => '${e.fileName}${e.pages == null ? '' : ' · ${e.pages}쪽'}'),
        ),
        bottomBar(
          _mode == 0 ? '합치기 ($count개)' : '나누기 ($count개)',
          _mode == 0 ? (count < 2 ? null : _merge) : (count == 0 ? null : _split),
          showBackup: false,
          extra: const [Text('  (원본은 바뀌지 않음)')],
        ),
      ]),
    );
  }
}
