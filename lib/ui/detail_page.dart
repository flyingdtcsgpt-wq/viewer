import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:open_filex/open_filex.dart';
import 'package:provider/provider.dart';

import '../app_state.dart';
import '../models/media_item.dart';
import 'cover_tile.dart';
import 'metadata_search_dialog.dart';
import 'viewers/open_item.dart';

/// 기본 앱으로 열기 (open_filex 는 모바일 전용이라 데스크톱은 OS 명령 사용)
Future<void> openWithSystem(String path) async {
  if (Platform.isAndroid || Platform.isIOS) {
    await OpenFilex.open(path);
  } else if (Platform.isWindows) {
    await Process.run('explorer.exe', [path]);
  } else if (Platform.isMacOS) {
    await Process.run('open', [path]);
  } else {
    await Process.run('xdg-open', [path]);
  }
}

class DetailPage extends StatefulWidget {
  final MediaItem item;
  const DetailPage({super.key, required this.item});

  @override
  State<DetailPage> createState() => _DetailPageState();
}

class _DetailPageState extends State<DetailPage> {
  late final _title = TextEditingController(text: widget.item.title);
  late final _author = TextEditingController(text: widget.item.author);
  late final _publisher = TextEditingController(text: widget.item.publisher);
  late final _isbn = TextEditingController(text: widget.item.isbn);
  late final _series = TextEditingController(text: widget.item.series);
  late final _year = TextEditingController(text: widget.item.year?.toString());
  late final _desc = TextEditingController(text: widget.item.description);
  late final _tags = TextEditingController(text: widget.item.tags.join(', '));
  bool _busy = false;

  MediaItem get item => widget.item;
  AppState get state => context.read<AppState>();

  void _reloadFields() {
    _title.text = item.title;
    _author.text = item.author ?? '';
    _publisher.text = item.publisher ?? '';
    _isbn.text = item.isbn ?? '';
    _series.text = item.series ?? '';
    _year.text = item.year?.toString() ?? '';
    _desc.text = item.description ?? '';
    _tags.text = item.tags.join(', ');
  }

  String? _v(TextEditingController c) => c.text.trim().isEmpty ? null : c.text.trim();

  Future<void> _save() async {
    item
      ..title = _v(_title) ?? item.title
      ..author = _v(_author)
      ..publisher = _v(_publisher)
      ..isbn = _v(_isbn)
      ..series = _v(_series)
      ..year = int.tryParse(_year.text)
      ..description = _v(_desc)
      ..tags = _tags.text.split(',').map((e) => e.trim()).where((e) => e.isNotEmpty).toSet().toList();
    await state.save(item);
    _toast('저장했습니다');
  }

  Future<void> _run(Future<void> Function() f) async {
    setState(() => _busy = true);
    try {
      await f();
    } catch (e) {
      _toast('오류: $e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  void _toast(String msg) {
    if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));
  }

  Future<void> _searchOnline() async {
    final query = _v(_isbn) ?? [_v(_title), _v(_author)].whereType<String>().join(' ');
    final picked = await showMetadataSearch(context, query);
    if (picked == null) return;
    await _run(() async {
      await state.applyMetadata(item, picked);
      setState(_reloadFields);
    });
  }

  Future<void> _aiParse() => _run(() async {
        final r = await state.ai.parseFileName(item.fileName);
        setState(() {
          if ((r['title'] ?? '').toString().isNotEmpty) _title.text = r['title'];
          if ((r['author'] ?? '').toString().isNotEmpty) _author.text = r['author'];
          if ((r['series'] ?? '').toString().isNotEmpty) _series.text = r['series'];
        });
        _toast('AI가 파일명을 분석했습니다. 확인 후 저장하세요.');
      });

  Future<void> _aiTags() => _run(() async {
        final tags = await state.ai.suggestTags(item);
        setState(() => _tags.text = {..._tags.text.split(',').map((e) => e.trim()).where((e) => e.isNotEmpty), ...tags}.join(', '));
      });

  Future<void> _pickCover() async {
    final f = await FilePicker.pickFile(type: FileType.image);
    if (f?.path == null) return;
    await _run(() async {
      item.coverPath = await state.covers.importLocal(f!.path!, item.path);
      await state.save(item);
      setState(() {});
    });
  }

