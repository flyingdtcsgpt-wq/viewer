import 'dart:io';

import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;
import 'package:provider/provider.dart';

import '../app_state.dart';
import '../models/media_item.dart';
import '../services/saf.dart';
import 'browser.dart' show fileSize;

/// 플레이스토어판: 파일 · 폴더를 앱의 "ARARIFlex 폴더" 로 가져오기
///
/// 저장소 권한 없이 사용자가 고른 것만 읽는다(Storage Access Framework). 고른 파일은 종류별 하위 폴더(만화 · 책 · 영상)로
/// 복사하거나 옮긴다(옮기면 원본을 지워 공간을 아낌). 폴더를 고르면 안의 폴더 구조를 그대로 둬서 시리즈 묶기에 쓰인다.
Future<void> openStoreImport(BuildContext context) async {
  final v = await showModalBottomSheet<int>(
    context: context,
    showDragHandle: true,
    builder: (ctx) => SafeArea(
      child: Column(mainAxisSize: MainAxisSize.min, children: [
        ListTile(
          leading: const Icon(Icons.note_add_outlined),
          title: const Text('파일 고르기'),
          subtitle: const Text('만화(CBZ · ZIP) · 책(EPUB · PDF · TXT) · 영상'),
          onTap: () => Navigator.pop(ctx, 0),
        ),
        ListTile(
          leading: const Icon(Icons.drive_folder_upload_outlined),
          title: const Text('폴더 통째로'),
          subtitle: const Text('폴더 안의 파일을 하위 폴더까지 한 번에'),
          onTap: () => Navigator.pop(ctx, 1),
        ),
        ListTile(
          leading: const Icon(Icons.help_outline),
          title: const Text('다른 방법'),
          subtitle: const Text('공유 · PC 에서 USB 로 넣기'),
          onTap: () => Navigator.pop(ctx, 2),
        ),
        const SizedBox(height: 8),
      ]),
    ),
  );
  if (v == null || !context.mounted) return;
  if (v == 2) return showStoreFolderHelp(context);
  List<SafEntry> files;
  var fromFolder = false;
  if (v == 0) {
    files = await Saf.pickFiles();
  } else {
    final tree = await Saf.pickFolder();
    if (tree == null || !context.mounted) return;
    fromFolder = true;
    files = await _withSpinner(context, '폴더 안 파일을 찾는 중…', Saf.listTree(tree));
  }
  if (!context.mounted) return;
  await importSafEntries(context, files, fromFolder: fromFolder);
}

Future<T> _withSpinner<T>(BuildContext context, String msg, Future<T> job) async {
  var open = true;
  showDialog<void>(
    context: context,
    barrierDismissible: false,
    builder: (ctx) => AlertDialog(content: Row(children: [const CircularProgressIndicator(), const SizedBox(width: 16), Expanded(child: Text(msg))])),
  ).whenComplete(() => open = false);
  try {
    return await job;
  } finally {
    if (open && context.mounted) Navigator.of(context, rootNavigator: true).pop();
  }
}

