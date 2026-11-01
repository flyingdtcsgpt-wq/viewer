import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../app_state.dart';
import '../models/entry.dart';
import '../models/series.dart';
import 'viewers/open_item.dart';

// =====================================================================
//  묶음 카드: 표지가 여러 장 겹친 모양 + 권수/연재 상태
// =====================================================================
class SeriesTile extends StatelessWidget {
  final SeriesEntry entry;
  final bool selected;
  final VoidCallback onTap;
  final VoidCallback onLongPress;
  final VoidCallback onEdit;
  const SeriesTile({
    super.key,
    required this.entry,
    required this.selected,
    required this.onTap,
    required this.onLongPress,
    required this.onEdit,
  });

  @override
  Widget build(BuildContext context) {
    final s = entry.series;
    final st = entry.stats;
    final scheme = Theme.of(context).colorScheme;
    final cover = s.coverPath ?? st.coverPath;
    final dpr = MediaQuery.devicePixelRatioOf(context);

    Widget card(double offset, double opacity, {Widget? child}) => Positioned(
          left: offset,
          right: 8 - offset,
          top: 8 - offset,
          bottom: offset,
          child: Container(
            decoration: BoxDecoration(
              color: scheme.surfaceContainerHighest.withValues(alpha: opacity),
              borderRadius: BorderRadius.circular(8),
              border: Border.all(color: scheme.outlineVariant),
              boxShadow: const [BoxShadow(blurRadius: 2, color: Colors.black26, offset: Offset(1, 1))],
            ),
            clipBehavior: Clip.antiAlias,
            child: child,
          ),
        );

    return InkWell(
      borderRadius: BorderRadius.circular(8),
      onTap: onTap,
      onLongPress: onLongPress,
      onSecondaryTap: onEdit,
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Expanded(
          child: Stack(fit: StackFit.expand, children: [
            card(8, 0.5),
            card(4, 0.8),
            card(
              0,
              1,
              child: cover == null
                  ? Center(child: Icon(st.isVideo ? Icons.video_library : Icons.collections_bookmark, size: 48))
                  : Image.file(File(cover), fit: BoxFit.cover, cacheWidth: (400 * dpr).round(),
                      errorBuilder: (_, _, _) => const Icon(Icons.collections_bookmark, size: 48)),
            ),
            // 권수 배지
            Positioned(
              right: 14,
              top: 6,
              child: _Pill(
                text: st.childSeries > 0 && st.direct == 0 ? '${st.allItems}' : '${st.direct}${s.total != null ? '/${s.total}' : ''}',
                color: scheme.primary,
                fg: scheme.onPrimary,
              ),
            ),
            if (s.status != SeriesStatus.unknown)
              Positioned(
                left: 6,
                top: 6,
                child: _Pill(
                  text: statusLabel(s.status),
                  color: s.status == SeriesStatus.completed ? Colors.green.shade700 : Colors.orange.shade800,
                  fg: Colors.white,
                ),
              ),
            if (st.allItems > 0 && st.finished > 0)
              Positioned(
                left: 0,
                right: 8,
                bottom: 0,
                child: LinearProgressIndicator(value: st.finished / st.allItems, minHeight: 4),
              ),
            if (selected) const _SelectedMark(),
          ]),
        ),
        const SizedBox(height: 6),
        Row(children: [
          Icon(st.childSeries > 0 ? Icons.folder_copy : Icons.folder, size: 16, color: scheme.primary),
          const SizedBox(width: 4),
          Expanded(child: Text(s.title, maxLines: 2, overflow: TextOverflow.ellipsis, style: Theme.of(context).textTheme.bodyMedium)),
        ]),
        Text(seriesSummary(s, st), maxLines: 1, overflow: TextOverflow.ellipsis, style: Theme.of(context).textTheme.bodySmall),
      ]),
    );
  }
}

class _Pill extends StatelessWidget {
  final String text;
  final Color color, fg;
  const _Pill({required this.text, required this.color, required this.fg});
  @override
  Widget build(BuildContext context) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
        decoration: BoxDecoration(color: color, borderRadius: BorderRadius.circular(10)),
        child: Text(text, style: TextStyle(fontSize: 11, fontWeight: FontWeight.w700, color: fg)),
      );
}

