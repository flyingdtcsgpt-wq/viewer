import 'dart:io';
import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:provider/provider.dart';

import '../../app_state.dart';
import '../../models/media_item.dart';
import '../../services/archive_tools.dart';
import '../../services/epub_writer.dart';
import '../../services/ocr_service.dart';
import '../../services/pdf_text.dart';
import '../browser.dart' show fileSize;
import '../cover_tile.dart';
import '../metadata_search_dialog.dart';
import 'image_editor.dart';

/// 도구 공통: 대상 표 + 실행 버튼 + 진행 표시
mixin ToolRunner<T extends StatefulWidget> on State<T> {
  bool running = false;
  double progress = 0;
  String log = '';
  bool backup = true;

  Future<void> runAll(List<MediaItem> items, Future<String> Function(MediaItem) work) async {
    final app = context.read<AppState>();
    setState(() {
      running = true;
      progress = 0;
      log = '';
    });
    var ok = 0, fail = 0;
    for (var i = 0; i < items.length; i++) {
      final e = items[i];
      try {
        final msg = await work(e);
        await app.refreshFile(e);
        ok++;
        log = '${e.fileName}: $msg\n$log';
      } catch (err) {
        fail++;
        log = '${e.fileName}: 실패 — $err\n$log';
      }
      if (mounted) setState(() => progress = (i + 1) / items.length);
    }
    if (!mounted) return;
    setState(() => running = false);
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('완료: 성공 $ok · 실패 $fail${backup ? ' (원본은 .bak 으로 남겼습니다)' : ''}')));
  }

  Widget bottomBar(String label, VoidCallback? onRun, {List<Widget> extra = const [], bool showBackup = true}) => Container(
        padding: const EdgeInsets.fromLTRB(16, 10, 16, 14),
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          if (running) LinearProgressIndicator(value: progress),
          if (log.isNotEmpty)
            Container(
              height: 90,
              width: double.infinity,
              margin: const EdgeInsets.only(top: 8),
              padding: const EdgeInsets.all(8),
              decoration: BoxDecoration(color: Colors.black26, borderRadius: BorderRadius.circular(6)),
              child: SingleChildScrollView(child: SelectableText(log, style: const TextStyle(fontSize: 12, fontFamily: 'monospace'))),
            ),
          const SizedBox(height: 8),
          Row(children: [
            if (showBackup) ...[
              Checkbox(value: backup, onChanged: running ? null : (v) => setState(() => backup = v ?? true)),
              const Text('원본 파일 백업 (.bak)'),
            ],
            ...extra,
            const Spacer(),
            FilledButton.icon(
              style: FilledButton.styleFrom(padding: const EdgeInsets.symmetric(horizontal: 28, vertical: 18)),
              onPressed: running ? null : onRun,
              icon: const Icon(Icons.rocket_launch),
              label: Text(label),
            ),
          ]),
        ]),
      );
}

// =====================================================================
//  압축 파일 구조 정리 (평탄화)
// =====================================================================
class FlattenToolPage extends StatefulWidget {
  final List<MediaItem> items;
  const FlattenToolPage({super.key, required this.items});
  @override
  State<FlattenToolPage> createState() => _FlattenToolPageState();
}

class _FlattenToolPageState extends State<FlattenToolPage> with ToolRunner {
  final _entries = <String, List<ZipEntry>>{};
  late final Set<MediaItem> _checked = {...widget.items};
  NamePattern _pattern = NamePattern.keep;

  @override
  void initState() {
    super.initState();
    _analyze();
  }

  Future<void> _analyze() async {
    for (final e in widget.items) {
      try {
        _entries[e.path] = await ArchiveTools.list(e.path);
      } catch (_) {
        _entries[e.path] = const [];
      }
      if (mounted) setState(() {});
    }
  }