/// 고른 파일들을 서재 폴더로 복사 · 옮기기 → 서재에 추가
Future<void> importSafEntries(BuildContext context, List<SafEntry> picked, {bool fromFolder = false, bool shared = false}) async {
  final state = context.read<AppState>();
  final files = [for (final e in picked) if (kindForPath(e.name) != null) e];
  final skipped = picked.length - files.length;
  if (files.isEmpty) {
    if (picked.isNotEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('가져올 수 있는 파일이 없습니다 (만화 CBZ · ZIP, 책 EPUB · PDF · TXT, 영상 파일)')),
      );
    }
    return;
  }
  final total = files.fold<int>(0, (a, e) => a + (e.size > 0 ? e.size : 0));
  var move = false;
  final go = await showDialog<bool>(
    context: context,
    builder: (ctx) => StatefulBuilder(
      builder: (ctx, set) => AlertDialog(
        title: Text('${files.length}개 가져오기'),
        content: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text('${total > 0 ? '모두 ${fileSize(total)} · ' : ''}만화 ${files.where((e) => kindForPath(e.name) == MediaKind.comic).length} · '
              '책 ${files.where((e) => kindForPath(e.name) == MediaKind.book).length} · 영상 ${files.where((e) => kindForPath(e.name) == MediaKind.video).length}'),
          if (skipped > 0) Text('지원하지 않는 파일 $skipped개는 건너뜁니다', style: Theme.of(ctx).textTheme.bodySmall),
          const SizedBox(height: 12),
          if (!shared) ...[
            Wrap(spacing: 8, runSpacing: 6, children: [
              ChoiceChip(label: const Text('복사 (원본 그대로)'), selected: !move, onSelected: (_) => set(() => move = false)),
              ChoiceChip(label: const Text('옮기기 (원본 지움)'), selected: move, onSelected: (_) => set(() => move = true)),
            ]),
          ],
          const SizedBox(height: 8),
          Text('ARARIFlex 폴더의 만화 · 책 · 영상 폴더로 들어갑니다.', style: Theme.of(ctx).textTheme.bodySmall),
        ]),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('취소')),
          FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('가져오기')),
        ],
      ),
    ),
  );
  if (go != true || !context.mounted) return;

  final progress = ValueNotifier<(int, String)>((0, ''));
  var stop = false;
  final made = <String>[];
  var failed = 0, notDeleted = 0;
  BuildContext? dctx;
  final job = () async {
    for (var i = 0; i < files.length && !stop; i++) {
      final e = files[i];
      progress.value = (i, e.name);
      final kind = kindForPath(e.name)!;
      // 폴더째 가져오면 안의 폴더 구조를 그대로 (시리즈 묶기에 도움)
      final rel = fromFolder ? e.rel.split('/').where((x) => x.isNotEmpty && x != '..').map(_safeName).join(p.separator) : '';
      final dir = p.join(state.storeFolderFor(kind), rel);
      var dest = p.join(dir, _safeName(e.name));
      // 같은 이름: 크기도 같으면 이미 있는 것, 다르면 번호를 붙인다
      final f = await _existing(dest);
      if (f != null && (e.size < 0 || f == e.size)) {
        made.add(dest);
        if (move && !await Saf.delete(e.uri)) notDeleted++;
        continue;
      }
      if (f != null) dest = await _free(dest);
      if (await Saf.copy(e.uri, dest)) {
        made.add(dest);
        if (move && !await Saf.delete(e.uri)) notDeleted++;
      } else {
        failed++;
      }
    }
    progress.value = (files.length, '');
  }();
  showDialog<void>(
    context: context,
    barrierDismissible: false,
    builder: (ctx) {
      dctx = ctx;
      return PopScope(
        canPop: false,
        child: AlertDialog(
          title: const Text('가져오는 중'),
          content: ValueListenableBuilder<(int, String)>(
            valueListenable: progress,
            builder: (_, v, _) => Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
              LinearProgressIndicator(value: files.isEmpty ? null : v.$1 / files.length),
              const SizedBox(height: 8),
              Text('${v.$1} / ${files.length}'),
              if (v.$2.isNotEmpty) Text(v.$2, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 12)),
            ]),
          ),
          actions: [TextButton(onPressed: () => stop = true, child: const Text('멈춤'))],
        ),
      );
    },
  );
  await job;
  final c = dctx;
  if (c != null && c.mounted) Navigator.of(c).pop();
  progress.dispose();
  if (made.isNotEmpty) await state.importFiles(made);
  if (!context.mounted) return;
  ScaffoldMessenger.of(context).showSnackBar(SnackBar(
    content: Text([
      '${made.length}개를 가져왔습니다',
      if (failed > 0) '실패 $failed개',
      if (notDeleted > 0) '원본 $notDeleted개는 지우지 못했습니다',
      if (stop) '멈춤',
    ].join(' · ')),
  ));
}

String _safeName(String s) {
  final t = s.replaceAll(RegExp(r'[\\/:*?"<>|\x00-\x1F]'), '_').trim();
  return t.isEmpty || t == '.' || t == '..' ? 'file' : t;
}

Future<int?> _existing(String path) async {
  try {
    final st = await FileStat.stat(path);
    return st.type == FileSystemEntityType.notFound ? null : st.size;
  } catch (_) {
    return null;
  }
}

Future<String> _free(String path) async {
  final stem = p.withoutExtension(path), ext = p.extension(path);
  for (var n = 2;; n++) {
    final c = '$stem ($n)$ext';
    if (await _existing(c) == null) return c;
  }
}