class _SelectedMark extends StatelessWidget {
  const _SelectedMark();
  @override
  Widget build(BuildContext context) => Positioned.fill(
        child: Container(
          decoration: BoxDecoration(
            color: Theme.of(context).colorScheme.primary.withValues(alpha: 0.25),
            border: Border.all(color: Theme.of(context).colorScheme.primary, width: 3),
            borderRadius: BorderRadius.circular(8),
          ),
          alignment: Alignment.topRight,
          padding: const EdgeInsets.all(6),
          child: Icon(Icons.check_circle, color: Theme.of(context).colorScheme.primary),
        ),
      );
}

/// 낱권 카드에서도 쓰는 선택 표시
Widget selectedOverlay() => const _SelectedMark();

// =====================================================================
//  묶음 안에 들어왔을 때 위쪽 머리글: 경로 + 권수/연재 상태 + 이어읽기
// =====================================================================
class SeriesHeader extends StatelessWidget {
  const SeriesHeader({super.key});

  @override
  Widget build(BuildContext context) {
    final state = context.watch<AppState>();
    final s = state.currentSeries;
    if (s == null) return const SizedBox();
    final st = state.statsOf(s);
    final next = state.nextToRead(s.id!);
    final text = Theme.of(context).textTheme;

    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 4, 12, 4),
      child: Card(
        margin: EdgeInsets.zero,
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            // 경로: 전체 › 명탐정 코난 › 외전
            SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: Row(children: [
                TextButton.icon(
                  style: TextButton.styleFrom(visualDensity: VisualDensity.compact),
                  onPressed: () => state.enterSeries(null),
                  icon: const Icon(Icons.home, size: 18),
                  label: const Text('전체'),
                ),
                for (final b in state.breadcrumb) ...[
                  const Icon(Icons.chevron_right, size: 18),
                  TextButton(
                    style: TextButton.styleFrom(visualDensity: VisualDensity.compact),
                    onPressed: b.id == s.id ? null : () => state.enterSeries(b.id),
                    child: Text(b.title),
                  ),
                ],
              ]),
            ),
            const SizedBox(height: 4),
            Wrap(spacing: 8, runSpacing: 8, crossAxisAlignment: WrapCrossAlignment.center, children: [
              Text(s.title, style: text.titleLarge),
              if (s.status != SeriesStatus.unknown)
                Chip(
                  visualDensity: VisualDensity.compact,
                  label: Text(statusLabel(s.status)),
                  backgroundColor: s.status == SeriesStatus.completed ? Colors.green.shade100 : Colors.orange.shade100,
                ),
              Chip(visualDensity: VisualDensity.compact, label: Text(_countText(s, st))),
              if (s.author != null && s.author!.isNotEmpty) Text(s.author!, style: text.bodyMedium),
            ]),
            if (s.description != null && s.description!.isNotEmpty)
              Padding(
                padding: const EdgeInsets.only(top: 4),
                child: Text(s.description!, maxLines: 2, overflow: TextOverflow.ellipsis, style: text.bodySmall),
              ),
            const SizedBox(height: 8),
            Wrap(spacing: 8, runSpacing: 8, children: [
              if (next != null)
                FilledButton.icon(
                  onPressed: () => openItem(context, next, siblings: state.volumesOf(s.id!)),
                  icon: Icon(st.isVideo ? Icons.play_arrow : Icons.chrome_reader_mode),
                  label: Text('${next.progress > 0 ? '이어서' : '처음부터'} ${next.volumeLabel ?? next.title}'),
                ),
              OutlinedButton.icon(
                onPressed: () => showSeriesEditor(context, s),
                icon: const Icon(Icons.edit),
                label: const Text('묶음 정보'),
              ),
              if (state.ai.enabled)
                OutlinedButton.icon(
                  onPressed: () => _aiFill(context, s),
                  icon: const Icon(Icons.auto_awesome),
                  label: const Text('AI로 권수/상태 채우기'),
                ),
            ]),
          ]),
        ),
      ),
    );
  }

  static String _countText(Series s, SeriesStats st) {
    final parts = <String>[];
    if (st.direct > 0 || st.childSeries == 0) {
      parts.add(s.total != null ? '보유 ${st.direct}${st.unit} / 총 ${s.total}${st.unit}' : '보유 ${st.direct}${st.unit}');
      if (s.total != null && s.total! > st.direct) parts.add('${s.total! - st.direct}${st.unit} 없음');
    }
    if (st.childSeries > 0) parts.add('하위 묶음 ${st.childSeries}개 · 전체 ${st.allItems}${st.unit}');
    if (st.finished > 0) parts.add('${st.finished}${st.unit} 완독');
    return parts.join(' · ');
  }

  Future<void> _aiFill(BuildContext context, Series s) async {
    final messenger = ScaffoldMessenger.of(context);
    messenger.showSnackBar(const SnackBar(content: Text('AI 에게 묻는 중…')));
    try {
      await context.read<AppState>().fillSeriesWithAi(s);
      messenger.showSnackBar(const SnackBar(content: Text('묶음 정보를 채웠습니다. 틀리면 "묶음 정보"에서 고치세요.')));
    } catch (e) {
      messenger.showSnackBar(SnackBar(content: Text('실패: $e')));
    }
  }
}

