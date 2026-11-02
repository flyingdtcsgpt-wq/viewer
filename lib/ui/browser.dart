import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../app_state.dart';
import '../models/entry.dart';
import '../models/media_item.dart';
import '../models/series.dart';
import '../services/settings.dart';
import 'batch_editor_page.dart';
import 'cover_tile.dart';
import 'detail_page.dart';
import 'landing_view.dart' show HoverZoom;
import 'series_widgets.dart';
import 'viewers/open_item.dart';

// =====================================================================
//  공통: 칸을 눌렀을 때 동작 (PC: 한 번 = 고르기, 두 번 = 열기 / 휴대폰: 한 번 = 열기)
// =====================================================================

void openEntry(BuildContext context, Entry e, List<MediaItem> siblings) {
  final state = context.read<AppState>();
  switch (e) {
    case SeriesEntry s:
      state.enterSeries(s.series.id);
    case ItemEntry i:
      openItem(context, i.item, siblings: siblings);
  }
}

void tapEntry(BuildContext context, Entry e, List<MediaItem> siblings, {required bool desktop}) {
  final state = context.read<AppState>();
  final multi = HardwareKeyboard.instance.isControlPressed || HardwareKeyboard.instance.isMetaPressed;
  if (state.isAdmin && (multi || (!desktop && state.selecting))) {
    state.toggleSelect(e);
    return;
  }
  if (desktop) {
    state.focus(e);
  } else {
    openEntry(context, e, siblings);
  }
}

String fileSize(int bytes) {
  if (bytes >= 1 << 30) return '${(bytes / (1 << 30)).toStringAsFixed(1)} GB';
  if (bytes >= 1 << 20) return '${(bytes / (1 << 20)).toStringAsFixed(1)} MB';
  if (bytes >= 1 << 10) return '${(bytes / (1 << 10)).toStringAsFixed(0)} KB';
  return '$bytes B';
}

String shortDate(DateTime t) =>
    '${t.year}. ${t.month.toString().padLeft(2, '0')}. ${t.day.toString().padLeft(2, '0')}.';

String ratingText(int r) => (r / 1).toStringAsFixed(r == 10 ? 0 : 1);

// =====================================================================
//  표지 카드 (격자 보기): 표지 위에 제목, 배지
// =====================================================================
class PosterCard extends StatelessWidget {
  final Entry entry;
  final bool selected;
  final bool hidden;
  final VoidCallback onTap;
  final VoidCallback onDoubleTap;
  final VoidCallback onLongPress;
  final void Function(Offset globalPosition) onContext;
  const PosterCard({
    super.key,
    required this.entry,
    required this.selected,
    required this.hidden,
    required this.onTap,
    required this.onDoubleTap,
    required this.onLongPress,
    required this.onContext,
  });

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final dpr = MediaQuery.devicePixelRatioOf(context);
    final isSeries = entry is SeriesEntry;
    String title;
    String? cover;
    String? topRight;
    int rating = 0;
    double progress = 0;
    switch (entry) {
      case SeriesEntry s:
        title = s.series.title;
        cover = s.series.coverPath ?? s.stats.coverPath;
        topRight = s.stats.childSeries > 0 && s.stats.direct == 0
            ? '${s.stats.allItems}${s.stats.unit}'
            : '${s.stats.direct}${s.series.total != null ? '/${s.series.total}' : ''}${s.stats.unit}';
        progress = s.stats.allItems == 0 ? 0 : s.stats.finished / s.stats.allItems;
      case ItemEntry i:
        title = i.item.title;
        cover = i.item.coverPath;
        topRight = i.item.pages != null ? '${i.item.pages}p' : i.item.volumeLabel;
        rating = i.item.rating;
        progress = i.item.progress;
    }

    Widget pill(Widget child, {Color? color}) => Container(
          padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
          decoration: BoxDecoration(color: color ?? Colors.black.withValues(alpha: 0.72), borderRadius: BorderRadius.circular(6)),
          child: DefaultTextStyle(
            style: const TextStyle(color: Colors.white, fontSize: 11, fontWeight: FontWeight.w700),
            child: IconTheme(data: const IconThemeData(color: Colors.white, size: 12), child: child),
          ),
        );

