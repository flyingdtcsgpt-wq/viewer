import 'media_item.dart';
import 'series.dart';

/// 그리드에 나오는 한 칸: 묶음 또는 낱권
sealed class Entry {
  String get key;
}

class SeriesEntry extends Entry {
  final Series series;
  final SeriesStats stats;
  SeriesEntry(this.series, this.stats);
  @override
  String get key => 's:${series.id}';
}

class ItemEntry extends Entry {
  final MediaItem item;
  ItemEntry(this.item);
  @override
  String get key => 'i:${item.id}';
}

/// 묶음 카드에 표시할 요약
class SeriesStats {
  final int direct; // 이 묶음에 바로 들어 있는 권 수
  final int childSeries; // 하위 묶음 수
  final int allItems; // 하위까지 전부
  final int finished; // 다 읽은(본) 권 수
  final String? coverPath;
  final bool isVideo;
  final DateTime latestAdded;
  final DateTime? lastOpened;

  const SeriesStats({
    required this.direct,
    required this.childSeries,
    required this.allItems,
    required this.finished,
    required this.coverPath,
    required this.isVideo,
    required this.latestAdded,
    required this.lastOpened,
  });

  String get unit => isVideo ? '화' : '권';
}

/// "12 / 105권 · 연재중" 같은 요약 문구
String seriesSummary(Series s, SeriesStats st) {
  final parts = <String>[];
  if (st.childSeries > 0) parts.add('묶음 ${st.childSeries}개');
  if (st.direct > 0 || st.childSeries == 0) {
    parts.add(s.total != null ? '${st.direct} / ${s.total}${st.unit}' : '${st.direct}${st.unit}');
  } else if (st.allItems > 0) {
    parts.add('전체 ${st.allItems}${st.unit}');
  }
  final status = statusLabel(s.status);
  if (status.isNotEmpty) parts.add(status);
  return parts.join(' · ');
}