// =====================================================================
//  여러 개 선택했을 때 위쪽 막대
// =====================================================================
class SelectionBar extends StatelessWidget {
  const SelectionBar({super.key});

  @override
  Widget build(BuildContext context) {
    final state = context.watch<AppState>();
    final scheme = Theme.of(context).colorScheme;
    return Container(
      margin: const EdgeInsets.fromLTRB(12, 8, 12, 4),
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(color: scheme.secondaryContainer, borderRadius: BorderRadius.circular(12)),
      child: Wrap(spacing: 4, runSpacing: 4, crossAxisAlignment: WrapCrossAlignment.center, children: [
        IconButton(tooltip: '선택 취소', icon: const Icon(Icons.close), onPressed: state.clearSelection),
        Text('${state.selected.length}개 선택', style: Theme.of(context).textTheme.titleSmall),
        const SizedBox(width: 8),
        TextButton.icon(onPressed: state.selectAll, icon: const Icon(Icons.select_all), label: const Text('전체 선택')),
        FilledButton.tonalIcon(
          onPressed: () async {
            final title = await askText(context, '새 묶음 이름', hint: '예) 명탐정 코난');
            if (title != null && title.isNotEmpty) await state.groupSelected(title);
          },
          icon: const Icon(Icons.create_new_folder),
          label: const Text('묶기'),
        ),
        FilledButton.tonalIcon(
          onPressed: () async {
            final target = await pickSeries(context, title: '어느 묶음으로 옮길까요?');
            if (target == null) return;
            final failed = await state.moveSelected(target.id);
            if (failed > 0 && context.mounted) {
              ScaffoldMessenger.of(context)
                  .showSnackBar(SnackBar(content: Text('$failed개 묶음은 자기 안으로 옮길 수 없어 건너뛰었습니다')));
            }
          },
          icon: const Icon(Icons.drive_file_move),
          label: const Text('다른 묶음으로'),
        ),
        if (state.currentSeriesId != null)
          TextButton.icon(
            onPressed: state.ungroupSelected,
            icon: const Icon(Icons.outbox),
            label: const Text('묶음에서 빼기'),
          ),
      ]),
    );
  }
}

// =====================================================================
//  대화상자
// =====================================================================

Future<String?> askText(BuildContext context, String title, {String? hint, String? initial}) {
  final c = TextEditingController(text: initial);
  return showDialog<String>(
    context: context,
    builder: (_) => AlertDialog(
      title: Text(title),
      content: TextField(
        controller: c,
        autofocus: true,
        decoration: InputDecoration(hintText: hint),
        onSubmitted: (v) => Navigator.pop(context, v.trim()),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: const Text('취소')),
        FilledButton(onPressed: () => Navigator.pop(context, c.text.trim()), child: const Text('확인')),
      ],
    ),
  );
}

/// 묶음 선택 결과. id == null 이면 "맨 위(묶음 없음)"
class SeriesChoice {
  final int? id;
  const SeriesChoice(this.id);
}

/// 묶음 트리에서 하나 고르기 (새 묶음 만들기 포함)
Future<SeriesChoice?> pickSeries(BuildContext context, {required String title, int? excludeSubtreeOf}) {
  return showDialog<SeriesChoice>(
    context: context,
    builder: (_) => _SeriesPicker(title: title, exclude: excludeSubtreeOf),
  );
}