    final card = Container(
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(6),
        border: Border.all(color: selected ? scheme.primary : Colors.transparent, width: 3),
        boxShadow: const [BoxShadow(color: Colors.black54, blurRadius: 6, offset: Offset(0, 3))],
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(4),
        child: Stack(fit: StackFit.expand, children: [
          // 묶음은 뒤에 한 장 더 겹친 느낌
          Container(color: scheme.surfaceContainerHigh),
          if (cover != null)
            Image.file(File(cover), fit: BoxFit.cover, cacheWidth: (360 * dpr).round(), errorBuilder: (_, _, _) => _fallback(context))
          else
            _fallback(context),
          // 아래 그라데이션 + 제목
          const DecoratedBox(
            decoration: BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.topCenter,
                end: Alignment.bottomCenter,
                colors: [Colors.transparent, Colors.transparent, Colors.black87],
                stops: [0, 0.6, 1],
              ),
            ),
          ),
          Positioned(
            left: 8,
            right: 8,
            bottom: progress > 0 ? 10 : 8,
            child: Text(
              title,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              textAlign: TextAlign.center,
              style: const TextStyle(
                color: Colors.white,
                fontWeight: FontWeight.w800,
                fontSize: 13,
                shadows: [Shadow(blurRadius: 4, color: Colors.black)],
              ),
            ),
          ),
          // 왼쪽 위: 묶음 아이콘 / 평점
          Positioned(
            left: 6,
            top: 6,
            child: Row(mainAxisSize: MainAxisSize.min, children: [
              if (isSeries) pill(const Icon(Icons.folder, color: Color(0xFFFFC107), size: 14), color: Colors.black54),
              if (rating > 0)
                pill(Row(mainAxisSize: MainAxisSize.min, children: [
                  const Icon(Icons.star, color: Color(0xFFFFC107)),
                  const SizedBox(width: 2),
                  Text(ratingText(rating)),
                ])),
              if (entry case SeriesEntry s when s.series.status != SeriesStatus.unknown) ...[
                const SizedBox(width: 4),
                pill(Text(statusLabel(s.series.status)),
                    color: s.series.status == SeriesStatus.completed ? Colors.green.shade700 : Colors.orange.shade800),
              ],
            ]),
          ),
          // 오른쪽 위: 쪽수 / 권수
          if (topRight != null) Positioned(right: 6, top: 6, child: pill(Text(topRight))),
          if (hidden) Positioned(left: 6, top: 30, child: pill(const Text('숨김'))),
          // 종류가 섞인 묶음: 책 · 그림 · 영상 개수를 따로
          if (entry case SeriesEntry s when s.stats.kinds.length > 1)
            Positioned(
              left: 6,
              right: 6,
              bottom: progress > 0 ? 44 : 40,
              child: Wrap(spacing: 4, runSpacing: 4, children: [
                for (final k in s.stats.kinds.entries)
                  pill(Row(mainAxisSize: MainAxisSize.min, children: [
                    Icon(switch (k.key) {
                      MediaKind.book => Icons.menu_book,
                      MediaKind.comic => Icons.auto_stories,
                      MediaKind.image => Icons.image,
                      MediaKind.video => Icons.movie,
                    }),
                    Text(' ${k.value}'),
                  ])),
              ]),
            ),
          if (entry case ItemEntry i when i.item.favorite)
            const Positioned(right: 6, top: 30, child: Icon(Icons.favorite, color: Colors.redAccent, size: 18)),
          if (entry case ItemEntry i when i.item.missing)
            Positioned(left: 6, bottom: 40, child: pill(const Text('원본 없음'), color: scheme.error)),
          if (progress > 0)
            Positioned(
              left: 0,
              right: 0,
              bottom: 0,
              child: LinearProgressIndicator(
                value: progress.clamp(0.0, 1.0),
                minHeight: 4,
                backgroundColor: Colors.white24,
                color: scheme.primary,
              ),
            ),
        ]),
      ),
    );

    return GestureDetector(
      onTap: onTap,
      onDoubleTap: onDoubleTap,
      onLongPress: onLongPress,
      onSecondaryTapUp: (d) => onContext(d.globalPosition),
      child: MouseRegion(cursor: SystemMouseCursors.click, child: HoverZoom(child: card)),
    );
  }

  Widget _fallback(BuildContext context) {
    final icon = switch (entry) {
      SeriesEntry _ => Icons.collections_bookmark,
      ItemEntry i => switch (i.item.kind) {
          MediaKind.book => Icons.menu_book,
          MediaKind.comic => Icons.auto_stories,
          MediaKind.image => Icons.image,
          MediaKind.video => Icons.movie,
        },
    };
    return Center(child: Icon(icon, size: 48, color: Colors.white38));
  }
}

// =====================================================================
//  격자 / 표 / 카드 목록
// =====================================================================
class EntryBrowser extends StatelessWidget {
  final bool desktop;
  const EntryBrowser({super.key, required this.desktop});

  @override
  Widget build(BuildContext context) {
    final state = context.watch<AppState>();
    final s = context.watch<Settings>();
    final entries = state.entries;
    final siblings = entries.whereType<ItemEntry>().map((e) => e.item).toList();

    if (entries.isEmpty) {
      return Center(
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          const Icon(Icons.library_books_outlined, size: 64, color: Colors.white38),
          const SizedBox(height: 12),
          Text(state.collection != Collection.none
              ? '${collectionLabel(state.collection)}: 항목이 없습니다'
              : state.currentSeriesId != null
                  ? '이 묶음은 비어 있습니다.'
                  : (state.isAdmin ? '항목이 없습니다. "폴더 추가"로 등록하세요.' : '볼 수 있는 항목이 없습니다.')),
        ]),
      );
    }

    final mode = desktop ? ViewMode.values[s.viewMode.clamp(0, 2)] : ViewMode.grid;
    void tap(Entry e) => tapEntry(context, e, siblings, desktop: desktop);
    void open(Entry e) => openEntry(context, e, siblings);
    void long(Entry e) {
      if (state.isAdmin) {
        state.toggleSelect(e);
      } else if (e is ItemEntry) {
        Navigator.push(context, MaterialPageRoute(builder: (_) => DetailPage(item: e.item)));
      } else {
        open(e);
      }
    }

    void menu(Entry e, Offset at) {
      if (!state.selected.contains(e.key)) state.focus(e);
      showEntryMenu(context, e, at, siblings);
    }

    switch (mode) {
      case ViewMode.grid:
        final width = MediaQuery.sizeOf(context).width;
        final size = desktop ? s.coverSize : (width - 24) / (width < 400 ? 2 : 3);
        return GridView.builder(
          padding: const EdgeInsets.all(14),
          gridDelegate: SliverGridDelegateWithMaxCrossAxisExtent(
            maxCrossAxisExtent: size,
            childAspectRatio: 0.69,
            crossAxisSpacing: 14,
            mainAxisSpacing: 16,
          ),
          itemCount: entries.length,
          itemBuilder: (_, i) {
            final e = entries[i];
            return PosterCard(
              key: ValueKey(e.key),
              entry: e,
              selected: state.selected.contains(e.key),
              hidden: switch (e) {
                SeriesEntry x => state.isHiddenSeries(x.series),
                ItemEntry x => state.isHiddenItem(x.item),
              },
              onTap: () => tap(e),
              onDoubleTap: () => open(e),
              onLongPress: () => long(e),
              onContext: (at) => menu(e, at),
            );
          },
        );
      case ViewMode.table:
        return _Table(entries: entries, onTap: tap, onOpen: open, onMenu: menu);
      case ViewMode.cards:
        return GridView.builder(
          padding: const EdgeInsets.all(14),
          gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
            maxCrossAxisExtent: 680,
            mainAxisExtent: 186,
            crossAxisSpacing: 14,
            mainAxisSpacing: 14,
          ),
          itemCount: entries.length,
          itemBuilder: (_, i) => _InfoCard(
            entry: entries[i],
            selected: state.selected.contains(entries[i].key),
            onTap: () => tap(entries[i]),
            onOpen: () => open(entries[i]),
            onMenu: (at) => menu(entries[i], at),
          ),
        );
    }
  }
}

