import 'dart:io';

import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;
import 'package:provider/provider.dart';

import '../app_state.dart';
import '../models/media_item.dart';
import '../services/linked.dart';
import '../services/saf.dart';
import 'browser.dart' show fileSize;
import 'guide.dart';

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
          leading: const Icon(Icons.add_link),
          title: const Text('폴더 연결'),
          subtitle: const Text('내 폴더 · SD 카드를 복사 없이 그대로 서재로 (앱을 지워도 파일이 남습니다)'),
          onTap: () => Navigator.pop(ctx, 3),
        ),
        const Divider(height: 1),
        ListTile(
          leading: const Icon(Icons.note_add_outlined),
          title: const Text('파일 고르기'),
          subtitle: const Text('만화(CBZ · ZIP) · 책(EPUB · PDF · TXT) · 영상을 앱 폴더로 복사 · 옮기기'),
          onTap: () => Navigator.pop(ctx, 0),
        ),
        ListTile(
          leading: const Icon(Icons.drive_folder_upload_outlined),
          title: const Text('폴더 통째로 가져오기'),
          subtitle: const Text('폴더 안의 파일을 하위 폴더까지 앱 폴더로 복사 · 옮기기'),
          onTap: () => Navigator.pop(ctx, 1),
        ),
        ListTile(
          leading: const Icon(Icons.help_outline),
          title: const Text('다른 방법으로 넣기'),
          subtitle: const Text('다른 앱에서 공유 · PC 에서 USB 로'),
          onTap: () => Navigator.pop(ctx, 2),
        ),
        const SizedBox(height: 8),
      ]),
    ),
  );
  if (v == null || !context.mounted) return;
  if (v == 2) return showStoreFolderHelp(context);
  if (v == 3) return linkFolderFlow(context);
  List<SafEntry> files;
  String? tree;
  if (v == 0) {
    files = await Saf.pickFiles();
  } else {
    tree = await Saf.pickFolder();
    if (tree == null || !context.mounted) return;
    files = await _withSpinner(context, '폴더 안 파일을 찾는 중…', Saf.listTree(tree));
  }
  try {
    if (context.mounted) await importSafEntries(context, files, fromFolder: tree != null);
  } finally {
    // 다 가져왔으면 그 폴더를 읽을 권한을 돌려준다 (계속 쥐고 있을 이유가 없다)
    if (tree != null) Saf.releaseFolder(tree).catchError((_) {});
  }
}

/// 폴더 연결: 시스템 폴더 선택 창에서 고른 폴더를 복사하지 않고 그대로 서재로 쓴다 (기기 저장공간 · SD 카드)
Future<void> linkFolderFlow(BuildContext context) async {
  final state = context.read<AppState>();
  final go = await showDialog<bool>(
    context: context,
    builder: (ctx) => AlertDialog(
      icon: const Icon(Icons.add_link),
      title: const Text('폴더 연결'),
      content: const SingleChildScrollView(
        child: Text('기기 저장공간이나 SD 카드에 있는 폴더를 고르면, 파일을 복사하지 않고 그 자리에서 바로 봅니다.\n\n'
            '• 그 폴더에 파일을 넣거나 지우면 서재에도 그대로 나타납니다.\n'
            '• 파일은 내가 정한 폴더에 그대로 있어서 파일 앱 · PC 에서 보이고, 앱을 지워도 남습니다.\n'
            '• 안드로이드 규칙으로 저장공간 맨 위, Download 폴더 자체, Android 폴더는 고를 수 없습니다. 그 안에 만든 폴더는 됩니다.\n\n'
            '다음 화면에서 폴더를 열고 아래쪽 "이 폴더 사용" → "허용" 을 누르세요.'),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('취소')),
        FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('폴더 고르기')),
      ],
    ),
  );
  if (go != true) return;
  final tree = await Saf.pickFolder();
  if (tree == null || !context.mounted) return;
  final err = await _withSpinner(context, '폴더를 연결하는 중…', state.linkFolder(tree));
  if (!context.mounted) return;
  ScaffoldMessenger.of(context)
      .showSnackBar(SnackBar(content: Text(err ?? '폴더를 연결했습니다. 안의 파일을 서재에 올리는 중입니다…')));
}