  /// (이미지 수, 정리할 파일 수, 폴더 깊이)
  (int, int, int) _stat(String path) {
    final l = _entries[path];
    if (l == null) return (-1, 0, 0);
    final images = l.where((e) => e.isImage && !ArchiveTools.isJunk(e.name)).length;
    final extra = l.length - images;
    final depth = l.fold<int>(0, (a, e) => e.depth > a ? e.depth : a);
    return (images, extra, depth);
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: AppBar(title: const Text('압축 파일 구조 정리 (평탄화)')),
      body: Column(children: [
        Padding(
          padding: const EdgeInsets.all(16),
          child: Row(children: [
            const Expanded(child: Text('압축 파일 안의 폴더를 없애고 이미지만 순서대로 남깁니다. __MACOSX, Thumbs.db 같은 쓰레기 파일도 지웁니다.')),
            const Text('파일 이름: '),
            DropdownButton<NamePattern>(
              value: _pattern,
              onChanged: (v) => setState(() => _pattern = v!),
              items: [for (final n in NamePattern.values) DropdownMenuItem(value: n, child: Text(patternLabel(n)))],
            ),
          ]),
        ),
        Container(
          color: scheme.surfaceContainer,
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
          child: const Row(children: [
            SizedBox(width: 48),
            Expanded(flex: 5, child: Text('파일명', style: TextStyle(fontWeight: FontWeight.w700))),
            Expanded(child: Text('이미지', style: TextStyle(fontWeight: FontWeight.w700))),
            Expanded(child: Text('정리할 파일', style: TextStyle(fontWeight: FontWeight.w700))),
            Expanded(child: Text('폴더 깊이', style: TextStyle(fontWeight: FontWeight.w700))),
            Expanded(child: Text('용량', style: TextStyle(fontWeight: FontWeight.w700))),
            Expanded(child: Text('상태', style: TextStyle(fontWeight: FontWeight.w700))),
          ]),
        ),
        Expanded(
          child: ListView.builder(
            itemCount: widget.items.length,
            itemBuilder: (_, i) {
              final e = widget.items[i];
              final (img, extra, depth) = _stat(e.path);
              final needs = img >= 0 && (extra > 0 || depth > 0 || _pattern != NamePattern.keep);
              return Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16),
                child: Row(children: [
                  SizedBox(
                    width: 48,
                    child: Checkbox(value: _checked.contains(e), onChanged: (v) => setState(() => v! ? _checked.add(e) : _checked.remove(e))),
                  ),
                  Expanded(flex: 5, child: Text(e.fileName, overflow: TextOverflow.ellipsis)),
                  Expanded(child: Text(img < 0 ? '…' : '$img')),
                  Expanded(child: Text('$extra', style: TextStyle(color: extra > 0 ? Colors.orange : null))),
                  Expanded(child: Text('$depth', style: TextStyle(color: depth > 0 ? Colors.orange : null))),
                  Expanded(child: Text(fileSize(e.size))),
                  Expanded(child: Text(img < 0 ? '분석 중' : (needs ? '정리 필요' : '깔끔함'), style: TextStyle(color: needs ? Colors.orange : Colors.green))),
                ]),
              );
            },
          ),
        ),
        Text('총 ${widget.items.length}개 / 체크 ${_checked.length}개', style: Theme.of(context).textTheme.bodySmall),
        bottomBar('정리 실행', () {
          final todo = widget.items.where((e) {
            final (img, extra, depth) = _stat(e.path);
            return _checked.contains(e) && img > 0 && (extra > 0 || depth > 0 || _pattern != NamePattern.keep);
          }).toList();
          runAll(todo, (e) async {
            final plan = ArchiveTools.flattenPlan(_entries[e.path]!, pattern: _pattern);
            await ArchiveTools.rewrite(e.path, plan, backup: backup);
            _entries[e.path] = await ArchiveTools.list(e.path);
            return '이미지 ${plan.length}장으로 정리';
          });
        }),
      ]),
    );
  }
}

// =====================================================================
//  내부 파일명 변경 (번호 붙이기 · 순서 바꾸기 · 빼기)
// =====================================================================
class RenameToolPage extends StatefulWidget {
  final List<MediaItem> items;
  const RenameToolPage({super.key, required this.items});
  @override
  State<RenameToolPage> createState() => _RenameToolPageState();
}

class _RenameToolPageState extends State<RenameToolPage> with ToolRunner {
  NamePattern _pattern = NamePattern.pad3;
  int _start = 0;
  late final Set<MediaItem> _checked = {...widget.items};
  late MediaItem _cur = widget.items.first;
  final _orders = <String, List<ZipEntry>>{}; // 사용자가 바꾼 순서
  final _deleted = <String, Set<String>>{};
  Uint8List? _preview;

  @override
  void initState() {
    super.initState();
    _select(_cur);
  }