class _InfoCard extends StatelessWidget {
  final Entry entry;
  final bool selected;
  final VoidCallback onTap, onOpen;
  final void Function(Offset) onMenu;
  const _InfoCard({required this.entry, required this.selected, required this.onTap, required this.onOpen, required this.onMenu});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final text = Theme.of(context).textTheme;
    final state = context.read<AppState>();
    late String title, meta, line2;
    String? desc, cover;
    switch (entry) {
      case SeriesEntry s:
        title = s.series.title;
        meta = [s.series.author, if (s.series.status != SeriesStatus.unknown) statusLabel(s.series.status)].whereType<String>().join(' · ');
        line2 = seriesSummary(s.series, s.stats);
        desc = s.series.description;
        cover = s.series.coverPath ?? s.stats.coverPath;
      case ItemEntry i:
        final e = i.item;
        title = e.volumeLabel != null && e.seriesId != null && !e.title.contains(RegExp(r'\d')) ? '${e.title} ${e.volumeLabel}' : e.title;
        meta = [e.author, e.publisher, if (e.tags.isNotEmpty) e.tags.take(3).join(', ')].whereType<String>().where((x) => x.isNotEmpty).join(' · ');
        line2 = [if (e.pages != null) '${e.pages}p', '★ ${ratingText(e.rating)}', if (e.progress > 0) '${(e.progress * 100).round()}% 읽음']
            .join(' · ');
        desc = e.description;
        cover = e.coverPath;
    }
    return GestureDetector(
      onTap: onTap,
      onDoubleTap: onOpen,
      onSecondaryTapUp: (d) => onMenu(d.globalPosition),
      child: Container(
        padding: const EdgeInsets.all(10),
        decoration: BoxDecoration(
          color: selected ? scheme.primary.withValues(alpha: 0.16) : scheme.surfaceContainer,
          borderRadius: BorderRadius.circular(8),
          border: Border.all(color: selected ? scheme.primary : Colors.transparent, width: 2),
        ),
        child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          AspectRatio(
            aspectRatio: 0.69,
            child: ClipRRect(
              borderRadius: BorderRadius.circular(4),
              child: cover == null
                  ? Container(color: scheme.surfaceContainerHigh, child: const Icon(Icons.book))
                  : Image.file(File(cover), fit: BoxFit.cover, cacheWidth: 300, errorBuilder: (_, _, _) => const Icon(Icons.book)),
            ),
          ),
          const SizedBox(width: 14),
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Row(children: [
                if (entry is SeriesEntry) const Padding(padding: EdgeInsets.only(right: 6), child: Icon(Icons.folder, color: Color(0xFFFFC107), size: 18)),
                Expanded(child: Text(title, maxLines: 1, overflow: TextOverflow.ellipsis, style: text.titleMedium?.copyWith(fontWeight: FontWeight.w800))),
                if (entry case ItemEntry i when state.isHiddenItem(i.item)) const Text(' 숨김', style: TextStyle(color: Colors.grey)),
              ]),
              const SizedBox(height: 4),
              if (meta.isNotEmpty) Text(meta, maxLines: 1, overflow: TextOverflow.ellipsis, style: text.bodySmall),
              Text(line2, style: text.bodySmall?.copyWith(color: scheme.onSurface.withValues(alpha: 0.7))),
              const SizedBox(height: 8),
              if (desc != null && desc.isNotEmpty)
                Expanded(child: Text(desc, maxLines: 4, overflow: TextOverflow.ellipsis, style: text.bodySmall?.copyWith(height: 1.5))),
            ]),
          ),
        ]),
      ),
    );
  }
}

/// 표 보기: 진행률 · 표지 · 제목 · 종류 · 쪽 · 평점 · 용량 · 추가일 · 시리즈
class _Table extends StatelessWidget {
  final List<Entry> entries;
  final void Function(Entry) onTap, onOpen;
  final void Function(Entry, Offset) onMenu;
  const _Table({required this.entries, required this.onTap, required this.onOpen, required this.onMenu});