class _SeriesPicker extends StatefulWidget {
  final String title;
  final int? exclude;
  const _SeriesPicker({required this.title, this.exclude});
  @override
  State<_SeriesPicker> createState() => _SeriesPickerState();
}

class _SeriesPickerState extends State<_SeriesPicker> {
  String _filter = '';

  @override
  Widget build(BuildContext context) {
    final state = context.watch<AppState>();
    final rows = <(Series, int)>[];
    void walk(int? parent, int depth) {
      final kids = [...?state.tree.children[parent]]..sort((a, b) => a.title.compareTo(b.title));
      for (final s in kids) {
        if (widget.exclude != null && state.isAncestor(widget.exclude!, s.id)) continue;
        rows.add((s, depth));
        walk(s.id, depth + 1);
      }
    }

    walk(null, 0);
    final f = _filter.toLowerCase();
    final shown = f.isEmpty ? rows : rows.where((r) => state.seriesPath(r.$1.id).toLowerCase().contains(f)).toList();

    return AlertDialog(
      title: Text(widget.title),
      content: SizedBox(
        width: 480,
        height: 460,
        child: Column(children: [
          TextField(
            decoration: const InputDecoration(prefixIcon: Icon(Icons.search), hintText: '묶음 찾기'),
            onChanged: (v) => setState(() => _filter = v),
          ),
          const SizedBox(height: 8),
          Expanded(
            child: ListView(children: [
              ListTile(
                leading: const Icon(Icons.home),
                title: const Text('맨 위 (묶음 없음)'),
                onTap: () => Navigator.pop(context, const SeriesChoice(null)),
              ),
              ListTile(
                leading: const Icon(Icons.create_new_folder),
                title: const Text('새 묶음 만들기…'),
                onTap: () async {
                  final name = await askText(context, '새 묶음 이름');
                  if (name == null || name.isEmpty || !context.mounted) return;
                  final parent = await pickSeries(context, title: '"$name" 을(를) 어디에 둘까요?');
                  if (parent == null) return;
                  final s = await state.createSeries(name, parentId: parent.id);
                  if (context.mounted) Navigator.pop(context, SeriesChoice(s.id));
                },
              ),
              const Divider(),
              for (final (s, depth) in shown)
                ListTile(
                  dense: true,
                  contentPadding: EdgeInsets.only(left: 16.0 + (f.isEmpty ? depth * 20 : 0), right: 16),
                  leading: const Icon(Icons.folder),
                  title: Text(f.isEmpty ? s.title : state.seriesPath(s.id)),
                  subtitle: Text(seriesSummary(s, state.statsOf(s))),
                  onTap: () => Navigator.pop(context, SeriesChoice(s.id)),
                ),
            ]),
          ),
        ]),
      ),
      actions: [TextButton(onPressed: () => Navigator.pop(context), child: const Text('취소'))],
    );
  }
}

/// 묶음 정보 편집: 제목, 작가, 총 권수, 연재 상태, 상위 묶음, 표지, 소개, 해제
Future<void> showSeriesEditor(BuildContext context, Series s) =>
    showDialog(context: context, builder: (_) => _SeriesEditor(s));

class _SeriesEditor extends StatefulWidget {
  final Series s;
  const _SeriesEditor(this.s);
  @override
  State<_SeriesEditor> createState() => _SeriesEditorState();
}

class _SeriesEditorState extends State<_SeriesEditor> {
  late final _title = TextEditingController(text: widget.s.title);
  late final _author = TextEditingController(text: widget.s.author);
  late final _total = TextEditingController(text: widget.s.total?.toString());
  late final _desc = TextEditingController(text: widget.s.description);
  late SeriesStatus _status = widget.s.status;
  late int? _parent = widget.s.parentId;
  late String? _cover = widget.s.coverPath;
  bool _busy = false;

