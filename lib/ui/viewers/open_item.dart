import 'dart:io';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../app_state.dart';

import '../../models/media_item.dart';
import '../../services/ext_archive.dart';
import '../../services/settings.dart';
import '../cover_tile.dart';
import 'epub_original_page.dart';
import '../detail_page.dart';
import 'comic_reader_page.dart';
import 'image_viewer_page.dart';
import 'pdf_reader_page.dart';
import 'text_reader_page.dart';
import 'video_player_page.dart';

/// 항목 종류에 맞는 내장 뷰어로 연다. 지원하지 않는 형식은 시스템 기본 앱으로.
/// [siblings]: 현재 목록 (그림/영상은 앞뒤로 넘겨 볼 수 있게)
Future<void> openItem(BuildContext context, MediaItem item, {List<MediaItem>? siblings}) async {
  if (!await File(item.path).exists()) {
    if (context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('원본 파일을 찾을 수 없습니다: ${item.path}')));
    }
    return;
  }
  if (!context.mounted) return;

  final page = viewerFor(item, siblings);
  if (page == null) {
    await openWithSystem(item.path);
    return;
  }
  await context.read<AppState>().beginView(item); // 열람 기록 시작
  if (!context.mounted) return;
  await Navigator.push(context, MaterialPageRoute(builder: (_) => page));
}

/// 항목에 맞는 뷰어 화면 (없으면 null = 시스템 앱)
Widget? viewerFor(MediaItem item, List<MediaItem>? siblings) {
  switch (item.kind) {
    case MediaKind.book:
      return switch (item.extension) {
        '.epub' when Platform.isWindows && Settings.instance.epubOriginal => EpubOriginalPage(item: item),
        '.txt' || '.epub' => TextReaderPage(item: item),
        '.pdf' => PdfReaderPage(item: item),
        _ => null,
      };
    case MediaKind.comic:
      return switch (item.extension) {
        '.cbz' || '.zip' => ComicReaderPage(item: item),
        '.cbr' || '.rar' || '.cb7' || '.7z' when ExtArchive.supported => ComicReaderPage(item: item),
        '.pdf' => PdfReaderPage(item: item),
        _ => null, // 그 밖의 형식은 시스템 앱으로
      };
    case MediaKind.image:
      final list = (siblings ?? [item]).where((e) => e.kind == MediaKind.image).toList();
      return ImageViewerPage(images: list, initialIndex: list.indexOf(item).clamp(0, list.length - 1));
    case MediaKind.video:
      final list = (siblings ?? [item]).where((e) => e.kind == MediaKind.video).toList();
      return VideoPlayerPage(playlist: list, initialIndex: list.indexOf(item).clamp(0, list.length - 1));
  }
}

/// 다음 권 열기: 지금 뷰어를 다음 권 뷰어로 바꾼다 (뒤로 가면 목록으로)
void openNextVolume(BuildContext context, MediaItem next) {
  final page = viewerFor(next, null);
  if (page == null) {
    openWithSystem(next.path);
    return;
  }
  context.read<AppState>().beginView(next);
  Navigator.pushReplacement(
    context,
    PageRouteBuilder(
      pageBuilder: (_, _, _) => page,
      transitionDuration: const Duration(milliseconds: 350),
      // 다음 권은 부드럽게 넘어가게 (밀려 들어오기)
      transitionsBuilder: (_, a, _, child) => SlideTransition(
        position: Tween(begin: const Offset(0.25, 0), end: Offset.zero).animate(CurvedAnimation(parent: a, curve: Curves.easeOutCubic)),
        child: FadeTransition(opacity: a, child: child),
      ),
    ),
  );
}

/// 같은 묶음의 다음 권으로 (지금 뷰어를 닫고 바로 연다)
class NextVolumeButton extends StatelessWidget {
  final MediaItem item;
  const NextVolumeButton({super.key, required this.item});