  @override
  Widget build(BuildContext context) {
    final state = context.watch<AppState>();
    final scheme = Theme.of(context).colorScheme;
    final small = Theme.of(context).textTheme.bodySmall;

    Widget head(String label, {int flex = 0, double? width, SortBy? sort}) {
      final active = sort != null && state.sortBy == sort;
      final child = InkWell(
        onTap: sort == null ? null : () => state.setSort(sort),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 10),
          child: Row(children: [
            Flexible(
              child: Text(label,
                  overflow: TextOverflow.ellipsis,
                  style: small?.copyWith(fontWeight: FontWeight.w700, color: active ? scheme.primary : null)),
            ),
            if (active) Icon(Icons.arrow_drop_down, size: 16, color: scheme.primary),
          ]),
        ),
      );
      return width != null ? SizedBox(width: width, child: child) : Expanded(flex: flex, child: child);
    }

    Widget cell(Widget child, {int flex = 0, double? width}) {
      final c = Padding(padding: const EdgeInsets.symmetric(horizontal: 8), child: child);
      return width != null ? SizedBox(width: width, child: c) : Expanded(flex: flex, child: c);
    }

    return Column(children: [
      Container(
        color: scheme.surfaceContainer,
        child: Row(children: [
          head('진행', width: 70),
          head('표지', width: 56),
          head('제목', flex: 5, sort: SortBy.title),
          head('종류', width: 64),
          head('쪽', width: 56),
          head('평점', width: 64, sort: SortBy.rating),
          head('용량', width: 84),
          head('추가일', width: 110, sort: SortBy.added),
          head('시리즈', flex: 3),
        ]),
      ),
      Expanded(
        child: ListView.builder(
          itemExtent: 58,
          itemCount: entries.length,
          itemBuilder: (_, i) {
            final e = entries[i];
            final sel = state.selected.contains(e.key);
            final (String title, String kind, String pages, int rating, String size, DateTime added, String series, double prog, String? cover) =
                switch (e) {
              SeriesEntry s => (
                  s.series.title,
                  '묶음',
                  '${s.stats.allItems}${s.stats.unit}',
                  0,
                  '',
                  s.stats.latestAdded,
                  state.seriesPath(s.series.parentId),
                  s.stats.allItems == 0 ? 0.0 : s.stats.finished / s.stats.allItems,
                  s.series.coverPath ?? s.stats.coverPath,
                ),
              ItemEntry x => (
                  x.item.fileName,
                  kindLabel(x.item.kind),
                  x.item.pages?.toString() ?? '',
                  x.item.rating,
                  fileSize(x.item.size),
                  x.item.addedAt,
                  state.seriesPath(x.item.seriesId),
                  x.item.progress,
                  x.item.coverPath,
                ),
            };
            return GestureDetector(
              onTap: () => onTap(e),
              onDoubleTap: () => onOpen(e),
              onSecondaryTapUp: (d) => onMenu(e, d.globalPosition),
              child: Container(
                decoration: BoxDecoration(
                  color: sel ? scheme.primary.withValues(alpha: 0.18) : (i.isOdd ? scheme.surfaceContainerLow : null),
                  border: Border(left: BorderSide(color: sel ? scheme.primary : Colors.transparent, width: 3)),
                ),
                child: Row(children: [
                  cell(
                    prog > 0
                        ? Column(mainAxisAlignment: MainAxisAlignment.center, crossAxisAlignment: CrossAxisAlignment.start, children: [
                            Text('${(prog * 100).round()}%', style: small?.copyWith(color: const Color(0xFFFFB300))),
                            const SizedBox(height: 3),
                            LinearProgressIndicator(value: prog.clamp(0.0, 1.0), minHeight: 3, color: const Color(0xFFFFB300)),
                          ])
                        : const SizedBox(),
                    width: 70,
                  ),
                  cell(
                    SizedBox(
                      height: 48,
                      child: cover == null
                          ? Icon(e is SeriesEntry ? Icons.folder : Icons.insert_drive_file, color: const Color(0xFFFFC107))
                          : ClipRRect(
                              borderRadius: BorderRadius.circular(3),
                              child: Image.file(File(cover), fit: BoxFit.cover, cacheWidth: 96, errorBuilder: (_, _, _) => const Icon(Icons.book)),
                            ),
                    ),
                    width: 56,
                  ),
                  cell(
                    Row(children: [
                      if (e is SeriesEntry) const Padding(padding: EdgeInsets.only(right: 6), child: Icon(Icons.folder, color: Color(0xFFFFC107), size: 18)),
                      Expanded(child: Text(title, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontWeight: FontWeight.w600))),
                    ]),
                    flex: 5,
                  ),
                  cell(Text(kind, style: small), width: 64),
                  cell(Text(pages, style: small), width: 56),
                  cell(Text(rating > 0 ? '★ ${ratingText(rating)}' : '', style: small?.copyWith(color: const Color(0xFFFFC107))), width: 64),
                  cell(Text(size, style: small), width: 84),
                  cell(Text(shortDate(added), style: small), width: 110),
                  cell(Text(series, maxLines: 1, overflow: TextOverflow.ellipsis, style: small), flex: 3),
                ]),
              ),
            );
          },
        ),
      ),
    ]);
  }
}

// =====================================================================
//  아래 상세 패널 (PC): 표지 + 읽기 / 시리즈 · 제목 · 태그 / 정보 표 / 줄거리
// =====================================================================
class DetailPanel extends StatelessWidget {
  const DetailPanel({super.key});

  @override
  Widget build(BuildContext context) {
    final state = context.watch<AppState>();
    final s = context.watch<Settings>();
    final e = state.focusedEntry;
    final scheme = Theme.of(context).colorScheme;
    if (e == null) return const SizedBox();

    final toggle = Center(
      child: Material(
        color: scheme.surfaceContainerHigh,
        borderRadius: const BorderRadius.vertical(top: Radius.circular(8)),
        child: InkWell(
          onTap: () => s.detailOpen = !s.detailOpen,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 4),
            child: Row(mainAxisSize: MainAxisSize.min, children: [
              const Text('상세', style: TextStyle(fontWeight: FontWeight.w700)),
              Icon(s.detailOpen ? Icons.expand_more : Icons.expand_less, size: 18),
            ]),
          ),
        ),
      ),
    );
    if (!s.detailOpen) return toggle;

    return Column(mainAxisSize: MainAxisSize.min, children: [
      toggle,
      Container(
        height: 330,
        decoration: BoxDecoration(
          color: scheme.surfaceContainerLow,
          border: Border(top: BorderSide(color: scheme.surfaceContainerHighest)),
        ),
        child: switch (e) {
          ItemEntry i => _ItemDetail(item: i.item),
          SeriesEntry x => _SeriesDetail(series: x.series, stats: x.stats),
        },
      ),
    ]);
  }
}

