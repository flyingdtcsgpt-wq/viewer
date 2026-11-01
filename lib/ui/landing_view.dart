import 'dart:io';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../app_state.dart';
import '../models/entry.dart';
import '../models/media_item.dart';
import '../models/series.dart';
import 'cover_tile.dart';
import 'detail_page.dart';
import 'series_widgets.dart';
import 'viewers/open_item.dart';

/// 넷플릭스풍 첫 화면: 큰 배너 + 가로로 넘기는 줄들
class LandingView extends StatelessWidget {
  final Widget? topBar; // 휴대폰에서 배너 위에 겹쳐 놓을 메뉴/검색 줄
  const LandingView({super.key, this.topBar});

  @override
  Widget build(BuildContext context) {
    final state = context.watch<AppState>();
    final featured = state.featured;
    final cont = state.continueWatching.take(24).toList();
    final favorites = state.allItems.where((e) => e.favorite).take(24).map<Entry>(ItemEntry.new).toList();

    final rows = <Widget>[
      if (cont.isNotEmpty) _Row(title: '${state.user?.name ?? ''} 님이 보던 작품', entries: cont.map<Entry>(ItemEntry.new).toList(), wideCards: true),
      _Row(title: '최근 추가된 작품', entries: state.rootEntries(), onMore: () => state.setFilter(clearKind: true)),
      for (final k in [MediaKind.comic, MediaKind.book, MediaKind.video, MediaKind.image])
        _Row(title: kindLabel(k), entries: state.rootEntries(kind: k), onMore: () => state.setFilter(kind: k)),
      if (favorites.isNotEmpty) _Row(title: '즐겨찾기', entries: favorites, onMore: () => state.setFilter(favorites: true)),
    ];

    if (featured == null) {
      return Stack(children: [
        Center(
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            const Icon(Icons.local_library, size: 72),
            const SizedBox(height: 12),
            Text(
              state.isAdmin ? '아직 작품이 없습니다. 왼쪽 메뉴의 "폴더 등록"으로 추가하세요.' : '볼 수 있는 작품이 없습니다.',
              textAlign: TextAlign.center,
            ),
          ]),
        ),
        ?topBar,
      ]);
    }

    return CustomScrollView(slivers: [
      SliverToBoxAdapter(child: Stack(children: [_Hero(entry: featured), ?topBar])),
      SliverList(delegate: SliverChildListDelegate(rows)),
      const SliverToBoxAdapter(child: SizedBox(height: 48)),
    ]);
  }
}

// =====================================================================
//  큰 배너
// =====================================================================
class _Hero extends StatelessWidget {
  final Entry entry;
  const _Hero({required this.entry});

