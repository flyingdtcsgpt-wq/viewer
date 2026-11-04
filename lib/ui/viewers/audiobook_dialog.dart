import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../../services/audiobook.dart';
import '../../services/background_reading.dart';
import '../../services/storage_permission.dart';
import '../../services/text_document.dart';

/// 책을 장(차례)마다 나눈 오디오북 부분들. 차례가 없으면 약 2만 자씩
/// 돌려줌: (시작 블록, 부분)
List<(int, AudiobookPart)> audiobookParts(TextDocument doc) {
  final blocks = doc.blocks;
  bool has(int i) => !blocks[i].isImage && (blocks[i].text ?? '').trim().isNotEmpty;
  List<int> idsOf(int a, int z) => [for (var i = a; i < z; i++) if (has(i)) i];
  AudiobookPart partOf(String title, List<int> ids) => AudiobookPart(title, [for (final i in ids) blocks[i].text!.trim()], ids);
  final starts = <(int, String)>[];
  final seen = <int>{};
  for (final t in [...doc.toc]..sort((a, b) => a.block.compareTo(b.block))) {
    if (t.block >= 0 && t.block < blocks.length && seen.add(t.block)) starts.add((t.block, t.title));
  }
  final out = <(int, AudiobookPart)>[];
  if (starts.isEmpty) {
    var cur = <int>[];
    var n = 0;
    for (var i = 0; i < blocks.length; i++) {
      if (!has(i)) continue;
      cur.add(i);
      n += blocks[i].text!.trim().length;
      if (n >= 20000) {
        out.add((cur.first, partOf('${out.length + 1}부분', cur)));
        cur = [];
        n = 0;
      }
    }
    if (cur.isNotEmpty) out.add((cur.first, partOf('${out.length + 1}부분', cur)));
    return out;
  }
  if (starts.first.$1 > 0) {
    final pre = idsOf(0, starts.first.$1);
    if (pre.isNotEmpty) out.add((0, partOf('머리말', pre)));
  }
  for (var k = 0; k < starts.length; k++) {
    final (a, title) = starts[k];
    final z = k + 1 < starts.length ? starts[k + 1].$1 : blocks.length;
    final ids = idsOf(a, z);
    if (ids.isNotEmpty) out.add((a, partOf(title, ids)));
  }
  return out;
}

/// 기본 저장 위치: 음악 폴더 / ARARIFlex 오디오북 / 책 제목
Future<String> defaultAudiobookDir(String title) async {
  final name = AudiobookMaker.safeName(title).isEmpty ? '오디오북' : AudiobookMaker.safeName(title);
  String base;
  if (Platform.isWindows || Platform.isMacOS || Platform.isLinux) {
    final home = Platform.environment[Platform.isWindows ? 'USERPROFILE' : 'HOME'];
    base = home == null ? (await getApplicationDocumentsDirectory()).path : p.join(home, 'Music');
  } else if (Platform.isAndroid) {
    // 권한이 있으면 다른 음악 앱도 찾을 수 있는 곳, 없으면 앱 전용 폴더
    base = await hasAllFilesAccess() ? '/storage/emulated/0/Audiobooks' : ((await getExternalStorageDirectory()) ?? await getApplicationDocumentsDirectory()).path;
  } else {
    base = (await getApplicationDocumentsDirectory()).path; // iOS: 파일 앱 › ARARIFlex 에서 보임
  }
  return p.join(base, 'ARARIFlex 오디오북', name);
}

String _dur(Duration d) {
  final h = d.inHours, m = d.inMinutes % 60;
  if (h > 0) return '$h시간 $m분';
  if (d.inMinutes > 0) return '${d.inMinutes}분';
  return '${d.inSeconds}초';
}