class _ItemDetail extends StatelessWidget {
  final MediaItem item;
  const _ItemDetail({required this.item});

  @override
  Widget build(BuildContext context) {
    final state = context.read<AppState>();
    state.ensurePages(item); // 쪽수를 모르면 한 번 세어 둔다
    final text = Theme.of(context).textTheme;
    final scheme = Theme.of(context).colorScheme;
    final series = state.seriesById(item.seriesId);
    final mins = item.pages == null ? null : (item.kind == MediaKind.comic ? (item.pages! * 0.25).ceil() : item.pages! * 2);

    final rows = <(IconData, String, Widget)>[
      (Icons.person, '저자', Text(item.author ?? '-')),
      (Icons.business, '출판사', Text(item.publisher ?? '-')),
      (Icons.description, '쪽수', Text(item.pages?.toString() ?? '-')),
      if (mins != null) (Icons.schedule, '예상 독서 시간', Text(mins < 60 ? '$mins분' : '${mins ~/ 60}시간 ${mins % 60}분')),
      if (series != null) (Icons.layers, '전체 권수', Text(series.total?.toString() ?? '-')),
      (
        Icons.star,
        '평점',
        Row(children: [
          Text(ratingText(item.rating), style: const TextStyle(color: Color(0xFFFFC107), fontWeight: FontWeight.w700)),
          const SizedBox(width: 8),
          OutlinedButton(
            style: OutlinedButton.styleFrom(visualDensity: VisualDensity.compact),
            onPressed: () => showRatingDialog(context, item),
            child: const Text('수정'),
          ),
        ]),
      ),
      (Icons.event, '연도', Text(item.year?.toString() ?? '-')),
      (Icons.sd_storage, '파일', Text('${item.extension.substring(1).toUpperCase()} · ${fileSize(item.size)}')),
      (Icons.folder_open, '위치', Text(item.path, maxLines: 1, overflow: TextOverflow.ellipsis)),
    ];

    return Padding(
      padding: const EdgeInsets.all(16),
      child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
        // 표지 + 읽기
        SizedBox(
          width: 190,
          child: Column(children: [
            Expanded(
              child: ClipRRect(borderRadius: BorderRadius.circular(6), child: CoverImage(item: item, fit: BoxFit.cover)),
            ),
            const SizedBox(height: 10),
            SizedBox(
              width: double.infinity,
              child: FilledButton.icon(
                style: FilledButton.styleFrom(padding: const EdgeInsets.symmetric(vertical: 14)),
                onPressed: () => openItem(context, item, siblings: state.entries.whereType<ItemEntry>().map((e) => e.item).toList()),
                icon: Icon(item.kind == MediaKind.video ? Icons.play_arrow : Icons.chrome_reader_mode),
                label: Text(item.progress > 0 ? '이어서 ${(item.progress * 100).round()}%' : (item.kind == MediaKind.video ? '재생' : '읽기')),
              ),
            ),
          ]),
        ),
        const SizedBox(width: 20),
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            if (series != null)
              Text(state.seriesPath(series.id), style: text.labelLarge?.copyWith(color: const Color(0xFFFFB300), fontWeight: FontWeight.w700)),
            Row(children: [
              Expanded(
                child: Text(
                  [item.title, if (item.volumeLabel != null && !item.title.contains(item.volumeLabel!.replaceAll(RegExp(r'[권화]'), ''))) item.volumeLabel!].join(' '),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: text.headlineSmall?.copyWith(fontWeight: FontWeight.w900),
                ),
              ),
              IconButton(
                tooltip: '정보 / 메타데이터 편집',
                icon: const Icon(Icons.edit_note),
                onPressed: () => Navigator.push(context, MaterialPageRoute(builder: (_) => DetailPage(item: item))),
              ),
            ]),
            if (item.tags.isNotEmpty) ...[
              const SizedBox(height: 6),
              Wrap(spacing: 6, runSpacing: 6, children: [
                for (final t in item.tags)
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                    decoration: BoxDecoration(color: scheme.surfaceContainerHighest, borderRadius: BorderRadius.circular(4)),
                    child: Text(t, style: text.labelSmall),
                  ),
              ]),
            ],
            const SizedBox(height: 10),
            Expanded(
              child: Container(
                decoration: BoxDecoration(border: Border.all(color: scheme.surfaceContainerHighest), borderRadius: BorderRadius.circular(6)),
                child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  // 정보 표
                  Expanded(
                    child: ListView(padding: const EdgeInsets.all(10), children: [
                      for (final (icon, label, value) in rows)
                        Container(
                          padding: const EdgeInsets.symmetric(vertical: 5),
                          decoration: BoxDecoration(border: Border(bottom: BorderSide(color: scheme.surfaceContainerHighest))),
                          child: Row(children: [
                            Icon(icon, size: 16, color: Colors.grey),
                            const SizedBox(width: 8),
                            SizedBox(width: 100, child: Text(label, style: text.bodySmall)),
                            Expanded(child: DefaultTextStyle.merge(style: text.bodyMedium, child: value)),
                          ]),
                        ),
                    ]),
                  ),
                  VerticalDivider(width: 1, color: scheme.surfaceContainerHighest),
                  // 줄거리
                  Expanded(
                    child: ListView(padding: const EdgeInsets.all(12), children: [
                      Row(children: [
                        const Icon(Icons.article, size: 16, color: Color(0xFFFFB300)),
                        const SizedBox(width: 6),
                        Text('줄거리', style: text.labelLarge?.copyWith(color: const Color(0xFFFFB300))),
                      ]),
                      const SizedBox(height: 8),
                      Text(item.description?.isNotEmpty == true ? item.description! : '줄거리가 없습니다. ✎ 버튼으로 인터넷에서 가져오거나 직접 입력하세요.',
                          style: text.bodyMedium?.copyWith(height: 1.6)),
                    ]),
                  ),
                ]),
              ),
            ),
          ]),
        ),
      ]),
    );
  }
}