  Future<void> _select(MediaItem e) async {
    setState(() {
      _cur = e;
      _preview = null;
    });
    _orders[e.path] ??= (await ArchiveTools.list(e.path)).where((x) => !ArchiveTools.isJunk(x.name)).toList();
    final first = _orders[e.path]!.where((x) => x.isImage).firstOrNull;
    if (first != null) _preview = await ArchiveTools.readEntry(e.path, first.name);
    if (mounted) setState(() {});
  }

  List<ZipPlan> _plan(String path, List<ZipEntry> order) {
    final del = _deleted[path] ?? const {};
    final out = <ZipPlan>[];
    var i = _start;
    for (final e in order) {
      if (del.contains(e.name)) continue;
      out.add(ZipPlan(e.name, e.isImage ? ArchiveTools.newName(_pattern, i++, e.name) : e.name));
    }
    return out;
  }

  void _move(int from, int to) {
    final l = _orders[_cur.path]!;
    if (to < 0 || to >= l.length) return;
    setState(() => l.insert(to, l.removeAt(from)));
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final order = _orders[_cur.path];
    final del = _deleted.putIfAbsent(_cur.path, () => {});
    final preview = order == null ? const <ZipPlan>[] : _plan(_cur.path, order);
    final newNames = {for (final pl in preview) pl.src: pl.dst};

    return Scaffold(
      appBar: AppBar(title: const Text('내부 파일명 변경')),
      body: Column(children: [
        Padding(
          padding: const EdgeInsets.all(16),
          child: Row(children: [
            const Text('파일명 패턴: '),
            DropdownButton<NamePattern>(
              value: _pattern,
              onChanged: (v) => setState(() => _pattern = v!),
              items: [for (final n in NamePattern.values) DropdownMenuItem(value: n, child: Text(patternLabel(n)))],
            ),
            const SizedBox(width: 24),
            const Text('시작 번호: '),
            IconButton(onPressed: _start > 0 ? () => setState(() => _start--) : null, icon: const Icon(Icons.remove)),
            Text('$_start', style: const TextStyle(fontWeight: FontWeight.w700)),
            IconButton(onPressed: () => setState(() => _start++), icon: const Icon(Icons.add)),
          ]),
        ),
        Expanded(
          child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
            // 왼쪽: 표지 미리보기
            SizedBox(
              width: 260,
              child: Column(children: [
                const Text('내부 첫 이미지', style: TextStyle(fontWeight: FontWeight.w700)),
                const SizedBox(height: 8),
                Expanded(
                  child: _preview == null
                      ? const Center(child: CircularProgressIndicator())
                      : Image.memory(_preview!, fit: BoxFit.contain),
                ),
              ]),
            ),
            const VerticalDivider(),
            Expanded(
              child: Column(children: [
                // 대상 압축 파일
                SizedBox(
                  height: 220,
                  child: ListView(children: [
                    for (final e in widget.items)
                      Material(
                        color: e == _cur ? scheme.primary.withValues(alpha: 0.3) : Colors.transparent,
                        child: ListTile(
                          dense: true,
                          leading: Checkbox(value: _checked.contains(e), onChanged: (v) => setState(() => v! ? _checked.add(e) : _checked.remove(e))),
                          title: Text(e.fileName),
                          trailing: Text('${e.pages ?? '?'}p · ${fileSize(e.size)}'),
                          onTap: () => _select(e),
                        ),
                      ),
                  ]),
                ),
                const Divider(),
                Text('내부 파일 (실시간 미리보기) · ${_cur.fileName}', style: const TextStyle(fontWeight: FontWeight.w700)),
                Container(
                  color: scheme.surfaceContainer,
                  padding: const EdgeInsets.symmetric(vertical: 6, horizontal: 8),
                  child: const Row(children: [
                    SizedBox(width: 50, child: Text('빼기')),
                    Expanded(flex: 4, child: Text('이전 파일 이름')),
                    Expanded(flex: 3, child: Text('새 파일 이름')),
                    SizedBox(width: 80, child: Text('용량')),
                    SizedBox(width: 160, child: Text('순서 변경')),
                  ]),
                ),
                Expanded(
                  child: order == null
                      ? const Center(child: CircularProgressIndicator())
                      : ListView.builder(
                          itemCount: order.length,
                          itemBuilder: (_, i) {
                            final z = order[i];
                            final gone = del.contains(z.name);
                            return Padding(
                              padding: const EdgeInsets.symmetric(horizontal: 8),
                              child: Row(children: [
                                SizedBox(
                                  width: 50,
                                  child: Checkbox(value: gone, onChanged: (v) => setState(() => v! ? del.add(z.name) : del.remove(z.name))),
                                ),
                                Expanded(
                                  flex: 4,
                                  child: Text(z.name,
                                      overflow: TextOverflow.ellipsis,
                                      style: TextStyle(decoration: gone ? TextDecoration.lineThrough : null, color: z.isImage ? null : Colors.grey)),
                                ),
                                Expanded(flex: 3, child: Text(gone ? '(삭제)' : (newNames[z.name] ?? ''), style: const TextStyle(color: Color(0xFF4FA3FF)))),
                                SizedBox(width: 80, child: Text(fileSize(z.size))),
                                SizedBox(
                                  width: 160,
                                  child: Row(children: [
                                    IconButton(visualDensity: VisualDensity.compact, icon: const Icon(Icons.keyboard_double_arrow_up), onPressed: () => _move(i, 0)),
                                    IconButton(visualDensity: VisualDensity.compact, icon: const Icon(Icons.keyboard_arrow_up), onPressed: () => _move(i, i - 1)),
                                    IconButton(visualDensity: VisualDensity.compact, icon: const Icon(Icons.keyboard_arrow_down), onPressed: () => _move(i, i + 1)),
                                    IconButton(
                                        visualDensity: VisualDensity.compact,
                                        icon: const Icon(Icons.keyboard_double_arrow_down),
                                        onPressed: () => _move(i, order.length - 1)),
                                  ]),
                                ),
                              ]),
                            );
                          },
                        ),
                ),
              ]),
            ),
          ]),
        ),
        bottomBar('이름 변경 실행 (${_checked.length}개)', () {
          runAll(_checked.toList(), (e) async {
            final order = _orders[e.path] ?? (await ArchiveTools.list(e.path)).where((x) => !ArchiveTools.isJunk(x.name)).toList();
            final plan = _plan(e.path, order);
            await ArchiveTools.rewrite(e.path, plan, backup: backup);
            _orders.remove(e.path);
            return '${plan.where((x) => x.src != x.dst).length}개 이름 변경';
          }).then((_) => _select(_cur));
        }),
      ]),
    );
  }
}