/// 오디오북으로 저장: 범위 · 형식 · 위치를 고르고 만든다
Future<void> showAudiobookExport(
  BuildContext context, {
  required String title,
  required TextDocument doc,
  required int currentBlock,
  required int rate,
  required List<(String, String, int)> Function(String paragraph, int block) plan,
}) async {
  final all = audiobookParts(doc);
  if (all.isEmpty) {
    ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('읽을 글이 없습니다')));
    return;
  }
  // 지금 읽는 곳이 들어 있는 부분
  var here = 0;
  for (var i = 0; i < all.length; i++) {
    if (all[i].$1 <= currentBlock) here = i;
  }
  var range = 0; // 0 전체, 1 지금 장부터, 2 지금 장만
  var compress = true;
  var single = false;
  var dir = await defaultAudiobookDir(title);
  if (!context.mounted) return;

  List<AudiobookPart> chosen() => switch (range) {
        1 => [for (final e in all.skip(here)) e.$2],
        2 => [all[here].$2],
        _ => [for (final e in all) e.$2],
      };
  // 같은 장은 늘 같은 번호(파일 이름)가 되게: 전체 목록에서의 순서를 쓴다
  int offset() => range == 0 ? 0 : here;

  final go = await showDialog<bool>(
    context: context,
    builder: (ctx) => StatefulBuilder(builder: (ctx, set) {
      final parts = chosen();
      final chars = parts.fold(0, (a, b) => a + b.chars);
      // 한국어 낭독은 보통 1분에 약 400자 (빠르기 반영)
      final minutes = chars / (400 * (1 + rate * 0.1).clamp(0.5, 2.0));
      return AlertDialog(
        icon: const Icon(Icons.library_music),
        title: const Text('오디오북으로 저장'),
        content: SizedBox(
          width: 480,
          child: SingleChildScrollView(
            child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
              const Text('지금 고른 음성으로 장마다 소리 파일을 만듭니다. 대사 · 속마음 · 인물별 목소리 설정도 그대로 씁니다. 인터넷 없이 이 기기에서 만듭니다.'),
              const SizedBox(height: 14),
              const Text('범위', style: TextStyle(fontWeight: FontWeight.bold)),
              const SizedBox(height: 6),
              Wrap(spacing: 8, runSpacing: 6, children: [
                for (final (v, l) in [(0, '책 전체 (${all.length}개)'), if (all.length > 1) (1, '지금 장부터 (${all.length - here}개)'), if (all.length > 1) (2, '지금 장만')])
                  ChoiceChip(label: Text(l), selected: range == v, onSelected: (_) => set(() => range = v)),
              ]),
              if (range == 2) Padding(padding: const EdgeInsets.only(top: 4), child: Text('「${all[here].$2.title}」', style: const TextStyle(fontSize: 12))),
              const SizedBox(height: 14),
              const Text('형식', style: TextStyle(fontWeight: FontWeight.bold)),
              const SizedBox(height: 6),
              Wrap(spacing: 8, runSpacing: 6, children: [
                ChoiceChip(label: const Text('M4A (작게 · 권장)'), selected: compress, onSelected: (_) => set(() => compress = true)),
                ChoiceChip(label: const Text('WAV (원음 · 약 4배 큼)'), selected: !compress, onSelected: (_) => set(() => compress = false)),
              ]),
              const SizedBox(height: 6),
              Wrap(spacing: 8, runSpacing: 6, children: [
                ChoiceChip(label: const Text('장마다 파일'), selected: !single, onSelected: (_) => set(() => single = false)),
                ChoiceChip(label: const Text('한 파일로 합치기'), selected: single, onSelected: (_) => set(() => single = true)),
              ]),
              const SizedBox(height: 14),
              const Text('저장 위치', style: TextStyle(fontWeight: FontWeight.bold)),
              const SizedBox(height: 4),
              Row(children: [
                Expanded(child: Text(dir, style: const TextStyle(fontSize: 12))),
                if (!Platform.isIOS)
                  TextButton(
                    onPressed: () async {
                      final d = await FilePicker.getDirectoryPath(dialogTitle: '오디오북을 저장할 폴더');
                      if (d != null) set(() => dir = p.join(d, p.basename(dir)));
                    },
                    child: const Text('바꾸기'),
                  ),
              ]),
              const SizedBox(height: 12),
              Text('${single ? 1 : parts.length}개 파일 · 듣는 시간 약 ${_dur(Duration(minutes: minutes.ceil()))} · ${(chars / 1000).toStringAsFixed(chars < 10000 ? 1 : 0)}천 자',
                  style: const TextStyle(fontWeight: FontWeight.w600)),
              const SizedBox(height: 4),
              const Text('긴 책은 오래 걸립니다. 만드는 동안 이 창을 열어 두세요. 멈춰도 다 만든 장은 남고, 다시 하면 이어서 만듭니다.',
                  style: TextStyle(fontSize: 12)),
            ]),
          ),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('취소')),
          FilledButton.icon(onPressed: () => Navigator.pop(ctx, true), icon: const Icon(Icons.play_arrow), label: const Text('만들기')),
        ],
      );
    }),
  );
  if (go != true || !context.mounted) return;

  // 고른 범위의 앞쪽 부분을 빈 자리로 두면 번호가 전체 목록과 맞는다 (이어 만들기 · 같은 이름)
  final skip = offset();
  final maker = AudiobookMaker();
  final progress = ValueNotifier<AudiobookProgress?>(null);
  final parts = chosen();
  AudiobookResult? result;
  Object? error;
  BackgroundReading.start('오디오북 만드는 중 · $title'); // 안드로이드: 화면을 꺼도 계속
  final job = maker
      .make(
        parts: [for (var i = 0; i < skip; i++) AudiobookPart(all[i].$2.title, const []), ...parts],
        outDir: dir,
        bookTitle: title,
        compress: compress,
        single: single,
        plan: plan,
        onProgress: (pr) => progress.value = pr,
      )
      .then<void>((r) {
        result = r;
      }, onError: (Object e) {
        error = e;
      }).whenComplete(BackgroundReading.stop);

  // 다 되면 진행 창을 한 번만 닫는다 (창이 다시 그려져도 두 번 닫지 않게)
  var finished = false, popped = false;
  BuildContext? dctx;
  void close() {
    final c = dctx;
    if (popped || c == null || !c.mounted) return;
    popped = true;
    Navigator.of(c).pop();
  }

  job.whenComplete(() {
    finished = true;
    close();
  });

  await showDialog<void>(
    context: context,
    barrierDismissible: false,
    builder: (ctx) {
      dctx = ctx;
      if (finished) WidgetsBinding.instance.addPostFrameCallback((_) => close());
      return PopScope(
        canPop: false,
        child: AlertDialog(
          title: const Text('오디오북 만드는 중'),
          content: SizedBox(
            width: 440,
            child: ValueListenableBuilder<AudiobookProgress?>(
              valueListenable: progress,
              builder: (_, pr, _) {
                final eta = pr?.eta;
                return Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text(pr == null ? '준비 중…' : '${pr.part + 1 - skip} / ${pr.parts - skip} · ${pr.title}', maxLines: 2, overflow: TextOverflow.ellipsis),
                  const SizedBox(height: 10),
                  LinearProgressIndicator(value: pr?.fraction),
                  const SizedBox(height: 8),
                  Text(
                    [
                      if (pr != null) '${(pr.fraction * 100).toStringAsFixed(1)}%',
                      if (pr != null) '만든 소리 ${_dur(pr.made)}',
                      if (eta != null) '남은 시간 약 ${_dur(eta)}',
                    ].join(' · '),
                    style: const TextStyle(fontSize: 12),
                  ),
                ]);
              },
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => maker.cancel(),
              child: const Text('멈춤'),
            ),
          ],
        ),
      );
    },
  );
  await job;
  progress.dispose();
  if (!context.mounted) return;
  final r = result;
  if (r == null) {
    showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('오디오북을 만들지 못했습니다'),
        content: Text('$error'),
        actions: [TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('확인'))],
      ),
    );
    return;
  }
  final made = r.files.length;
  showDialog<void>(
    context: context,
    builder: (ctx) => AlertDialog(
      icon: Icon(r.cancelled ? Icons.pause_circle : Icons.check_circle),
      title: Text(r.cancelled ? '멈췄습니다' : '오디오북을 만들었습니다'),
      content: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text('파일 $made개${r.length > Duration.zero ? ' · 이번에 만든 소리 ${_dur(r.length)}' : ''}'),
        if (r.skippedParts > 0) Text('이미 있던 ${r.skippedParts}개는 건너뛰었습니다'),
        if (r.failedPieces > 0) Text('소리로 바꾸지 못한 조각 ${r.failedPieces}개는 빠졌습니다', style: const TextStyle(color: Colors.orange)),
        if (compress && !r.compressed && made > 0)
          const Text('이 기기에서 M4A 로 줄이지 못해 WAV 로 저장했습니다', style: TextStyle(color: Colors.orange)),
        if (r.cancelled) const Text('다시 「만들기」를 누르면 이어서 만듭니다.'),
        const SizedBox(height: 8),
        SelectableText(dir, style: const TextStyle(fontSize: 12)),
      ]),
      actions: [
        if (Platform.isWindows || Platform.isMacOS)
          TextButton(
            onPressed: () => Process.run(Platform.isWindows ? 'explorer.exe' : 'open', [dir]),
            child: const Text('폴더 열기'),
          ),
        FilledButton(onPressed: () => Navigator.pop(ctx), child: const Text('확인')),
      ],
    ),
  );
}