class _SeriesDetail extends StatelessWidget {
  final Series series;
  final SeriesStats stats;
  const _SeriesDetail({required this.series, required this.stats});

  @override
  Widget build(BuildContext context) {
    final state = context.read<AppState>();
    final text = Theme.of(context).textTheme;
    final next = state.nextToRead(series.id!);
    final cover = series.coverPath ?? stats.coverPath;
    return Padding(
      padding: const EdgeInsets.all(16),
      child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
        SizedBox(
          width: 190,
          child: Column(children: [
            Expanded(
              child: ClipRRect(
                borderRadius: BorderRadius.circular(6),
                child: cover == null
                    ? const Center(child: Icon(Icons.collections_bookmark, size: 64))
                    : Image.file(File(cover), fit: BoxFit.cover, width: double.infinity, errorBuilder: (_, _, _) => const SizedBox()),
              ),
            ),
            const SizedBox(height: 10),
            SizedBox(
              width: double.infinity,
              child: FilledButton.icon(
                style: FilledButton.styleFrom(padding: const EdgeInsets.symmetric(vertical: 14)),
                onPressed: next == null
                    ? () => state.enterSeries(series.id)
                    : () => openItem(context, next, siblings: state.volumesOf(series.id!)),
                icon: const Icon(Icons.play_arrow),
                label: Text(next == null ? '열기' : '${next.progress > 0 ? '이어서' : '보기'} ${next.volumeLabel ?? ''}'),
              ),
            ),
          ]),
        ),
        const SizedBox(width: 20),
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            if (series.parentId != null)
              Text(state.seriesPath(series.parentId), style: text.labelLarge?.copyWith(color: const Color(0xFFFFB300))),
            Text(series.title, style: text.headlineSmall?.copyWith(fontWeight: FontWeight.w900)),
            const SizedBox(height: 8),
            Text(seriesSummary(series, stats), style: text.titleSmall),
            if (series.author != null) Text(series.author!, style: text.bodyMedium),
            const SizedBox(height: 12),
            if (series.description != null) Expanded(child: SingleChildScrollView(child: Text(series.description!, style: text.bodyMedium?.copyWith(height: 1.6)))),
            const Spacer(),
            Wrap(spacing: 8, children: [
              OutlinedButton.icon(onPressed: () => state.enterSeries(series.id), icon: const Icon(Icons.folder_open), label: const Text('안으로 들어가기')),
              if (state.isAdmin)
                OutlinedButton.icon(onPressed: () => showSeriesEditor(context, series), icon: const Icon(Icons.edit), label: const Text('묶음 정보')),
            ]),
          ]),
        ),
      ]),
    );
  }
}

// =====================================================================
//  별점 창: 별 5개, 반 개 단위 (10점 만점)
// =====================================================================
Future<void> showRatingDialog(BuildContext context, MediaItem item) async {
  final state = context.read<AppState>();
  var value = item.rating;
  const labels = ['평가 안 함', '최악', '별로', '실망', '아쉬움', '보통', '괜찮음', '좋음', '추천', '매우 좋음', '최고!'];
  final result = await showDialog<int>(
    context: context,
    builder: (ctx) => StatefulBuilder(
      builder: (ctx, setLocal) => Dialog(
        backgroundColor: const Color(0xFF2A2A2A),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        child: SizedBox(
          width: 440,
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Column(mainAxisSize: MainAxisSize.min, children: [
              Row(children: [
                SizedBox(width: 56, height: 80, child: ClipRRect(borderRadius: BorderRadius.circular(4), child: CoverImage(item: item))),
                const SizedBox(width: 14),
                Expanded(
                  child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    if (item.seriesId != null)
                      Text(state.seriesPath(item.seriesId), style: const TextStyle(color: Color(0xFFFFB300), fontSize: 12)),
                    Text(item.title, style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w700, fontSize: 16)),
                  ]),
                ),
                IconButton(onPressed: () => Navigator.pop(ctx), icon: const Icon(Icons.close, color: Colors.white)),
              ]),
              const Divider(height: 32, color: Colors.white24),
              const Text('어떻게 평가하시겠습니까?', style: TextStyle(color: Colors.white, fontSize: 16, fontWeight: FontWeight.w700)),
              const SizedBox(height: 16),
              // 별 하나를 왼쪽 절반/오른쪽 절반으로 나눠 반 개 단위
              Row(mainAxisAlignment: MainAxisAlignment.center, children: [
                for (var i = 0; i < 5; i++)
                  SizedBox(
                    width: 64,
                    height: 64,
                    child: Stack(children: [
                      Icon(
                        value >= (i + 1) * 2 ? Icons.star : (value == i * 2 + 1 ? Icons.star_half : Icons.star_border),
                        size: 64,
                        color: const Color(0xFFFFC107),
                        shadows: const [Shadow(color: Color(0x88FFC107), blurRadius: 16)],
                      ),
                      Row(children: [
                        Expanded(child: GestureDetector(behavior: HitTestBehavior.opaque, onTap: () => setLocal(() => value = i * 2 + 1))),
                        Expanded(child: GestureDetector(behavior: HitTestBehavior.opaque, onTap: () => setLocal(() => value = i * 2 + 2))),
                      ]),
                    ]),
                  ),
              ]),
              const SizedBox(height: 12),
              Text(labels[value], style: const TextStyle(color: Color(0xFFFFB300), fontWeight: FontWeight.w700)),
              Text('$value / 10', style: const TextStyle(color: Colors.white60)),
              const SizedBox(height: 20),
              Row(children: [
                TextButton(onPressed: () => setLocal(() => value = 0), child: const Text('지우기')),
                const SizedBox(width: 8),
                Expanded(
                  child: FilledButton(
                    style: FilledButton.styleFrom(
                      backgroundColor: const Color(0xFFF5B82E),
                      foregroundColor: Colors.black,
                      padding: const EdgeInsets.symmetric(vertical: 16),
                    ),
                    onPressed: () => Navigator.pop(ctx, value),
                    child: const Text('평가하기', style: TextStyle(fontWeight: FontWeight.w800)),
                  ),
                ),
              ]),
            ]),
          ),
        ),
      ),
    ),
  );
  if (result != null) await state.setRating(item, result);
}