// =====================================================================
//  표지 추가 및 교체
// =====================================================================
class CoverToolPage extends StatefulWidget {
  final List<MediaItem> items;
  const CoverToolPage({super.key, required this.items});
  @override
  State<CoverToolPage> createState() => _CoverToolPageState();
}

class _CoverToolPageState extends State<CoverToolPage> with ToolRunner {
  late final Set<MediaItem> _checked = {...widget.items};
  late MediaItem _cur = widget.items.first;
  Uint8List? _newCover;
  String _newExt = '.jpg';
  bool _replace = false; // false = 첫 페이지에 추가, true = 기존 표지 교체
  bool _renumber = true;
  int _tab = 0;
  List<ZipEntry> _inner = [];
  final _thumbs = <String, Uint8List>{};

  @override
  void initState() {
    super.initState();
    _loadInner();
  }

  Future<void> _loadInner() async {
    _inner = (await ArchiveTools.list(_cur.path)).where((e) => e.isImage && !ArchiveTools.isJunk(e.name)).toList();
    if (mounted) setState(() {});
    for (final z in _inner.take(24)) {
      final b = await ArchiveTools.readEntry(_cur.path, z.name);
      if (b != null && mounted) setState(() => _thumbs[z.name] = b);
    }
  }

  Future<void> _fromFile() async {
    final f = await FilePicker.pickFile(type: FileType.image);
    if (f?.path == null) return;
    final b = await File(f!.path!).readAsBytes();
    setState(() {
      _newCover = b;
      _newExt = p.extension(f.path!).toLowerCase();
    });
  }

  Future<void> _fromSearch() async {
    final pick = await showMetadataSearch(context, context.read<AppState>().seriesById(_cur.seriesId)?.title ?? _cur.title, title: '표지 검색');
    final url = pick?.meta.coverUrl;
    if (url == null) return;
    final res = await http.get(Uri.parse(url));
    if (res.statusCode == 200 && mounted) {
      setState(() {
        _newCover = res.bodyBytes;
        _newExt = '.jpg';
      });
    }
  }

