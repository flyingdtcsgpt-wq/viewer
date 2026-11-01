import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../app_state.dart';
import '../models/media_item.dart';
import '../services/auth.dart';
import 'cover_tile.dart';
import 'viewers/open_item.dart';

/// 내 열람 기록: 언제 무엇을 열어 어디까지 봤는지 (사용자별)
class HistoryPage extends StatefulWidget {
  const HistoryPage({super.key});
  @override
  State<HistoryPage> createState() => _HistoryPageState();
}

class _HistoryPageState extends State<HistoryPage> {
  List<(HistoryRecord, MediaItem)>? _rows;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final r = await context.read<AppState>().historyList();
    if (mounted) setState(() => _rows = r);
  }

  String _when(DateTime t) {
    final now = DateTime.now();
    String two(int v) => v.toString().padLeft(2, '0');
    final time = '${two(t.hour)}:${two(t.minute)}';
    final d = DateTime(now.year, now.month, now.day).difference(DateTime(t.year, t.month, t.day)).inDays;
    if (d == 0) return '오늘 $time';
    if (d == 1) return '어제 $time';
    return '${t.year}.${two(t.month)}.${two(t.day)} $time';
  }

  String _where(HistoryRecord h, MediaItem e) {
    final pct = '${(h.progress * 100).round()}%';
    final pos = h.position;
    if (pos == null) return pct;
    if (e.kind == MediaKind.video) {
      final ms = int.tryParse(pos) ?? 0;
      final d = Duration(milliseconds: ms);
      return '${d.inHours > 0 ? '${d.inHours}:' : ''}${(d.inMinutes % 60).toString().padLeft(2, '0')}:${(d.inSeconds % 60).toString().padLeft(2, '0')} ($pct)';
    }
    if (e.extension == '.pdf' || e.kind == MediaKind.comic) return '${int.tryParse(pos) != null ? (e.extension == '.pdf' ? pos : '${int.parse(pos) + 1}') : pos}쪽 ($pct)';
    return pct;
  }

  @override
  Widget build(BuildContext context) {
    final state = context.watch<AppState>();
    final rows = _rows;
    return Scaffold(
      appBar: AppBar(
        title: Text('${state.user?.name ?? ''} 님의 열람 기록'),
        actions: [
          IconButton(
            tooltip: '기록 지우기',
            icon: const Icon(Icons.delete_sweep),
            onPressed: () async {
              final ok = await showDialog<bool>(
                context: context,
                builder: (_) => AlertDialog(
                  title: const Text('열람 기록 지우기'),
                  content: const Text('기록 목록만 지웁니다. 각 책의 마지막 읽은 위치는 남습니다.'),
                  actions: [
                    TextButton(onPressed: () => Navigator.pop(context), child: const Text('취소')),
                    FilledButton(onPressed: () => Navigator.pop(context, true), child: const Text('지우기')),
                  ],
                ),
              );
              if (ok == true) {
                await state.clearHistory();
                await _load();
              }
            },
          ),
        ],
      ),
      body: rows == null
          ? const Center(child: CircularProgressIndicator())
          : rows.isEmpty
              ? const Center(child: Text('아직 기록이 없습니다'))
              : Center(
                  child: ConstrainedBox(
                    constraints: const BoxConstraints(maxWidth: 860),
                    child: ListView.separated(
                      itemCount: rows.length,
                      separatorBuilder: (_, _) => const Divider(height: 1),
                      itemBuilder: (_, i) {
                        final (h, e) = rows[i];
                        return ListTile(
                          leading: SizedBox(width: 44, height: 60, child: ClipRRect(borderRadius: BorderRadius.circular(4), child: CoverImage(item: e))),
                          title: Text(
                            [state.seriesPath(e.seriesId), e.volumeLabel ?? e.title].where((s) => s.isNotEmpty).join(' › '),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                          subtitle: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                            Text('${_when(h.openedAt)} · ${_where(h, e)}'),
                            const SizedBox(height: 4),
                            LinearProgressIndicator(value: h.progress.clamp(0.0, 1.0)),
                          ]),
                          trailing: IconButton(
                            tooltip: '이어서 보기',
                            icon: const Icon(Icons.play_circle),
                            onPressed: () async {
                              await openItem(context, e);
                              _load();
                            },
                          ),
                        );
                      },
                    ),
                  ),
                ),
    );
  }
}