/// 연결한 폴더 하나: 다시 훑기 · 연결 끊기
Future<void> showLinkedFolder(BuildContext context, LinkedFolder f) async {
  final state = context.read<AppState>();
  final offline = state.offlineLinked.contains(f.path);
  final v = await showDialog<int>(
    context: context,
    builder: (ctx) => AlertDialog(
      icon: Icon(f.removable ? Icons.sd_card_outlined : Icons.folder_outlined),
      title: Text(f.label),
      content: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
        SelectableText(_friendly(f.path), style: const TextStyle(fontSize: 12)),
        const SizedBox(height: 10),
        Text(offline
            ? (f.removable
                ? '지금은 이 폴더를 읽을 수 없습니다. SD 카드(또는 USB)를 꽂고 "다시 훑기" 를 누르세요. 목록과 읽던 위치는 그대로 남아 있습니다.'
                : '지금은 이 폴더를 읽을 수 없습니다. 폴더를 옮겼거나 지웠다면 연결을 끊고 다시 연결해 주세요.')
            : '서재에 ${state.linkedCount(f)}개가 올라와 있습니다. 이 폴더에 파일을 넣거나 지우면 앱을 열 때 저절로 반영됩니다.'),
      ]),
      actions: [
        TextButton(onPressed: () => Navigator.pop(ctx, 2), child: const Text('연결 끊기')),
        TextButton(onPressed: () => Navigator.pop(ctx, 1), child: const Text('다시 훑기')),
        FilledButton(onPressed: () => Navigator.pop(ctx), child: const Text('닫기')),
      ],
    ),
  );
  if (!context.mounted) return;
  if (v == 1) {
    await state.rescanWhenFree();
    if (context.mounted && state.offlineLinked.contains(f.path)) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('아직 폴더를 읽을 수 없습니다')));
    }
  } else if (v == 2) {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('연결을 끊을까요?'),
        content: Text('"${f.label}" 의 ${state.linkedCount(f)}개가 서재 목록에서 빠집니다.\n\n'
            '파일은 지워지지 않고 그 폴더에 그대로 남습니다. 다만 읽던 위치와 책갈피는 사라집니다.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('취소')),
          FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('연결 끊기')),
        ],
      ),
    );
    if (ok == true) await state.unlinkFolder(f);
  }
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
    if (picked.isEmpty && shared) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('가져올 파일이 없습니다. 글자나 링크가 아니라 파일을 공유해 주세요')),
      );
    }
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
              ChoiceChip(label: const Text('복사'), selected: !move, onSelected: (_) => set(() => move = false)),
              ChoiceChip(label: const Text('옮기기'), selected: move, onSelected: (_) => set(() => move = true)),
            ]),
            const SizedBox(height: 8),
            // 고른 방식이 무엇을 하는지 바로 아래에 풀어 쓴다
            Text(
              move
                  ? '옮기기: ARARIFlex 폴더에 넣은 뒤, 지금 고른 원래 파일을 지웁니다. 저장공간을 아낍니다.'
                  : '복사: 지금 고른 원래 파일은 그대로 두고, ARARIFlex 폴더에 하나 더 만듭니다.${total > 0 ? ' 저장공간이 ${fileSize(total)} 더 필요합니다.' : ''}',
              style: Theme.of(ctx).textTheme.bodySmall,
            ),
          ],
          const SizedBox(height: 8),
          Text('가져온 파일은 ARARIFlex 폴더의 만화 · 책 · 영상 폴더에 들어갑니다. 나중에 앱에서 삭제하면 이 폴더 안의 파일이 지워집니다.',
              style: Theme.of(ctx).textTheme.bodySmall),
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
  var copied = 0, already = 0, failed = 0, notDeleted = 0;
  final job = () async {
    for (var i = 0; i < files.length && !stop; i++) {
      final e = files[i];
      progress.value = (i, e.name);
      final kind = kindForPath(e.name)!;
      // 폴더째 가져오면 안의 폴더 구조를 그대로 (시리즈 묶기에 도움)
      final rel = fromFolder ? e.rel.split('/').where((x) => x.isNotEmpty && x != '..').map(_safeName).join(p.separator) : '';
      final dir = p.join(state.storeFolderFor(kind), rel);
      var dest = p.join(dir, _safeName(e.name));
      // 같은 이름: 크기까지 같으면 이미 있는 것으로 보고 건너뛴다. 이때는 "옮기기"여도 원본을 지우지 않는다
      // (이름과 크기만 같은 다른 파일일 수도 있어서. 크기를 알 수 없으면 같은 파일로 보지 않고 번호를 붙여 따로 넣는다)
      final f = await _existing(dest);
      if (f != null && e.size >= 0 && f == e.size) {
        already++;
        continue;
      }
      if (f != null) dest = await _free(dest);
      if (await Saf.copy(e.uri, dest)) {
        copied++;
        if (move) {
          // 다 넘어온 것을 확인한 뒤에만 원본을 지운다
          final got = await _existing(dest);
          final whole = got != null && got > 0 && (e.size < 0 || got == e.size);
          if (!whole || !await Saf.delete(e.uri)) notDeleted++;
        }
      } else {
        failed++;
      }
    }
    progress.value = (files.length, '');
  }();
  // 창은 일이 끝나면 스스로 닫힌다 (일이 창보다 먼저 끝나거나 다른 화면이 위에 떠도 남지 않게)
  showDialog<void>(
    context: context,
    barrierDismissible: false,
    builder: (_) => _ProgressDialog(job: job, progress: progress, total: files.length, onStop: () => stop = true),
  );
  await job;
  // 서재에 올리기: 폴더를 다시 훑는다 (마침 돌고 있던 자동 훑기가 있으면 끝난 뒤에)
  if (copied > 0) await state.rescanWhenFree();
  if (!context.mounted) return;
  ScaffoldMessenger.of(context).showSnackBar(SnackBar(
    content: Text([
      if (copied > 0 || already == 0) '$copied개를 가져왔습니다',
      if (already > 0) '이미 있는 $already개는 건너뛰었습니다${move ? ' (원본은 그대로)' : ''}',
      if (failed > 0) '실패 $failed개',
      if (notDeleted > 0) '원본 $notDeleted개는 지우지 못했습니다',
      if (stop) '멈춤',
    ].join(' · ')),
  ));
}