  @override
  Widget build(BuildContext context) {
    final state = context.read<AppState>();
    final size = MediaQuery.sizeOf(context);
    final wide = size.width >= 840;
    final bg = Theme.of(context).scaffoldBackgroundColor;

    late final String title, subtitle;
    String? desc, cover;
    late final String playLabel;
    late final VoidCallback onPlay, onInfo;

    switch (entry) {
      case SeriesEntry e:
        final s = e.series;
        final next = state.nextToRead(s.id!);
        title = s.title;
        subtitle = [seriesSummary(s, e.stats), if (s.author != null) s.author!].where((x) => x.isNotEmpty).join('  ·  ');
        desc = s.description;
        cover = s.coverPath ?? e.stats.coverPath;
        playLabel = next == null ? '열기' : '${next.progress > 0 ? '이어서' : '보기'} ${next.volumeLabel ?? ''}'.trim();
        onPlay = next == null
            ? () => state.enterSeries(s.id)
            : () => openItem(context, next, siblings: state.volumesOf(s.id!));
        onInfo = () => state.enterSeries(s.id);
      case ItemEntry e:
        final it = e.item;
        title = it.title;
        subtitle = [kindLabel(it.kind), if (it.author != null) it.author!, if (it.progress > 0) '${(it.progress * 100).round()}% 봄']
            .join('  ·  ');
        desc = it.description;
        cover = it.coverPath;
        playLabel = it.progress > 0 ? '이어서 보기' : (it.kind == MediaKind.video ? '재생' : '보기');
        onPlay = () => openItem(context, it);
        onInfo = () => Navigator.push(context, MaterialPageRoute(builder: (_) => DetailPage(item: it)));
    }

    final height = wide ? (size.height * 0.62).clamp(360.0, 720.0) : size.width * 1.25;
    final text = Theme.of(context).textTheme;

    final info = Column(
      crossAxisAlignment: wide ? CrossAxisAlignment.start : CrossAxisAlignment.center,
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(
          title,
          textAlign: wide ? TextAlign.start : TextAlign.center,
          maxLines: 2,
          overflow: TextOverflow.ellipsis,
          style: (wide ? text.displaySmall : text.headlineMedium)?.copyWith(
            fontWeight: FontWeight.w900,
            color: Colors.white,
            shadows: const [Shadow(blurRadius: 12, color: Colors.black)],
          ),
        ),
        const SizedBox(height: 8),
        Text(subtitle, style: text.titleSmall?.copyWith(color: Colors.white70)),
        if (wide && desc != null && desc.isNotEmpty) ...[
          const SizedBox(height: 12),
          Text(desc, maxLines: 3, overflow: TextOverflow.ellipsis, style: text.bodyLarge?.copyWith(color: Colors.white)),
        ],
        const SizedBox(height: 20),
        Wrap(spacing: 12, runSpacing: 8, alignment: WrapAlignment.center, children: [
          FilledButton.icon(
            style: FilledButton.styleFrom(
              backgroundColor: Colors.white,
              foregroundColor: Colors.black,
              padding: const EdgeInsets.symmetric(horizontal: 28, vertical: 16),
              textStyle: const TextStyle(fontSize: 16, fontWeight: FontWeight.w700),
            ),
            onPressed: onPlay,
            icon: const Icon(Icons.play_arrow, size: 28),
            label: Text(playLabel),
          ),
          FilledButton.icon(
            style: FilledButton.styleFrom(
              backgroundColor: Colors.white24,
              foregroundColor: Colors.white,
              padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 16),
              textStyle: const TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
            ),
            onPressed: onInfo,
            icon: const Icon(Icons.info_outline),
            label: const Text('상세 정보'),
          ),
        ]),
      ],
    );

    return SizedBox(
      height: height,
      child: Stack(fit: StackFit.expand, children: [
        // 배경: 표지를 크게 (넓은 화면은 오른쪽에 붙임)
        if (cover != null)
          Align(
            alignment: wide ? Alignment.centerRight : Alignment.topCenter,
            child: FractionallySizedBox(
              widthFactor: wide ? 0.7 : 1,
              heightFactor: 1,
              child: Image.file(File(cover), fit: BoxFit.cover, alignment: Alignment.topCenter, errorBuilder: (_, _, _) => const SizedBox()),
            ),
          ),
        // 왼쪽/아래 그라데이션으로 배경과 자연스럽게 섞기
        DecoratedBox(
          decoration: BoxDecoration(
            gradient: LinearGradient(
              begin: wide ? Alignment.centerLeft : Alignment.topCenter,
              end: wide ? Alignment.centerRight : Alignment.bottomCenter,
              colors: wide
                  ? [bg, bg, bg.withValues(alpha: 0.6), Colors.transparent]
                  : [Colors.transparent, Colors.transparent, bg.withValues(alpha: 0.85), bg],
              stops: wide ? const [0, 0.3, 0.55, 0.85] : const [0, 0.45, 0.8, 1],
            ),
          ),
        ),
        DecoratedBox(
          decoration: BoxDecoration(
            gradient: LinearGradient(
              begin: Alignment.topCenter,
              end: Alignment.bottomCenter,
              colors: [Colors.black.withValues(alpha: 0.45), Colors.transparent, Colors.transparent, bg],
              stops: const [0, 0.2, 0.75, 1],
            ),
          ),
        ),
        Positioned(
          left: wide ? 48 : 16,
          right: wide ? size.width * 0.35 : 16,
          bottom: wide ? 56 : 24,
          child: info,
        ),
      ]),
    );
  }
}

// =====================================================================
//  가로 줄
// =====================================================================
class _Row extends StatefulWidget {
  final String title;
  final List<Entry> entries;
  final VoidCallback? onMore;
  final bool wideCards; // "보던 작품" 은 진행 막대가 잘 보이게 조금 크게
  const _Row({required this.title, required this.entries, this.onMore, this.wideCards = false});

  @override
  State<_Row> createState() => _RowState();
}

class _RowState extends State<_Row> {
  final _ctrl = ScrollController();

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  void _scroll(int dir) {
    if (!_ctrl.hasClients) return;
    final p = _ctrl.position;
    _ctrl.animateTo((p.pixels + dir * p.viewportDimension * 0.85).clamp(0.0, p.maxScrollExtent),
        duration: const Duration(milliseconds: 350), curve: Curves.easeOutCubic);
  }