  List<ZipPlan> _plan(List<ZipEntry> all) {
    final images = all.where((e) => e.isImage && !ArchiveTools.isJunk(e.name)).toList();
    final others = all.where((e) => !e.isImage && !ArchiveTools.isJunk(e.name)).toList();
    final out = <ZipPlan>[];
    var i = 0;
    String name(String orig) => _renumber ? ArchiveTools.newName(NamePattern.pad3, i++, orig) : p.posix.basename(orig);
    if (_replace) {
      for (var k = 0; k < images.length; k++) {
        if (k == 0) {
          final n = name('cover$_newExt');
          out.add(ZipPlan(null, _renumber ? n : '${p.posix.basenameWithoutExtension(images[0].name)}$_newExt', data: _newCover));
        } else {
          out.add(ZipPlan(images[k].name, name(images[k].name)));
        }
      }
    } else {
      out.add(ZipPlan(null, _renumber ? name('cover$_newExt') : '000_cover$_newExt', data: _newCover));
      for (final z in images) {
        out.add(ZipPlan(z.name, name(z.name)));
      }
    }
    out.addAll(others.map((z) => ZipPlan(z.name, z.name)));
    return out;
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: AppBar(title: const Text('표지 추가 및 교체')),
      body: Column(children: [
        Expanded(
          child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
            // 왼쪽: 기존 표지 / 새 표지
            SizedBox(
              width: 280,
              child: Padding(
                padding: const EdgeInsets.all(12),
                child: Column(children: [
                  Text('기존 표지  ${_cur.fileName}', maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontWeight: FontWeight.w700)),
                  const SizedBox(height: 6),
                  Expanded(child: CoverImage(item: _cur, fit: BoxFit.contain)),
                  const Divider(height: 24),
                  const Text('새 표지', style: TextStyle(fontWeight: FontWeight.w700)),
                  const SizedBox(height: 6),
                  Expanded(
                    child: _newCover == null
                        ? Container(
                            decoration: BoxDecoration(color: scheme.surfaceContainer, borderRadius: BorderRadius.circular(8)),
                            child: const Center(child: Icon(Icons.menu_book, size: 64, color: Colors.grey)),
                          )
                        : Image.memory(_newCover!, fit: BoxFit.contain),
                  ),
                  if (_newCover != null)
                    TextButton.icon(
                      onPressed: () async {
                        final out = await showImageEditor(context, _newCover!);
                        if (out != null) {
                          setState(() {
                            _newCover = out;
                            _newExt = '.jpg';
                          });
                        }
                      },
                      icon: const Icon(Icons.crop),
                      label: const Text('이미지 편집 (자르기 · 회전)'),
                    ),
                ]),
              ),
            ),
            const VerticalDivider(),
            Expanded(
              child: Column(children: [
                // 옵션
                Padding(
                  padding: const EdgeInsets.all(12),
                  child: Wrap(spacing: 12, runSpacing: 8, crossAxisAlignment: WrapCrossAlignment.center, children: [
                    SegmentedButton<bool>(
                      segments: const [
                        ButtonSegment(value: false, label: Text('첫 페이지에 표지 추가')),
                        ButtonSegment(value: true, label: Text('기존 표지 교체')),
                      ],
                      selected: {_replace},
                      onSelectionChanged: (v) => setState(() => _replace = v.first),
                    ),
                    FilterChip(label: const Text('페이지 파일명 연속 번호로 변경'), selected: _renumber, onSelected: (v) => setState(() => _renumber = v)),
                  ]),
                ),
                // 대상 목록
                SizedBox(
                  height: 200,
                  child: ListView(children: [
                    for (final e in widget.items)
                      Material(
                        color: e == _cur ? scheme.primary.withValues(alpha: 0.3) : Colors.transparent,
                        child: ListTile(
                          dense: true,
                          leading: Checkbox(value: _checked.contains(e), onChanged: (v) => setState(() => v! ? _checked.add(e) : _checked.remove(e))),
                          title: Text(e.fileName),
                          trailing: Text('${e.pages ?? '?'}p · ${fileSize(e.size)}'),
                          onTap: () {
                            setState(() {
                              _cur = e;
                              _thumbs.clear();
                            });
                            _loadInner();
                          },
                        ),
                      ),
                  ]),
                ),
                const Divider(),
                // 새 표지 고르는 곳
                Row(children: [
                  for (final (i, l) in const [(0, '이미지 파일'), (1, '표지 검색'), (2, '책 내부 이미지')])
                    Padding(
                      padding: const EdgeInsets.only(left: 12),
                      child: ChoiceChip(label: Text(l), selected: _tab == i, onSelected: (_) => setState(() => _tab = i)),
                    ),
                ]),
                Expanded(
                  child: switch (_tab) {
                    0 => Center(child: FilledButton.icon(onPressed: _fromFile, icon: const Icon(Icons.folder_open), label: const Text('이미지 파일 고르기'))),
                    1 => Center(child: FilledButton.icon(onPressed: _fromSearch, icon: const Icon(Icons.travel_explore), label: const Text('인터넷에서 표지 검색'))),
                    _ => GridView.builder(
                        padding: const EdgeInsets.all(12),
                        gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(maxCrossAxisExtent: 130, childAspectRatio: 0.7, mainAxisSpacing: 8, crossAxisSpacing: 8),
                        itemCount: _inner.take(24).length,
                        itemBuilder: (_, i) {
                          final z = _inner[i];
                          final b = _thumbs[z.name];
                          return InkWell(
                            onTap: b == null
                                ? null
                                : () => setState(() {
                                      _newCover = b;
                                      _newExt = p.extension(z.name).toLowerCase();
                                    }),
                            child: Column(children: [
                              Expanded(child: b == null ? const Center(child: CircularProgressIndicator()) : Image.memory(b, fit: BoxFit.cover, cacheWidth: 200)),
                              Text(z.base, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 11)),
                            ]),
                          );
                        },
                      ),
                  },
                ),
              ]),
            ),
          ]),
        ),
        bottomBar('${_checked.length}개 파일에 표지 저장', _newCover == null
            ? null
            : () => runAll(_checked.toList(), (e) async {
                  final all = await ArchiveTools.list(e.path);
                  await ArchiveTools.rewrite(e.path, _plan(all), backup: backup);
                  return _replace ? '표지 교체' : '표지 추가';
                })),
      ]),
    );
  }
}