  @override
  Widget build(BuildContext context) {
    final state = context.watch<AppState>();
    final s = widget.s;
    InputDecoration deco(String l) => InputDecoration(labelText: l, border: const OutlineInputBorder());

    return AlertDialog(
      title: const Text('묶음 정보'),
      content: SizedBox(
        width: 520,
        child: SingleChildScrollView(
          child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            if (_busy) const LinearProgressIndicator(),
            const SizedBox(height: 8),
            TextField(controller: _title, decoration: deco('제목')),
            const SizedBox(height: 12),
            TextField(controller: _author, decoration: deco('작가 / 감독')),
            const SizedBox(height: 12),
            TextField(
              controller: _total,
              keyboardType: TextInputType.number,
              decoration: deco('전체 권(화) 수 — 모르면 비워두기'),
            ),
            const SizedBox(height: 12),
            SegmentedButton<SeriesStatus>(
              segments: const [
                ButtonSegment(value: SeriesStatus.unknown, label: Text('모름')),
                ButtonSegment(value: SeriesStatus.ongoing, label: Text('연재중')),
                ButtonSegment(value: SeriesStatus.completed, label: Text('완결')),
                ButtonSegment(value: SeriesStatus.hiatus, label: Text('휴재')),
              ],
              selected: {_status},
              onSelectionChanged: (v) => setState(() => _status = v.first),
            ),
            const SizedBox(height: 12),
            ListTile(
              contentPadding: EdgeInsets.zero,
              leading: const Icon(Icons.account_tree),
              title: const Text('상위 묶음'),
              subtitle: Text(_parent == null ? '맨 위' : state.seriesPath(_parent)),
              trailing: const Icon(Icons.chevron_right),
              onTap: () async {
                final c = await pickSeries(context, title: '상위 묶음 선택', excludeSubtreeOf: s.id);
                if (c != null) setState(() => _parent = c.id);
              },
            ),
            ListTile(
              contentPadding: EdgeInsets.zero,
              leading: const Icon(Icons.image),
              title: const Text('대표 표지'),
              subtitle: Text(_cover == null ? '첫 권 표지 사용' : '직접 지정함'),
              trailing: Wrap(children: [
                if (_cover != null) IconButton(icon: const Icon(Icons.clear), onPressed: () => setState(() => _cover = null)),
                IconButton(
                  icon: const Icon(Icons.folder_open),
                  onPressed: () async {
                    final f = await FilePicker.pickFile(type: FileType.image);
                    if (f?.path == null) return;
                    final path = await state.covers.importLocal(f!.path!, 'series-${s.id}');
                    setState(() => _cover = path);
                  },
                ),
              ]),
            ),
            const SizedBox(height: 8),
            TextField(controller: _desc, maxLines: 3, decoration: deco('소개 / 메모')),
          ]),
        ),
      ),
      actions: [
        TextButton(
          style: TextButton.styleFrom(foregroundColor: Theme.of(context).colorScheme.error),
          onPressed: () async {
            final ok = await showDialog<bool>(
              context: context,
              builder: (_) => AlertDialog(
                title: const Text('묶음 해제'),
                content: const Text('묶음만 없어지고, 안에 있던 권과 하위 묶음은 한 단계 위로 나옵니다. 파일은 지워지지 않습니다.'),
                actions: [
                  TextButton(onPressed: () => Navigator.pop(context), child: const Text('취소')),
                  FilledButton(onPressed: () => Navigator.pop(context, true), child: const Text('해제')),
                ],
              ),
            );
            if (ok == true) {
              await state.deleteSeries(s);
              if (context.mounted) Navigator.pop(context);
            }
          },
          child: const Text('묶음 해제'),
        ),
        if (state.ai.enabled)
          TextButton(
            onPressed: () async {
              setState(() => _busy = true);
              try {
                await state.fillSeriesWithAi(s);
                setState(() {
                  _total.text = s.total?.toString() ?? '';
                  _status = s.status;
                  _author.text = s.author ?? '';
                  _desc.text = s.description ?? '';
                });
              } catch (e) {
                if (context.mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('AI 실패: $e')));
              } finally {
                if (mounted) setState(() => _busy = false);
              }
            },
            child: const Text('AI로 채우기'),
          ),
        TextButton(onPressed: () => Navigator.pop(context), child: const Text('취소')),
        FilledButton(
          onPressed: () async {
            String? v(TextEditingController c) => c.text.trim().isEmpty ? null : c.text.trim();
            s
              ..title = v(_title) ?? s.title
              ..author = v(_author)
              ..total = int.tryParse(_total.text.trim())
              ..description = v(_desc)
              ..status = _status
              ..coverPath = _cover;
            await state.saveSeries(s);
            if (_parent != s.parentId) await state.moveSeries(s, _parent);
            if (context.mounted) Navigator.pop(context);
          },
          child: const Text('저장'),
        ),
      ],
    );
  }
}