  @override
  Widget build(BuildContext context) {
    if (widget.entries.isEmpty) return const SizedBox();
    final state = context.read<AppState>();
    final width = MediaQuery.sizeOf(context).width;
    final wide = width >= 840;
    final cardW = (wide ? 168.0 : 112.0) * (widget.wideCards ? 1.1 : 1);
    final cardH = cardW * 1.5 + 46;
    final pad = wide ? 48.0 : 16.0;
    final siblings = widget.entries.whereType<ItemEntry>().map((e) => e.item).toList();

    return Padding(
      padding: const EdgeInsets.only(top: 20),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Padding(
          padding: EdgeInsets.symmetric(horizontal: pad),
          child: Row(children: [
            Text(widget.title, style: Theme.of(context).textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w700)),
            const Spacer(),
            if (widget.onMore != null)
              TextButton(onPressed: widget.onMore, child: const Text('모두 보기 ›')),
          ]),
        ),
        const SizedBox(height: 8),
        SizedBox(
          height: cardH + 16,
          child: Stack(children: [
            ListView.separated(
              controller: _ctrl,
              scrollDirection: Axis.horizontal,
              padding: EdgeInsets.symmetric(horizontal: pad, vertical: 8),
              itemCount: widget.entries.length,
              separatorBuilder: (_, _) => const SizedBox(width: 10),
              itemBuilder: (_, i) {
                final e = widget.entries[i];
                return SizedBox(
                  width: cardW,
                  child: HoverZoom(
                    child: switch (e) {
                      SeriesEntry s => SeriesTile(
                          entry: s,
                          selected: false,
                          hidden: state.isHiddenSeries(s.series),
                          onTap: () => state.enterSeries(s.series.id),
                          onLongPress: () => state.enterSeries(s.series.id),
                          onEdit: state.isAdmin ? () => showSeriesEditor(context, s.series) : () {},
                        ),
                      ItemEntry it => CoverTile(
                          item: it.item,
                          hidden: state.isHiddenItem(it.item),
                          showVolume: it.item.seriesId != null,
                          onTap: () => openItem(context, it.item, siblings: siblings),
                          onLongPress: () => _info(context, it.item),
                          onInfo: () => _info(context, it.item),
                        ),
                    },
                  ),
                );
              },
            ),
            // PC: 줄 양끝 화살표
            if (wide) ...[
              Positioned(left: 4, top: 0, bottom: 46, child: Center(child: _Arrow(Icons.chevron_left, () => _scroll(-1)))),
              Positioned(right: 4, top: 0, bottom: 46, child: Center(child: _Arrow(Icons.chevron_right, () => _scroll(1)))),
            ],
          ]),
        ),
      ]),
    );
  }

  void _info(BuildContext context, MediaItem e) =>
      Navigator.push(context, MaterialPageRoute(builder: (_) => DetailPage(item: e)));
}

class _Arrow extends StatelessWidget {
  final IconData icon;
  final VoidCallback onTap;
  const _Arrow(this.icon, this.onTap);
  @override
  Widget build(BuildContext context) => Material(
        color: Colors.black54,
        shape: const CircleBorder(),
        child: InkWell(
          customBorder: const CircleBorder(),
          onTap: onTap,
          child: Padding(padding: const EdgeInsets.all(6), child: Icon(icon, color: Colors.white, size: 30)),
        ),
      );
}

/// 마우스를 올리면 살짝 커지는 효과 (PC)
class HoverZoom extends StatefulWidget {
  final Widget child;
  const HoverZoom({super.key, required this.child});
  @override
  State<HoverZoom> createState() => _HoverZoomState();
}

class _HoverZoomState extends State<HoverZoom> {
  bool _hover = false;
  @override
  Widget build(BuildContext context) => MouseRegion(
        onEnter: (_) => setState(() => _hover = true),
        onExit: (_) => setState(() => _hover = false),
        child: AnimatedScale(
          scale: _hover ? 1.06 : 1,
          duration: const Duration(milliseconds: 160),
          curve: Curves.easeOut,
          child: widget.child,
        ),
      );
}

/// 묶음 상태 색 (배너·카드 공용)
Color statusColor(SeriesStatus s) => s == SeriesStatus.completed ? Colors.green.shade600 : Colors.orange.shade700;
