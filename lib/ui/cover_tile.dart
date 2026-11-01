import 'dart:io';

import 'package:flutter/material.dart';

import '../models/media_item.dart';

class CoverTile extends StatelessWidget {
  final MediaItem item;
  final VoidCallback onTap;
  final VoidCallback onInfo;
  const CoverTile({super.key, required this.item, required this.onTap, required this.onInfo});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return InkWell(
      borderRadius: BorderRadius.circular(8),
      onTap: onTap,
      onLongPress: onInfo, // 휴대폰: 길게 누르면 정보
      onSecondaryTap: onInfo, // PC: 오른쪽 클릭하면 정보
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Expanded(
          child: Stack(fit: StackFit.expand, children: [
            ClipRRect(
              borderRadius: BorderRadius.circular(8),
              child: CoverImage(item: item),
            ),
            Positioned(
              left: 6,
              top: 6,
              child: _Badge(item.extension.replaceFirst('.', '').toUpperCase(), scheme.primaryContainer),
            ),
            if (item.favorite)
              const Positioned(right: 6, top: 6, child: Icon(Icons.favorite, color: Colors.redAccent, size: 20)),
            if (item.progress > 0)
              Positioned(
                left: 0,
                right: 0,
                bottom: 0,
                child: LinearProgressIndicator(value: item.progress, minHeight: 4),
              ),
            Positioned(
              right: 2,
              bottom: 6,
              child: IconButton.filledTonal(
                visualDensity: VisualDensity.compact,
                iconSize: 18,
                tooltip: '정보 / 편집',
                icon: const Icon(Icons.info_outline),
                onPressed: onInfo,
              ),
            ),
            if (item.missing)
              Positioned(left: 6, bottom: 6, child: _Badge('원본 없음', scheme.errorContainer)),
          ]),
        ),
        const SizedBox(height: 6),
        Text(item.title, maxLines: 2, overflow: TextOverflow.ellipsis, style: Theme.of(context).textTheme.bodyMedium),
        if (item.author != null)
          Text(item.author!, maxLines: 1, overflow: TextOverflow.ellipsis, style: Theme.of(context).textTheme.bodySmall),
      ]),
    );
  }
}

class _Badge extends StatelessWidget {
  final String text;
  final Color color;
  const _Badge(this.text, this.color);

  @override
  Widget build(BuildContext context) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
        decoration: BoxDecoration(color: color.withValues(alpha: 0.9), borderRadius: BorderRadius.circular(4)),
        child: Text(text, style: const TextStyle(fontSize: 10, fontWeight: FontWeight.w600)),
      );
}

/// 커버 이미지 (없으면 종류 아이콘 + 제목으로 대체 커버)
class CoverImage extends StatelessWidget {
  final MediaItem item;
  final BoxFit fit;
  const CoverImage({super.key, required this.item, this.fit = BoxFit.cover});

  @override
  Widget build(BuildContext context) {
    final path = item.coverPath;
    if (path != null) {
      final dpr = MediaQuery.devicePixelRatioOf(context);
      return Image.file(
        File(path),
        fit: fit,
        cacheWidth: (400 * dpr).round(), // 큰 원본 이미지도 메모리 절약
        errorBuilder: (_, _, _) => _placeholder(context),
      );
    }
    return _placeholder(context);
  }

  Widget _placeholder(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final icon = switch (item.kind) {
      MediaKind.book => Icons.menu_book,
      MediaKind.comic => Icons.auto_stories,
      MediaKind.image => Icons.image,
      MediaKind.video => Icons.movie,
    };
    return Container(
      color: scheme.surfaceContainerHighest,
      padding: const EdgeInsets.all(12),
      child: Column(mainAxisAlignment: MainAxisAlignment.center, children: [
        Icon(icon, size: 40, color: scheme.onSurfaceVariant),
        const SizedBox(height: 8),
        Text(item.title, textAlign: TextAlign.center, maxLines: 4, overflow: TextOverflow.ellipsis),
      ]),
    );
  }
}
