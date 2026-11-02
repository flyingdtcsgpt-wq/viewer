import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;
import 'package:provider/provider.dart';

import '../app_state.dart';
import '../models/media_item.dart';
import '../services/storage_permission.dart';
import 'browser.dart' show fileSize;

/// 폴더 추가: 폴더 고르기 → 겹침 확인 → 발견된 항목 목록에서 골라 추가
Future<void> addFolderFlow(BuildContext context) async {
  if (!await ensureStorageAccess(context)) return;
  final dir = await FilePicker.getDirectoryPath(dialogTitle: '추가할 폴더 선택');
  if (dir == null || !context.mounted) return;
  await showImportDialog(context, folder: dir);
}

/// 파일 추가: 파일 고르기 → 목록에서 골라 추가
Future<void> addFilesFlow(BuildContext context) async {
  final files = await FilePicker.pickFiles(dialogTitle: '추가할 파일 선택');
  final paths = files.map((f) => f.path).whereType<String>().toList();
  if (paths.isEmpty || !context.mounted) return;
  await showImportDialog(context, files: paths);
}

Future<void> showImportDialog(BuildContext context, {String? folder, List<String>? files}) => showDialog(
      context: context,
      barrierDismissible: false,
      builder: (_) => _ImportDialog(folder: folder, files: files),
    );

class _ImportDialog extends StatefulWidget {
  final String? folder;
  final List<String>? files;
  const _ImportDialog({this.folder, this.files});
  @override
  State<_ImportDialog> createState() => _ImportDialogState();
}

class _ImportDialogState extends State<_ImportDialog> {
  late final AppState _app = context.read<AppState>();
  List<ImportCandidate>? _list;
  int _found = 0;
  String _overlap = '';
  final _kinds = {...MediaKind.values};
  bool _onlyNew = true;
  String _filter = '';
  late final ImportOptions _opt = ImportOptions(
    baseDir: widget.folder,
    targetRoot: _app.settings.libraryRoot,
    group: widget.folder != null ? GroupMode.auto : GroupMode.auto,
    watch: widget.folder != null,
  );
  late final _bundleName = TextEditingController(text: widget.folder != null ? p.basename(widget.folder!) : '새 묶음');
  bool _running = false;

  @override
  void initState() {
    super.initState();
    _scan();
  }

  Future<void> _scan() async {
    final dir = widget.folder;
    if (dir != null) {
      final (parent, children) = _app.folderOverlap(dir);
      if (parent != null) {
        _overlap = '이 폴더는 이미 등록된 라이브러리 폴더 "$parent" 안에 있습니다. 이미 등록된 파일은 건너뛰고, 새 파일만 보여줍니다.';
        _opt.watch = false;
      } else if (children.isNotEmpty) {
        _overlap = '이 폴더 안에 이미 등록된 라이브러리 폴더 ${children.length}개가 있습니다:\n'
            '${children.map((c) => '  · $c').join('\n')}\n'
            '"원본 위치에 연결"로 라이브러리 폴더에 등록하면 이 폴더 하나로 합쳐집니다. 이미 등록된 파일은 다시 추가되지 않습니다.';
      }
    }
    final list = dir != null
        ? await _app.previewFolder(dir, onProgress: (n) {
            if (mounted) setState(() => _found = n);
          })
        : await _app.previewFiles(widget.files!);
    if (mounted) setState(() => _list = list);
  }

  List<ImportCandidate> get _shown => (_list ?? const <ImportCandidate>[])
      .where((c) => _kinds.contains(c.kind))
      .where((c) => !_onlyNew || c.status != ImportStatus.registered)
      .where((c) => _filter.isEmpty || c.path.toLowerCase().contains(_filter.toLowerCase()))
      .toList();