// =====================================================================
//  오른쪽 클릭 메뉴
// =====================================================================
Future<void> showEntryMenu(BuildContext context, Entry e, Offset at, List<MediaItem> siblings) async {
  final state = context.read<AppState>();
  final admin = state.isAdmin;
  final overlay = Overlay.of(context).context.findRenderObject() as RenderBox;
  final pos = RelativeRect.fromRect(at & const Size(1, 1), Offset.zero & overlay.size);
  final multi = state.selected.length > 1;

  PopupMenuItem<String> item(String v, IconData icon, String label, {String? key, Color? color}) => PopupMenuItem(
        value: v,
        height: 38,
        child: Row(children: [
          Icon(icon, size: 18, color: color),
          const SizedBox(width: 10),
          Expanded(child: Text(label, style: TextStyle(color: color))),
          if (key != null) Text(key, style: const TextStyle(color: Colors.grey, fontSize: 12)),
        ]),
      );

  final items = <PopupMenuEntry<String>>[
    if (!multi) ...[
      item('open', Icons.chrome_reader_mode, e is SeriesEntry ? '열기' : '뷰어로 보기', key: 'Enter'),
      if (e is ItemEntry) item('system', Icons.open_in_new, '다른 앱으로 열기'),
      const PopupMenuDivider(),
    ],
    if (e case ItemEntry i when !multi) ...[
      item('finished', Icons.done_all, i.item.progress >= 0.98 ? '안 읽음으로 표시' : '읽음으로 표시'),
      item('reset', Icons.restart_alt, '읽기 진행률 초기화'),
      item('rate', Icons.star, '평점 수정'),
      item('fav', i.item.favorite ? Icons.favorite : Icons.favorite_border, i.item.favorite ? '즐겨찾기 해제' : '즐겨찾기'),
      item('info', Icons.edit_note, '메타데이터 관리'),
      const PopupMenuDivider(),
    ],
    if (e is SeriesEntry && admin && !multi) ...[
      item('series', Icons.edit, '묶음 정보'),
      const PopupMenuDivider(),
    ],
    if (admin) ...[
      item('batch', Icons.edit_note, multi || e is SeriesEntry ? '메타데이터 일괄 관리' : '메타데이터 관리 (편집기)'),
      item('move', Icons.drive_file_move, multi ? '선택한 ${state.selected.length}개 다른 묶음으로' : '다른 묶음으로 이동'),
      item('hide', Icons.visibility_off, '숨기기'),
      item('access', Icons.lock_person, '사용자 접근'),
    ],
    if (e is ItemEntry && !multi && Platform.isWindows) item('explorer', Icons.folder_open, '탐색기에서 열기'),
    if (admin) ...[
      const PopupMenuDivider(),
      item('delete', Icons.delete_outline, multi ? '선택한 ${state.selected.length}개 삭제' : '삭제', key: 'Del', color: Colors.redAccent),
    ],
    const PopupMenuDivider(),
    item('all', Icons.select_all, '전체 선택', key: 'Ctrl+A'),
    if (admin) item('refresh', Icons.refresh, '새로고침 (다시 스캔)', key: 'F5'),
  ];

  final v = await showMenu<String>(context: context, position: pos, items: items, color: const Color(0xFF242424));
  if (v == null || !context.mounted) return;
  switch (v) {
    case 'open':
      openEntry(context, e, siblings);
    case 'system':
      if (e is ItemEntry) openWithSystem(e.item.path);
    case 'finished':
      if (e is ItemEntry) state.markFinished(e.item, e.item.progress < 0.98);
    case 'reset':
      if (e is ItemEntry) state.markFinished(e.item, false);
    case 'rate':
      if (e is ItemEntry) showRatingDialog(context, e.item);
    case 'fav':
      if (e is ItemEntry) {
        e.item.favorite = !e.item.favorite;
        state.save(e.item);
      }
    case 'info':
      if (e is ItemEntry) Navigator.push(context, MaterialPageRoute(builder: (_) => DetailPage(item: e.item)));
    case 'batch':
      final items = state.selectedItemsDeep;
      if (items.isNotEmpty) Navigator.push(context, MaterialPageRoute(builder: (_) => BatchEditorPage(items: items)));
    case 'series':
      if (e is SeriesEntry) showSeriesEditor(context, e.series);
    case 'move':
      final target = await pickSeries(context, title: '어느 묶음으로 옮길까요?');
      if (target != null) await state.moveSelected(target.id);
    case 'hide':
      if (!state.hasHiddenPassword) {
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('먼저 관리자 메뉴에서 숨김 비밀번호를 정하세요')));
      } else {
        await state.hideSelected(true);
      }
    case 'access':
      await showAccessForSelection(context);
    case 'explorer':
      if (e is ItemEntry) Process.run('explorer.exe', ['/select,${e.item.path}']);
    case 'delete':
      final mode = await confirmDelete(context, multi ? '선택한 ${state.selected.length}개' : '"${switch (e) {
          SeriesEntry s => s.series.title,
          ItemEntry i => i.item.title,
        }}"', isSeries: e is SeriesEntry);
      if (mode != null) await state.removeSelected(deleteFile: mode);
    case 'all':
      state.selectAll();
    case 'refresh':
      await state.rescanAll();
  }
}