  @override
  Widget build(BuildContext context) {
    final next = context.read<AppState>().nextVolume(item);
    if (next == null) return const SizedBox();
    return IconButton(
      tooltip: '다음 권: ${next.volumeLabel ?? next.title}',
      icon: const Icon(Icons.skip_next),
      onPressed: () => openNextVolume(context, next),
    );
  }
}

/// 권 끝 안내: 다음 권이 있으면 표지와 "다음 권 보기", 없으면 "다음 권이 없습니다"
/// [onStay]: 이 권에 머물기 (카드 닫기). 없으면 그 단추를 숨김 (글 끝에 붙는 카드)
class VolumeEndCard extends StatelessWidget {
  final MediaItem item;
  final VoidCallback? onStay;
  const VolumeEndCard({super.key, required this.item, this.onStay});

  @override
  Widget build(BuildContext context) {
    final app = context.read<AppState>();
    final next = app.nextVolume(item);
    final series = app.seriesById(item.seriesId);
    final owned = series == null ? 0 : app.volumesOf(series.id!).length;
    final total = series?.total;
    const white = TextStyle(color: Colors.white);
    return ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: 420),
      child: Material(
        color: const Color(0xF0202020),
        borderRadius: BorderRadius.circular(16),
        elevation: 12,
        child: Padding(
          padding: const EdgeInsets.all(20),
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            const Icon(Icons.done_all, color: Colors.white70, size: 30),
            const SizedBox(height: 6),
            Text('${item.volumeLabel ?? item.title} 끝', style: white.copyWith(fontSize: 18, fontWeight: FontWeight.w800), textAlign: TextAlign.center),
            const SizedBox(height: 16),
            if (next != null) ...[
              InkWell(
                borderRadius: BorderRadius.circular(10),
                onTap: () => openNextVolume(context, next),
                child: Row(mainAxisSize: MainAxisSize.min, children: [
                  SizedBox(width: 72, height: 104, child: ClipRRect(borderRadius: BorderRadius.circular(6), child: CoverImage(item: next))),
                  const SizedBox(width: 14),
                  Flexible(
                    child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                      const Text('다음 권', style: TextStyle(color: Colors.white54, fontSize: 12)),
                      Text(next.volumeLabel ?? next.title, style: white.copyWith(fontSize: 16, fontWeight: FontWeight.w700)),
                      Text(next.title, maxLines: 2, overflow: TextOverflow.ellipsis, style: const TextStyle(color: Colors.white70, fontSize: 12)),
                      if (next.progress > 0 && next.progress < 0.98)
                        Text('${(next.progress * 100).round()}% 읽음', style: const TextStyle(color: Colors.white54, fontSize: 12)),
                    ]),
                  ),
                ]),
              ),
              const SizedBox(height: 16),
              FilledButton.icon(
                autofocus: true,
                style: FilledButton.styleFrom(padding: const EdgeInsets.symmetric(horizontal: 28, vertical: 14)),
                onPressed: () => openNextVolume(context, next),
                icon: const Icon(Icons.skip_next),
                label: const Text('다음 권 보기'),
              ),
            ] else ...[
              Text('다음 권이 없습니다', style: white.copyWith(fontSize: 16, fontWeight: FontWeight.w700)),
              if (total != null && owned < total)
                Padding(
                  padding: const EdgeInsets.only(top: 4),
                  child: Text('전체 $total권 중 $owned권을 가지고 있습니다', style: const TextStyle(color: Colors.white54, fontSize: 12)),
                ),
            ],
            const SizedBox(height: 10),
            Wrap(alignment: WrapAlignment.center, spacing: 8, children: [
              if (onStay != null) TextButton(onPressed: onStay, child: const Text('이 권 계속 보기')),
              TextButton(onPressed: () => Navigator.maybePop(context), child: const Text('목록으로')),
            ]),
          ]),
        ),
      ),
    );
  }
}
