import 'dart:io';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../app_state.dart';

import '../../models/media_item.dart';
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
  await Navigator.push(context, MaterialPageRoute(builder: (_) => page));
}

/// 항목에 맞는 뷰어 화면 (없으면 null = 시스템 앱)
Widget? viewerFor(MediaItem item, List<MediaItem>? siblings) {
  switch (item.kind) {
    case MediaKind.book:
      return switch (item.extension) {
        '.txt' || '.epub' => TextReaderPage(item: item),
        '.pdf' => PdfReaderPage(item: item),
        _ => null,
      };
    case MediaKind.comic:
      return switch (item.extension) {
        '.cbz' || '.zip' => ComicReaderPage(item: item),
        '.pdf' => PdfReaderPage(item: item),
        _ => null, // CBR/RAR/7Z 는 아직 시스템 앱으로
      };
    case MediaKind.image:
      final list = (siblings ?? [item]).where((e) => e.kind == MediaKind.image).toList();
      return ImageViewerPage(images: list, initialIndex: list.indexOf(item).clamp(0, list.length - 1));
    case MediaKind.video:
      final list = (siblings ?? [item]).where((e) => e.kind == MediaKind.video).toList();
      return VideoPlayerPage(playlist: list, initialIndex: list.indexOf(item).clamp(0, list.length - 1));
  }
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
      onPressed: () {
        final page = viewerFor(next, null);
        if (page == null) {
          openWithSystem(next.path);
          return;
        }
        Navigator.pushReplacement(context, MaterialPageRoute(builder: (_) => page));
      },
    );
  }
}