  String _rel(String path) => widget.folder != null ? p.relative(path, from: widget.folder!) : path;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final text = Theme.of(context).textTheme;
    final list = _list;
    final shown = _shown;
    // 필터로 가린 항목은 추가하지 않는다 (보이는 것 중 체크한 것만)
    final picked = shown.where((c) => c.selected && c.status != ImportStatus.registered).toList();
    final counts = <MediaKind, int>{};
    for (final c in list ?? const <ImportCandidate>[]) {
      counts[c.kind] = (counts[c.kind] ?? 0) + 1;
    }
    final fresh = list?.where((c) => c.status == ImportStatus.fresh).length ?? 0;
    final dups = list?.where((c) => c.status == ImportStatus.duplicate).length ?? 0;
    final regs = list?.where((c) => c.status == ImportStatus.registered).length ?? 0;
    final size = MediaQuery.sizeOf(context);

    final table = list == null
        ? Center(
            child: Column(mainAxisSize: MainAxisSize.min, children: [
              const CircularProgressIndicator(),
              const SizedBox(height: 12),
              Text('폴더를 살펴보는 중… $_found개 발견'),
            ]),
          )
        : Column(children: [
            // 거르기
            Wrap(spacing: 6, runSpacing: 6, crossAxisAlignment: WrapCrossAlignment.center, children: [
              for (final k in MediaKind.values)
                if ((counts[k] ?? 0) > 0)
                  FilterChip(
                    label: Text('${kindLabel(k)} ${counts[k]}'),
                    selected: _kinds.contains(k),
                    onSelected: (v) => setState(() => v ? _kinds.add(k) : _kinds.remove(k)),
                  ),
              FilterChip(label: const Text('이미 등록된 것 숨기기'), selected: _onlyNew, onSelected: (v) => setState(() => _onlyNew = v)),
              SizedBox(
                width: 220,
                child: TextField(
                  decoration: const InputDecoration(isDense: true, prefixIcon: Icon(Icons.search, size: 18), hintText: '경로로 찾기'),
                  onChanged: (v) => setState(() => _filter = v),
                ),
              ),
            ]),
            const SizedBox(height: 6),
            Container(
              color: scheme.surfaceContainer,
              child: Row(children: [
                Checkbox(
                  tristate: true,
                  value: shown.every((c) => c.selected || c.status == ImportStatus.registered)
                      ? true
                      : (shown.any((c) => c.selected) ? null : false),
                  onChanged: (v) => setState(() {
                    final on = v ?? false;
                    for (final c in shown) {
                      if (c.status != ImportStatus.registered) c.selected = on;
                    }
                  }),
                ),
                const Text('전체 선택/해제', style: TextStyle(fontWeight: FontWeight.w700)),
                const Spacer(),
                TextButton(
                  onPressed: () => setState(() {
                    for (final c in shown) {
                      c.selected = c.status == ImportStatus.fresh;
                    }
                  }),
                  child: const Text('새 항목만 선택'),
                ),
              ]),
            ),
            Expanded(
              child: ListView.builder(
                itemCount: shown.length,
                itemExtent: 44,
                itemBuilder: (_, i) {
                  final c = shown[i];
                  final reg = c.status == ImportStatus.registered;
                  final (label, color) = switch (c.status) {
                    ImportStatus.fresh => ('새 항목', Colors.green),
                    ImportStatus.registered => ('이미 등록됨', Colors.grey),
                    ImportStatus.duplicate => ('중복 의심', Colors.orange),
                  };
                  return Opacity(
                    opacity: reg ? 0.5 : 1,
                    child: Row(children: [
                      Checkbox(value: c.selected, onChanged: reg ? null : (v) => setState(() => c.selected = v ?? false)),
                      Icon(switch (c.kind) {
                        MediaKind.book => Icons.menu_book,
                        MediaKind.comic => Icons.auto_stories,
                        MediaKind.image => Icons.image,
                        MediaKind.video => Icons.movie,
                      }, size: 18),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Tooltip(
                          message: c.duplicateOf != null ? '같은 파일로 보임: ${c.duplicateOf}' : c.path,
                          child: Text(_rel(c.path), maxLines: 1, overflow: TextOverflow.ellipsis),
                        ),
                      ),
                      SizedBox(width: 80, child: Text(fileSize(c.size), style: text.bodySmall)),
                      Container(
                        width: 84,
                        margin: const EdgeInsets.only(right: 8),
                        padding: const EdgeInsets.symmetric(vertical: 2),
                        decoration: BoxDecoration(border: Border.all(color: color), borderRadius: BorderRadius.circular(4)),
                        child: Text(label, textAlign: TextAlign.center, style: TextStyle(fontSize: 11, color: color)),
                      ),
                    ]),
                  );
                },
              ),
            ),
          ]);

    Widget section(String title, List<Widget> children) => Padding(
          padding: const EdgeInsets.only(bottom: 16),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(title, style: const TextStyle(fontWeight: FontWeight.w800)),
            const SizedBox(height: 6),
            ...children,
          ]),
        );

    // 하나만 고르는 줄 (Radio 위젯 API 변경과 무관하게 같은 모양)
    Widget radio<T>(T value, T group, String title, String? sub, ValueChanged<T?> f) => ListTile(
          dense: true,
          contentPadding: EdgeInsets.zero,
          leading: Icon(value == group ? Icons.radio_button_checked : Icons.radio_button_unchecked,
              color: value == group ? scheme.primary : null),
          onTap: () => f(value),
          title: Text(title),
          subtitle: sub == null ? null : Text(sub, style: const TextStyle(fontSize: 11)),
        );

    final options = ListView(children: [
      section('추가 방식', [
        radio(ImportMode.reference, _opt.mode, '원본 위치에 연결', '파일은 그대로 두고 목록에만 넣습니다', (v) => setState(() => _opt.mode = v!)),
        radio(ImportMode.copy, _opt.mode, '라이브러리 폴더로 복사', '원본은 두고 정리 폴더에 사본을 만듭니다', (v) => setState(() => _opt.mode = v!)),
        radio(ImportMode.move, _opt.mode, '라이브러리 폴더로 이동', '정리 폴더로 옮깁니다 (원래 자리에서 사라짐)', (v) => setState(() => _opt.mode = v!)),
        if (_opt.mode != ImportMode.reference)
          ListTile(
            dense: true,
            contentPadding: EdgeInsets.zero,
            leading: const Icon(Icons.folder),
            title: Text(_opt.targetRoot ?? '정리 폴더를 고르세요'),
            subtitle: Text('규칙: ${_app.settings.organizePattern}', style: const TextStyle(fontSize: 11)),
            trailing: const Icon(Icons.edit),
            onTap: () async {
              final d = await FilePicker.getDirectoryPath(dialogTitle: '정리 폴더 선택');
              if (d != null) setState(() => _opt.targetRoot = d);
            },
          ),
      ]),
      section('묶기', [
        radio(GroupMode.auto, _opt.group, '파일명으로 시리즈 자동 묶기', '"01권", "S01E02" 등을 보고 묶음', (v) => setState(() => _opt.group = v!)),
        if (widget.folder != null) ...[
          radio(GroupMode.folderTree, _opt.group, '폴더 구조 그대로 묶음 만들기', '하위 폴더마다 하위 묶음', (v) => setState(() => _opt.group = v!)),
          radio(GroupMode.wholeFolder, _opt.group, '폴더 전체를 묶음 하나로', '잡동사니 폴더: 표지 하나로 묶고, 안에서 책·그림·영상 구분', (v) => setState(() => _opt.group = v!)),
        ] else
          radio(GroupMode.wholeFolder, _opt.group, '고른 파일을 묶음 하나로', null, (v) => setState(() => _opt.group = v!)),
        radio(GroupMode.none, _opt.group, '묶지 않기', null, (v) => setState(() => _opt.group = v!)),
        if (_opt.group == GroupMode.wholeFolder)
          TextField(controller: _bundleName, decoration: const InputDecoration(labelText: '묶음 이름', isDense: true)),
      ]),
      section('기타', [
        if (_app.isAdmin)
          CheckboxListTile(
            dense: true,
            contentPadding: EdgeInsets.zero,
            value: _opt.hidden,
            onChanged: _app.hasHiddenPassword ? (v) => setState(() => _opt.hidden = v ?? false) : null,
            title: const Text('숨김으로 추가'),
            subtitle: Text(_app.hasHiddenPassword ? '숨김 목록에만 보이고 파일도 OS 숨김 속성이 됩니다' : '먼저 관리자 메뉴에서 숨김 비밀번호를 정하세요',
                style: const TextStyle(fontSize: 11)),
          ),
        if (widget.folder != null && _opt.mode == ImportMode.reference)
          CheckboxListTile(
            dense: true,
            contentPadding: EdgeInsets.zero,
            value: _opt.watch,
            onChanged: (v) => setState(() => _opt.watch = v ?? false),
            title: const Text('라이브러리 폴더로 등록'),
            subtitle: const Text('사이드바에 보이고, "다시 스캔" 때 새 파일을 찾습니다', style: TextStyle(fontSize: 11)),
          ),
      ]),
    ]);

    return Dialog(
      insetPadding: const EdgeInsets.all(24),
      child: SizedBox(
        width: size.width.clamp(0, 1300).toDouble(),
        height: size.height * 0.9,
        child: Padding(
          padding: const EdgeInsets.all(20),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Row(children: [
              Expanded(
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text(widget.folder != null ? '폴더 추가' : '파일 추가', style: text.titleLarge?.copyWith(fontWeight: FontWeight.w800)),
                  Text(widget.folder ?? '${widget.files!.length}개 파일', style: text.bodySmall, maxLines: 1, overflow: TextOverflow.ellipsis),
                ]),
              ),
              if (list != null)
                Text('발견 ${list.length}개 · 새 항목 $fresh · 중복 의심 $dups · 이미 등록 $regs', style: text.bodyMedium),
            ]),
            if (_overlap.isNotEmpty)
              Container(
                margin: const EdgeInsets.only(top: 10),
                padding: const EdgeInsets.all(10),
                decoration: BoxDecoration(color: Colors.amber.withValues(alpha: 0.15), borderRadius: BorderRadius.circular(8)),
                child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  const Icon(Icons.info_outline, color: Colors.amber),
                  const SizedBox(width: 8),
                  Expanded(child: Text(_overlap)),
                ]),
              ),
            const SizedBox(height: 10),
            Expanded(
              child: size.width >= 900
                  ? Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                      Expanded(child: table),
                      const VerticalDivider(width: 24),
                      SizedBox(width: 340, child: options),
                    ])
                  : Column(children: [Expanded(child: table), SizedBox(height: 260, child: options)]),
            ),
            const Divider(),
            Row(children: [
              if (_running) const Expanded(child: LinearProgressIndicator()) else const Spacer(),
              const SizedBox(width: 16),
              TextButton(onPressed: _running ? null : () => Navigator.pop(context), child: const Text('취소')),
              const SizedBox(width: 8),
              FilledButton.icon(
                onPressed: _running || picked.isEmpty || (_opt.mode != ImportMode.reference && _opt.targetRoot == null)
                    ? null
                    : () async {
                        setState(() => _running = true);
                        _opt.bundleName = _bundleName.text.trim().isEmpty ? null : _bundleName.text.trim();
                        final messenger = ScaffoldMessenger.of(context);
                        try {
                          final n = await _app.importCandidates(picked, _opt);
                          if (!context.mounted) return;
                          Navigator.pop(context);
                          final fail = picked.length - n;
                          messenger.showSnackBar(SnackBar(
                              content: Text(fail > 0 && _opt.mode != ImportMode.reference ? '$n개를 추가했습니다 (${_app.scanStatus})' : '$n개를 추가했습니다')));
                        } catch (e) {
                          if (!mounted) return;
                          setState(() => _running = false);
                          messenger.showSnackBar(SnackBar(content: Text('추가하지 못했습니다: ${e is StateError ? e.message : e}')));
                        }
                      },
                icon: const Icon(Icons.add),
                label: Text('${picked.length}개 추가'),
              ),
            ]),
          ]),
        ),
      ),
    );
  }
}