// =====================================================================
//  경로 막대: ← → ↑  전체 › 묶음 › 묶음
// =====================================================================
class PathBar extends StatelessWidget {
  const PathBar({super.key});

  @override
  Widget build(BuildContext context) {
    final state = context.watch<AppState>();
    final scheme = Theme.of(context).colorScheme;
    Widget nav(IconData icon, String tip, VoidCallback? f) => Container(
          margin: const EdgeInsets.only(right: 4),
          decoration: BoxDecoration(border: Border.all(color: scheme.surfaceContainerHighest), borderRadius: BorderRadius.circular(6)),
          child: IconButton(visualDensity: VisualDensity.compact, tooltip: tip, icon: Icon(icon, size: 20), onPressed: f),
        );

    final crumbs = <Widget>[
      TextButton.icon(
        style: TextButton.styleFrom(visualDensity: VisualDensity.compact),
        onPressed: () => state.enterSeries(null),
        icon: const Icon(Icons.home, size: 18),
        label: Text(state.kindFilter == null ? '전체' : kindLabel(state.kindFilter!)),
      ),
      if (state.libraryPath != null) ...[
        const Icon(Icons.chevron_right, size: 18),
        const Icon(Icons.folder, size: 16, color: Color(0xFFFFC107)),
        const SizedBox(width: 4),
        Text(state.settings.libraryFolders.where((f) => f.path == state.libraryPath).firstOrNull?.name ?? state.libraryPath!,
            style: const TextStyle(fontWeight: FontWeight.w700)),
        const SizedBox(width: 8),
        Text(state.libraryPath!, style: const TextStyle(color: Colors.grey, fontSize: 12)),
      ],
      if (state.collection != Collection.none) ...[
        const Icon(Icons.chevron_right, size: 18),
        Text(collectionLabel(state.collection), style: const TextStyle(fontWeight: FontWeight.w700)),
      ],
      if (state.collection == Collection.none && state.libraryPath == null)
        for (final b in state.breadcrumb) ...[
          const Icon(Icons.chevron_right, size: 18),
          TextButton(
            style: TextButton.styleFrom(visualDensity: VisualDensity.compact),
            onPressed: b.id == state.currentSeriesId ? null : () => state.enterSeries(b.id),
            child: Text(b.title, style: TextStyle(fontWeight: b.id == state.currentSeriesId ? FontWeight.w800 : null)),
          ),
        ],
    ];

    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 6, 12, 6),
      child: Row(children: [
        nav(Icons.chevron_left, '뒤로 (Alt+←)', state.canBack ? state.goBack : null),
        nav(Icons.chevron_right, '앞으로 (Alt+→)', state.canForward ? state.goForward : null),
        nav(Icons.expand_less, '위로 (Backspace)', state.currentSeriesId != null ? state.goUp : null),
        const SizedBox(width: 6),
        Expanded(
          child: Container(
            height: 40,
            padding: const EdgeInsets.symmetric(horizontal: 6),
            decoration: BoxDecoration(border: Border.all(color: scheme.surfaceContainerHighest), borderRadius: BorderRadius.circular(6)),
            child: SingleChildScrollView(scrollDirection: Axis.horizontal, reverse: true, child: Row(children: crumbs)),
          ),
        ),
        if (state.isAdmin) ...[
          const SizedBox(width: 6),
          nav(Icons.refresh, '다시 스캔 (F5)', state.scanning ? null : state.rescanAll),
        ],
      ]),
    );
  }
}

// =====================================================================
//  아래 상태 막대: 선택 / 묶음 / 파일 수 · 보기 방식 · 항목 크기
// =====================================================================
class StatusBar extends StatelessWidget {
  const StatusBar({super.key});

  @override
  Widget build(BuildContext context) {
    final state = context.watch<AppState>();
    final s = context.watch<Settings>();
    final scheme = Theme.of(context).colorScheme;
    final entries = state.entries;
    final series = entries.whereType<SeriesEntry>().length;
    final files = entries.length - series;
    final selBytes = entries
        .whereType<ItemEntry>()
        .where((e) => state.selected.contains(e.key))
        .fold<int>(0, (a, e) => a + e.item.size);

    Widget mode(int m, IconData icon, String tip) => IconButton(
          tooltip: tip,
          visualDensity: VisualDensity.compact,
          isSelected: s.viewMode == m,
          style: IconButton.styleFrom(
            backgroundColor: s.viewMode == m ? scheme.primary : null,
            foregroundColor: s.viewMode == m ? Colors.white : null,
          ),
          icon: Icon(icon, size: 20),
          onPressed: () => s.viewMode = m,
        );

    return Container(
      height: 40,
      padding: const EdgeInsets.symmetric(horizontal: 12),
      decoration: BoxDecoration(color: scheme.surfaceContainerLow, border: Border(top: BorderSide(color: scheme.surfaceContainerHighest))),
      child: Row(children: [
        Expanded(
          child: Text(
            [
              '선택: ${state.selected.length}',
              '묶음: $series개',
              '파일: $files개',
              if (selBytes > 0) '선택한 파일 용량: ${fileSize(selBytes)}',
              if (state.scanning || state.scanStatus.isNotEmpty) state.scanStatus,
            ].join('  |  '),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: Theme.of(context).textTheme.bodySmall,
          ),
        ),
        mode(0, Icons.view_list, '표 보기'),
        mode(1, Icons.grid_view, '격자 보기'),
        mode(2, Icons.view_agenda, '카드 목록 보기'),
        const SizedBox(width: 12),
        Text('항목 크기', style: Theme.of(context).textTheme.bodySmall),
        SizedBox(
          width: 160,
          child: Slider(min: 120, max: 320, value: s.coverSize.clamp(120, 320), onChanged: s.viewMode == 1 ? (v) => s.coverSize = v : null),
        ),
      ]),
    );
  }
}