  Future<void> _organize() async {
    final move = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text('라이브러리 폴더로 정리'),
        content: Text('규칙: ${state.settings.organizePattern}\n대상: ${state.settings.libraryRoot ?? '(설정에서 지정 필요)'}'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context), child: const Text('취소')),
          TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('복사')),
          FilledButton(onPressed: () => Navigator.pop(context, true), child: const Text('이동')),
        ],
      ),
    );
    if (move == null) return;
    await _save();
    await _run(() async {
      await state.organize(item, move: move);
      setState(() {});
      _toast('정리 완료: ${item.path}');
    });
  }

  Future<void> _delete() async {
    final del = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text('삭제'),
        content: const Text('라이브러리 목록에서만 뺄까요, 실제 파일도 지울까요?'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context), child: const Text('취소')),
          TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('목록에서만')),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: Theme.of(context).colorScheme.error),
            onPressed: () => Navigator.pop(context, true),
            child: const Text('파일도 삭제'),
          ),
        ],
      ),
    );
    if (del == null) return;
    await state.remove(item, deleteFile: del);
    if (mounted) Navigator.pop(context);
  }

  @override
  Widget build(BuildContext context) {
    final wide = MediaQuery.sizeOf(context).width >= 800;
    final aiOn = context.watch<AppState>().ai.enabled;

    final cover = Column(children: [
      AspectRatio(
        aspectRatio: 0.68,
        child: ClipRRect(borderRadius: BorderRadius.circular(12), child: CoverImage(item: item, fit: BoxFit.contain)),
      ),
      const SizedBox(height: 12),
      Wrap(spacing: 8, runSpacing: 8, alignment: WrapAlignment.center, children: [
        FilledButton.icon(
          onPressed: () async {
            await openItem(context, item);
            if (mounted) setState(() {});
          },
          icon: Icon(item.kind == MediaKind.video ? Icons.play_arrow : Icons.chrome_reader_mode),
          label: Text(item.kind == MediaKind.video
              ? (item.progress > 0 ? '이어보기' : '재생')
              : (item.progress > 0 ? '이어읽기 ${(item.progress * 100).round()}%' : '보기')),
        ),
        OutlinedButton.icon(
          onPressed: () => openWithSystem(item.path),
          icon: const Icon(Icons.open_in_new),
          label: const Text('다른 앱으로'),
        ),
        OutlinedButton.icon(onPressed: _pickCover, icon: const Icon(Icons.image), label: const Text('커버 변경')),
        if (Platform.isWindows)
          OutlinedButton.icon(
            onPressed: () => Process.run('explorer.exe', ['/select,${item.path}']),
            icon: const Icon(Icons.folder_open),
            label: const Text('폴더 열기'),
          ),
      ]),
      const SizedBox(height: 12),
      Row(mainAxisAlignment: MainAxisAlignment.center, children: [
        for (var i = 1; i <= 5; i++)
          IconButton(
            icon: Icon(i <= item.rating ? Icons.star : Icons.star_border, color: Colors.amber),
            onPressed: () {
              setState(() => item.rating = item.rating == i ? 0 : i);
              state.save(item);
            },
          ),
      ]),
    ]);

    Widget field(TextEditingController c, String label, {int lines = 1, TextInputType? type}) => Padding(
          padding: const EdgeInsets.only(bottom: 12),
          child: TextField(
            controller: c,
            maxLines: lines,
            keyboardType: type,
            decoration: InputDecoration(labelText: label, border: const OutlineInputBorder()),
          ),
        );

    final form = Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      Wrap(spacing: 8, runSpacing: 8, children: [
        if (item.kind == MediaKind.book || item.kind == MediaKind.comic)
          FilledButton.tonalIcon(onPressed: _searchOnline, icon: const Icon(Icons.travel_explore), label: const Text('인터넷에서 정보 가져오기')),
        if (aiOn) ...[
          FilledButton.tonalIcon(onPressed: _aiParse, icon: const Icon(Icons.auto_awesome), label: const Text('AI 파일명 분석')),
          FilledButton.tonalIcon(onPressed: _aiTags, icon: const Icon(Icons.sell), label: const Text('AI 태그 추천')),
        ],
      ]),
      const SizedBox(height: 16),
      field(_title, '제목'),
      field(_author, item.kind == MediaKind.video ? '감독/출연' : '저자'),
      if (item.kind != MediaKind.image && item.kind != MediaKind.video) ...[
        field(_publisher, '출판사'),
        field(_isbn, 'ISBN', type: TextInputType.number),
      ],
      field(_series, '시리즈'),
      field(_year, '연도', type: TextInputType.number),
      field(_tags, '태그 (쉼표로 구분)'),
      field(_desc, '설명 / 메모', lines: 6),
      Text('파일: ${item.path}', style: Theme.of(context).textTheme.bodySmall),
      Text('크기: ${(item.size / 1024 / 1024).toStringAsFixed(1)} MB · ${item.storage == StorageMode.managed ? '라이브러리 관리' : '원본 위치 참조'}',
          style: Theme.of(context).textTheme.bodySmall),
    ]);

    return Scaffold(
      appBar: AppBar(
        title: Text(item.title, overflow: TextOverflow.ellipsis),
        actions: [
          IconButton(
            tooltip: '즐겨찾기',
            icon: Icon(item.favorite ? Icons.favorite : Icons.favorite_border),
            onPressed: () {
              setState(() => item.favorite = !item.favorite);
              state.save(item);
            },
          ),
          IconButton(tooltip: '라이브러리 폴더로 정리', icon: const Icon(Icons.drive_file_move), onPressed: _organize),
          IconButton(tooltip: '삭제', icon: const Icon(Icons.delete_outline), onPressed: _delete),
          IconButton(tooltip: '저장', icon: const Icon(Icons.save), onPressed: _save),
        ],
        bottom: _busy ? const PreferredSize(preferredSize: Size.fromHeight(4), child: LinearProgressIndicator()) : null,
      ),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(16),
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 1100),
            child: wide
                ? Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    SizedBox(width: 320, child: cover),
                    const SizedBox(width: 24),
                    Expanded(child: form),
                  ])
                : Column(children: [
                    SizedBox(width: 260, child: cover),
                    const SizedBox(height: 24),
                    form,
                  ]),
          ),
        ),
      ),
    );
  }
}