/// 가져오는 중 창: [job] 이 끝나면 스스로 닫힌다
class _ProgressDialog extends StatefulWidget {
  final Future<void> job;
  final ValueNotifier<(int, String)> progress;
  final int total;
  final VoidCallback onStop;
  const _ProgressDialog({required this.job, required this.progress, required this.total, required this.onStop});
  @override
  State<_ProgressDialog> createState() => _ProgressDialogState();
}

class _ProgressDialogState extends State<_ProgressDialog> {
  ModalRoute<dynamic>? _route;

  @override
  void initState() {
    super.initState();
    widget.job.whenComplete(_close);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _route = ModalRoute.of(context);
  }

  void _close() {
    // 화면이 한 번 그려진 뒤에 닫는다 (일이 아주 빨리 끝난 경우)
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final r = _route;
      if (!mounted || r == null) return;
      if (r.isCurrent) {
        Navigator.of(context).pop();
      } else if (r.isActive) {
        Navigator.of(context).removeRoute(r); // 다른 화면이 위에 떠 있어도 이 창만 없앤다
      }
    });
    WidgetsBinding.instance.ensureVisualUpdate();
  }

  @override
  Widget build(BuildContext context) => PopScope(
        canPop: false,
        child: AlertDialog(
          title: const Text('가져오는 중'),
          content: ValueListenableBuilder<(int, String)>(
            valueListenable: widget.progress,
            builder: (_, v, _) => Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
              LinearProgressIndicator(value: widget.total == 0 ? null : v.$1 / widget.total),
              const SizedBox(height: 8),
              Text('${v.$1} / ${widget.total}'),
              if (v.$2.isNotEmpty) Text(v.$2, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 12)),
            ]),
          ),
          actions: [TextButton(onPressed: widget.onStop, child: const Text('멈춤'))],
        ),
      );
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