/// ARARIFlex 폴더 안내 (어디에 넣으면 되는지)
Future<void> showStoreFolderHelp(BuildContext context) {
  final dir = context.read<AppState>().storeDir ?? '';
  return showDialog<void>(
    context: context,
    builder: (ctx) => AlertDialog(
      icon: const Icon(Icons.folder_special_outlined),
      title: const Text('ARARIFlex 폴더'),
      content: SingleChildScrollView(
        child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
          const Text('ARARIFlex 는 이 폴더 안의 만화 · 책 · 영상만 보여 줍니다. 넣는 방법은 세 가지입니다.'),
          const SizedBox(height: 12),
          const Text('1. 앱에서 가져오기', style: TextStyle(fontWeight: FontWeight.bold)),
          const Text('＋ 가져오기 › 파일 고르기 / 폴더 통째로. 복사하거나 옮길 수 있습니다.'),
          const SizedBox(height: 8),
          const Text('2. 다른 앱에서 공유', style: TextStyle(fontWeight: FontWeight.bold)),
          const Text('파일 관리자 · 메신저 · 브라우저에서 파일을 공유 › ARARIFlex 를 고르면 바로 들어옵니다.'),
          const SizedBox(height: 8),
          const Text('3. PC 에서 USB 로', style: TextStyle(fontWeight: FontWeight.bold)),
          const Text('휴대폰을 PC 에 연결하고(파일 전송) 아래 폴더에 넣은 뒤, 앱에서 "다시 찾기" 를 누르세요.'),
          const SizedBox(height: 4),
          SelectableText(_friendly(dir), style: const TextStyle(fontSize: 12)),
          const SizedBox(height: 12),
          const Text('앱을 지우면 이 폴더도 함께 지워질 수 있습니다. 지울 때 "앱 데이터 유지" 를 고르거나, 설정 › 정보 › 서재 백업을 해 두세요.',
              style: TextStyle(fontSize: 12)),
        ]),
      ),
      actions: [TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('확인'))],
    ),
  );
}

/// /storage/emulated/0/Android/data/... → 내장 저장공간 › Android › data › ...
String _friendly(String dir) {
  const root = '/storage/emulated/0/';
  if (!dir.startsWith(root)) return dir;
  return '내장 저장공간 › ${dir.substring(root.length).split('/').join(' › ')}';
}

/// 서재가 비었을 때: 무엇을 어떻게 넣는지 안내
class StoreEmptyGuide extends StatelessWidget {
  const StoreEmptyGuide({super.key});

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    final scheme = Theme.of(context).colorScheme;
    return Center(
      child: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(28, 96, 28, 28),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 420),
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            Icon(Icons.auto_stories_outlined, size: 72, color: scheme.primary),
            const SizedBox(height: 16),
            Text('내 만화 · 책 · 영상을 넣어 보세요', style: text.titleLarge?.copyWith(fontWeight: FontWeight.w800), textAlign: TextAlign.center),
            const SizedBox(height: 8),
            Text('가져온 파일은 ARARIFlex 폴더에 모이고, 시리즈별로 자동으로 묶입니다.',
                style: text.bodyMedium?.copyWith(color: scheme.onSurfaceVariant), textAlign: TextAlign.center),
            const SizedBox(height: 24),
            SizedBox(
              width: double.infinity,
              child: FilledButton.icon(
                style: FilledButton.styleFrom(padding: const EdgeInsets.symmetric(vertical: 14)),
                onPressed: () => openStoreImport(context),
                icon: const Icon(Icons.add),
                label: const Text('가져오기'),
              ),
            ),
            const SizedBox(height: 8),
            TextButton(onPressed: () => showStoreFolderHelp(context), child: const Text('다른 방법 (공유 · PC 에서 USB 로)')),
            const SizedBox(height: 16),
            Text('지원 형식: 만화 CBZ · ZIP / 책 EPUB · PDF · TXT / 영상 MP4 · MKV 등', style: text.bodySmall, textAlign: TextAlign.center),
            const SizedBox(height: 8),
            Text('ARARIFlex 는 콘텐츠를 제공하거나 내려받지 않는 뷰어입니다. 직접 구입했거나 이용 권한이 있는 파일만 넣어 주세요.',
                style: text.bodySmall?.copyWith(color: scheme.onSurfaceVariant), textAlign: TextAlign.center),
          ]),
        ),
      ),
    );
  }
}