// =====================================================================
//  텍본 정리기 (TXT): UTF-8 변환 · 공백 · 빈 줄
// =====================================================================
class TxtCleanPage extends StatefulWidget {
  final List<MediaItem> items;
  const TxtCleanPage({super.key, required this.items});
  @override
  State<TxtCleanPage> createState() => _TxtCleanPageState();
}

class _TxtCleanPageState extends State<TxtCleanPage> with ToolRunner {
  late final Set<MediaItem> _checked = {...widget.items};
  bool _collapse = true;

  @override
  Widget build(BuildContext context) => Scaffold(
        appBar: AppBar(title: const Text('텍본 정리기')),
        body: Column(children: [
          const Padding(
            padding: EdgeInsets.all(16),
            child: Text('CP949(EUC-KR) 등으로 된 TXT 를 UTF-8 로 바꾸고, 줄 끝 공백을 지우고, 줄바꿈을 통일합니다.'),
          ),
          SwitchListTile(title: const Text('빈 줄이 3개 넘게 이어지면 2개로 줄이기'), value: _collapse, onChanged: (v) => setState(() => _collapse = v)),
          const Divider(),
          Expanded(
            child: ListView(children: [
              for (final e in widget.items)
                CheckboxListTile(
                  value: _checked.contains(e),
                  onChanged: (v) => setState(() => v! ? _checked.add(e) : _checked.remove(e)),
                  title: Text(e.fileName),
                  subtitle: Text(fileSize(e.size)),
                ),
            ]),
          ),
          bottomBar('정리 실행 (${_checked.length}개)', () {
            runAll(_checked.toList(), (e) async {
              final (enc, before, after) = await ArchiveTools.cleanTxt(e.path, backup: backup, collapseBlank: _collapse);
              return '$enc → UTF-8, ${fileSize(before)} → ${fileSize(after)}';
            });
          }),
        ]),
      );
}