/// ARARIFlex 폴더 안내: 어디에 있고, 가져오기 말고 어떻게 넣는지 (공유 · USB)
Future<void> showStoreFolderHelp(BuildContext context) {
  final state = context.read<AppState>();
  final dir = state.storeDir ?? '';
  return showDialog<void>(
    context: context,
    builder: (ctx) => AlertDialog(
      icon: const Icon(Icons.folder_special_outlined),
      title: const Text('ARARIFlex 폴더'),
      content: SingleChildScrollView(
        child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
          const Text('서재는 이 폴더 그 자체입니다. 이 폴더에 들어 있는 만화 · 책 · 영상이 앱에 보이고, 앱에서 삭제하면 이 폴더에서 지워집니다.'),
          const SizedBox(height: 6),
          SelectableText(_friendly(dir), style: const TextStyle(fontSize: 12)),
          const SizedBox(height: 14),
          const Text('PC 에서 USB 로 넣기', style: TextStyle(fontWeight: FontWeight.bold)),
          const Text('1. 기기를 PC 에 연결하고 알림에서 "파일 전송" 을 고릅니다.\n'
              '2. PC 에서 위 폴더를 열어 만화 · 책 · 영상 폴더에 파일을 복사합니다.\n'
              '3. 앱을 다시 열면 저절로 서재에 나타납니다. 앱을 켜 둔 채로 넣었다면 아래 단추를 누르세요.'),
          const SizedBox(height: 6),
          OutlinedButton.icon(
            onPressed: () async {
              Navigator.pop(ctx);
              final before = state.rawItems.length;
              await state.rescanWhenFree();
              if (!context.mounted) return;
              final n = state.rawItems.length - before;
              ScaffoldMessenger.of(context)
                  .showSnackBar(SnackBar(content: Text(n > 0 ? '새 파일 $n개를 서재에 넣었습니다' : '새로 넣은 파일이 없습니다')));
            },
            icon: const Icon(Icons.refresh),
            label: const Text('방금 넣은 파일 불러오기'),
          ),
          const SizedBox(height: 14),
          const Text('다른 앱에서 공유로 넣기', style: TextStyle(fontWeight: FontWeight.bold)),
          const Text('파일 관리자 · 브라우저 · 메신저에서 파일을 공유 › ARARIFlex 를 고르면 바로 들어옵니다.'),
          const SizedBox(height: 14),
          const Text('앱을 지우면 이 폴더의 파일도 함께 지워집니다. 남기려면 지울 때 나오는 "앱 데이터 보관" 을 고르세요.', style: TextStyle(fontSize: 12)),
        ]),
      ),
      actions: [TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('닫기'))],
    ),
  );
}

/// /storage/emulated/0/Android/data/... → 내장 저장공간 › Android › data › ...
String _friendly(String dir) {
  const root = '/storage/emulated/0/';
  if (dir.startsWith(root)) return '내장 저장공간 › ${dir.substring(root.length).split('/').join(' › ')}';
  // /storage/1234-5678/만화 → SD 카드 › 만화
  final m = RegExp(r'^/storage/[^/]+/(.*)$').firstMatch(dir);
  if (m != null) return 'SD 카드 › ${m.group(1)!.split('/').join(' › ')}';
  return dir;
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
            Text('"가져오기" 는 파일을 앱 폴더에 모으고, "폴더 연결" 은 내 폴더를 그 자리에서 그대로 봅니다. 시리즈별로 자동으로 묶입니다.',
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
            SizedBox(
              width: double.infinity,
              child: OutlinedButton.icon(
                style: OutlinedButton.styleFrom(padding: const EdgeInsets.symmetric(vertical: 14)),
                onPressed: () => linkFolderFlow(context),
                icon: const Icon(Icons.add_link),
                label: const Text('내 폴더 · SD 카드 연결 (복사 없이)'),
              ),
            ),
            const SizedBox(height: 8),
            TextButton(onPressed: () => showStoreFolderHelp(context), child: const Text('다른 방법 (공유 · PC 에서 USB 로)')),
            TextButton.icon(onPressed: () => showAppGuide(context), icon: const Icon(Icons.help_outline, size: 18), label: const Text('사용법 안내 보기')),
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