// =====================================================================
//  TXT → EPUB
// =====================================================================
class TxtToEpubPage extends StatefulWidget {
  final List<MediaItem> items;
  const TxtToEpubPage({super.key, required this.items});
  @override
  State<TxtToEpubPage> createState() => _TxtToEpubPageState();
}

class _TxtToEpubPageState extends State<TxtToEpubPage> with ToolRunner {
  late final Set<MediaItem> _checked = {...widget.items};
  bool _auto = true;
  bool _cover = true;
  bool _addToLibrary = true;

  @override
  Widget build(BuildContext context) => Scaffold(
        appBar: AppBar(title: const Text('TXT → EPUB 변환')),
        body: Column(children: [
          const Padding(
            padding: EdgeInsets.all(16),
            child: Text('텍본을 목차가 있는 EPUB 전자책으로 만듭니다. 같은 폴더에 같은 이름의 .epub 파일이 생기고, 원본 TXT 는 그대로 둡니다.'),
          ),
          SwitchListTile(
            title: const Text('자동 목차'),
            subtitle: const Text('"제1장", "1화", "프롤로그" 같은 줄에서 장을 나눕니다'),
            value: _auto,
            onChanged: (v) => setState(() => _auto = v),
          ),
          SwitchListTile(title: const Text('표지 넣기 (앱에 표지가 있으면)'), value: _cover, onChanged: (v) => setState(() => _cover = v)),
          SwitchListTile(title: const Text('만든 EPUB 을 라이브러리에 추가'), value: _addToLibrary, onChanged: (v) => setState(() => _addToLibrary = v)),
          const Divider(),
          Expanded(
            child: ListView(children: [
              for (final e in widget.items)
                CheckboxListTile(
                  value: _checked.contains(e),
                  onChanged: (v) => setState(() => v! ? _checked.add(e) : _checked.remove(e)),
                  secondary: SizedBox(width: 36, height: 50, child: CoverImage(item: e)),
                  title: Text(e.title),
                  subtitle: Text('${e.fileName} · ${fileSize(e.size)}'),
                ),
            ]),
          ),
          bottomBar('EPUB 만들기 (${_checked.length}개)', () {
            final app = context.read<AppState>();
            final made = <String>[];
            runAll(_checked.toList(), (e) async {
              final cover = _cover && e.coverPath != null && await File(e.coverPath!).exists() ? await File(e.coverPath!).readAsBytes() : null;
              final out = await EpubWriter.fromTxt(e.path, title: e.title, author: e.author, cover: cover, autoChapters: _auto);
              made.add(out);
              return '→ ${p.basename(out)}';
            }).then((_) {
              if (_addToLibrary && made.isNotEmpty) app.importFiles(made);
            });
          }, extra: const [Text('  (원본은 바뀌지 않음)')]),
        ]),
      );
}

// =====================================================================
//  PDF → 텍스트 (스캔본은 글자 인식)
// =====================================================================
class PdfToTextPage extends StatefulWidget {
  final List<MediaItem> items;
  const PdfToTextPage({super.key, required this.items});
  @override
  State<PdfToTextPage> createState() => _PdfToTextPageState();
}

class _PdfToTextPageState extends State<PdfToTextPage> with ToolRunner {
  late final Set<MediaItem> _checked = {...widget.items};
  bool _epub = true;
  bool _addToLibrary = true;
  bool _stop = false;
  String _now = '';

  /// 원본 옆에 쓸 수 없으면(휴대폰의 읽기 전용 폴더 등) 앱 문서 폴더로
  Future<String> _target(MediaItem e, String ext) async {
    final base = p.basenameWithoutExtension(e.path);
    Future<String> free(String dir) async {
      var out = p.join(dir, '$base$ext');
      for (var k = 2; await File(out).exists(); k++) {
        out = p.join(dir, '$base (글자${k == 2 ? '' : ' $k'})$ext');
      }
      return out;
    }

    final beside = await free(p.dirname(e.path));
    try {
      await File(beside).writeAsString('');
      return beside;
    } catch (_) {
      final d = Directory(p.join((await getApplicationDocumentsDirectory()).path, 'ARARIFlex 변환'));
      await d.create(recursive: true);
      return free(d.path);
    }
  }

  Future<void> _run() async {
    final app = context.read<AppState>();
    final list = _checked.toList();
    final made = <String>[];
    _stop = false;
    setState(() {
      running = true;
      progress = 0;
      log = '';
    });
    var ok = 0, fail = 0;
    for (var i = 0; i < list.length && !_stop; i++) {
      final e = list[i];
      try {
        final r = await PdfText.convert(e.path, cancelled: () => _stop, onPage: (d, n) {
          if (!mounted) return;
          setState(() {
            _now = '${e.fileName} · $d / $n쪽';
            progress = (i + (n == 0 ? 1 : d / n)) / list.length;
          });
        });
        if (r.cancelled) break;
        if (r.text.replaceAll(RegExp(r'\s'), '').isEmpty) throw '글자를 찾지 못했습니다';
        final txt = await _target(e, '.txt');
        await File(txt).writeAsString(r.text);
        var out = txt;
        if (_epub) {
          final cover = e.coverPath != null && await File(e.coverPath!).exists() ? await File(e.coverPath!).readAsBytes() : null;
          out = await EpubWriter.fromTxt(txt, title: e.title, author: e.author, cover: cover);
          await File(txt).delete();
        }
        made.add(out);
        ok++;
        log = '${e.fileName} → ${p.basename(out)} (${r.pages}쪽 중 글자 인식 ${r.ocrPages}쪽${r.emptyPages > 0 ? ', 빈 쪽 ${r.emptyPages}' : ''}, ${r.text.length}자)\n$log';
      } on OcrUnavailable catch (err) {
        fail++;
        log = '${e.fileName}: ${err.message}\n$log';
      } catch (err) {
        fail++;
        log = '${e.fileName}: 실패 — $err\n$log';
      }
      if (mounted) setState(() => progress = (i + 1) / list.length);
    }
    if (_addToLibrary && made.isNotEmpty) await app.importFiles(made);
    if (!mounted) return;
    setState(() {
      running = false;
      _now = '';
    });
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('${_stop ? '멈춤' : '완료'}: 성공 $ok · 실패 $fail')));
  }

  @override
  Widget build(BuildContext context) => Scaffold(
        appBar: AppBar(title: const Text('PDF → 텍스트')),
        body: Column(children: [
          const Padding(
            padding: EdgeInsets.all(16),
            child: Text('PDF 의 글을 TXT · EPUB 으로 꺼냅니다. 스캔한 PDF(그림뿐인 쪽)는 기기 안 글자 인식으로 읽습니다. '
                '쪽 번호와 되풀이되는 머리글은 빼고, 줄바꿈으로 끊긴 문장은 잇습니다. 원본 PDF 는 그대로 둡니다.'),
          ),
          SwitchListTile(
            title: const Text('EPUB 으로 만들기'),
            subtitle: const Text('끄면 TXT 로 저장합니다. "제1장" 같은 줄로 목차를 만듭니다'),
            value: _epub,
            onChanged: running ? null : (v) => setState(() => _epub = v),
          ),
          SwitchListTile(
            title: const Text('만든 파일을 라이브러리에 추가'),
            subtitle: const Text('소설로 등록되어 소리 내어 읽기 · 오디오북 저장을 쓸 수 있습니다'),
            value: _addToLibrary,
            onChanged: running ? null : (v) => setState(() => _addToLibrary = v),
          ),
          const Divider(),
          Expanded(
            child: ListView(children: [
              for (final e in widget.items)
                CheckboxListTile(
                  value: _checked.contains(e),
                  onChanged: running ? null : (v) => setState(() => v! ? _checked.add(e) : _checked.remove(e)),
                  secondary: SizedBox(width: 36, height: 50, child: CoverImage(item: e)),
                  title: Text(e.title),
                  subtitle: Text('${e.fileName} · ${fileSize(e.size)}${e.pages == null ? '' : ' · ${e.pages}쪽'}'),
                ),
            ]),
          ),
          if (_now.isNotEmpty) Padding(padding: const EdgeInsets.symmetric(horizontal: 16), child: Text(_now, style: const TextStyle(fontSize: 12))),
          bottomBar(
            running ? '변환 중…' : '변환 (${_checked.length}개)',
            _checked.isEmpty ? null : _run,
            extra: [
              if (running) TextButton(onPressed: () => setState(() => _stop = true), child: const Text('멈춤')),
              const Text('  (원본은 바뀌지 않음)'),
            ],
            showBackup: false,
          ),
        ]),
      );
}
