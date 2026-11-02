import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../app_state.dart';
import '../models/media_item.dart';
import '../services/series_parser.dart';
import 'cover_tile.dart';
import 'metadata_search_dialog.dart';

/// 메타데이터 일괄 편집 (BookManager "메타데이터 관리" 탭 방식)
/// 왼쪽: 책 목록(시리즈별, 체크) / 오른쪽: 원본(지금 책) · 일괄 편집(체크한 책 전부)
class BatchEditorPage extends StatefulWidget {
  final List<MediaItem> items;
  const BatchEditorPage({super.key, required this.items});

  @override
  State<BatchEditorPage> createState() => _BatchEditorPageState();
}

class _Field {
  final String key, label;
  final int lines;
  final bool number;
  const _Field(this.key, this.label, {this.lines = 1, this.number = false});
}

const _fields = [
  _Field('title', '제목'),
  _Field('series', '시리즈'),
  _Field('total', '전체권수', number: true),
  _Field('volume', '권 / 화', number: true),
  _Field('pages', '페이지수', number: true),
  _Field('author', '작가'),
  _Field('publisher', '출판사'),
  _Field('year', '연도', number: true),
  _Field('isbn', 'ISBN'),
  _Field('tags', '태그 (쉼표)'),
  _Field('description', '줄거리', lines: 5),
];

class _BatchEditorPageState extends State<BatchEditorPage> {
  late final AppState _app = context.read<AppState>();
  late final Set<MediaItem> _checked = {...widget.items};
  late MediaItem _cur = widget.items.first;
  final _orig = {for (final f in _fields) f.key: TextEditingController()};
  final _batch = {for (final f in _fields) f.key: TextEditingController()};
  bool _overwriteEmpty = false;
  bool _busy = false;
  String _status = '';

  @override
  void initState() {
    super.initState();
    _load(_cur);
  }

  @override
  void dispose() {
    for (final c in [..._orig.values, ..._batch.values]) {
      c.dispose();
    }
    super.dispose();
  }

  String _num(num? v) => v == null ? '' : (v == v.roundToDouble() ? v.toInt().toString() : v.toString());

  Map<String, String> _valuesOf(MediaItem e) => {
        'title': e.title,
        'series': _app.seriesById(e.seriesId)?.title ?? '',
        'total': _num(_app.seriesById(e.seriesId)?.total),
        'volume': _num(e.volume),
        'pages': _num(e.pages),
        'author': e.author ?? '',
        'publisher': e.publisher ?? '',
        'year': _num(e.year),
        'isbn': e.isbn ?? '',
        'tags': e.tags.join(', '),
        'description': e.description ?? '',
      };

  void _load(MediaItem e) {
    final v = _valuesOf(e);
    for (final f in _fields) {
      _orig[f.key]!.text = v[f.key]!;
    }
    setState(() => _cur = e);
  }

  /// 값 하나를 항목에 쓴다 (시리즈 / 전체권수는 묶음에)
  Future<void> _write(MediaItem e, String key, String value) async {
    final v = value.trim();
    String? opt() => v.isEmpty ? null : v;
    switch (key) {
      case 'title':
        if (v.isNotEmpty) e.title = v;
      case 'series':
        if (v.isEmpty) {
          if (e.seriesId != null) await _app.moveItems([e], null);
        } else if (_app.seriesById(e.seriesId)?.title != v) {
          await _app.moveToSeriesNamed([e], v);
        }
      case 'total':
        final s = _app.seriesById(e.seriesId);
        if (s != null) {
          s.total = int.tryParse(v);
          await _app.saveSeries(s);
        }
      case 'volume':
        e.volume = double.tryParse(v);
      case 'pages':
        e.pages = int.tryParse(v);
      case 'author':
        e.author = opt();
      case 'publisher':
        e.publisher = opt();
      case 'year':
        e.year = int.tryParse(v);
      case 'isbn':
        e.isbn = opt();
      case 'tags':
        e.tags = v.split(',').map((x) => x.trim()).where((x) => x.isNotEmpty).toSet().toList();
      case 'description':
        e.description = opt();
    }
  }

  Future<void> _run(String label, Future<void> Function() f) async {
    setState(() {
      _busy = true;
      _status = '$label…';
    });
    try {
      await f();
      _status = '$label 완료';
    } catch (e) {
      _status = '$label 실패: $e';
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  /// 지금 책 저장 (원본 칸)
  Future<void> _saveCurrent() => _run('저장', () async {
        // 시리즈를 먼저 정해야 전체권수가 그 묶음에 들어간다
        for (final k in ['series', ..._fields.map((f) => f.key).where((k) => k != 'series')]) {
          await _write(_cur, k, _orig[k]!.text);
        }
        await _app.save(_cur);
        _load(_cur);
      });

  /// 체크한 책 전부에 일괄 칸 적용 (비어 있는 칸은 건너뜀, "빈 값도 덮어쓰기"면 지움)
  Future<void> _saveAll() => _run('모두 저장', () async {
        final keys = _fields.map((f) => f.key).where((k) => _overwriteEmpty ? k != 'title' : _batch[k]!.text.trim().isNotEmpty).toList();
        keys.sort((a, b) => a == 'series' ? -1 : (b == 'series' ? 1 : 0));
        if (keys.isEmpty) return;
        for (final e in _checked) {
          for (final k in keys) {
            await _write(e, k, _batch[k]!.text);
          }
          await _app.save(e);
        }
        _load(_cur);
      });

  // ---------- 자동 입력 ----------
  Future<void> _autoSeries() => _run('시리즈 자동 매칭', () async {
        final groups = <String, List<MediaItem>>{};
        for (final e in _checked) {
          final t = parseName(e.path).title;
          if (t.isNotEmpty) groups.putIfAbsent(t, () => []).add(e);
        }
        for (final g in groups.entries) {
          await _app.moveToSeriesNamed(g.value, g.key);
        }
        _load(_cur);
      });

  Future<void> _autoVolume() => _run('자동 권수 입력', () async {
        for (final e in _checked) {
          final v = parseName(e.path).volume;
          if (v != null) {
            e.volume = v;
            await _app.save(e);
          }
        }
        _load(_cur);
      });

  Future<void> _autoPages() => _run('자동 페이지 수 입력', () async {
        for (final e in _checked) {
          final n = await _app.covers.pageCount(e);
          if (n != null) {
            e.pages = n;
            await _app.save(e);
          }
        }
        _load(_cur);
      });

  Future<void> _autoTitle() => _run('자동 제목 입력', () async {
        for (final e in _checked) {
          final s = _app.seriesById(e.seriesId);
          if (s != null && e.volumeLabel != null) {
            e.title = '${s.title} ${e.volumeLabel}';
            await _app.save(e);
          }
        }
        _load(_cur);
      });

  /// 인터넷 검색 결과 → 원본 칸(지금 책) 또는 일괄 칸에 채우기
  Future<void> _searchOnline({required bool toBatch}) async {
    final q = (toBatch ? _batch['series']!.text : '').trim().isNotEmpty
        ? _batch['series']!.text
        : (_orig['isbn']!.text.isNotEmpty ? _orig['isbn']!.text : _orig['series']!.text.isNotEmpty ? _orig['series']!.text : _orig['title']!.text);
    final pick = await showMetadataSearch(context, q, title: toBatch ? '체크한 ${_checked.length}권에 적용' : _cur.title);
    if (pick == null) return;
    final m = pick.meta;
    final target = toBatch ? _batch : _orig;
    void put(String f, String k, String? v) {
      if (pick.fields.contains(f) && v != null && v.isNotEmpty) target[k]!.text = v;
    }

    if (!toBatch) put('title', 'title', m.title);
    put('author', 'author', m.author);
    put('publisher', 'publisher', m.publisher);
    if (!toBatch) put('isbn', 'isbn', m.isbn);
    put('year', 'year', m.year?.toString());
    put('description', 'description', m.description);
    if (pick.fields.contains('cover') && m.coverUrl != null && !toBatch) {
      await _run('표지 받기', () async {
        _cur.coverPath = await _app.covers.download(m.coverUrl!, _cur.path) ?? _cur.coverPath;
        await _app.save(_cur);
      });
    }
    setState(() => _status = toBatch ? '검색 결과를 일괄 칸에 채웠습니다. "모두 저장"을 누르세요.' : '검색 결과를 원본 칸에 채웠습니다. "저장"을 누르세요.');
  }

  void _step(int d) {
    final list = widget.items;
    final i = list.indexOf(_cur) + d;
    if (i >= 0 && i < list.length) _load(list[i]);
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final text = Theme.of(context).textTheme;
    final items = widget.items;

    // 왼쪽 목록: 시리즈별로
    final groups = <String, List<MediaItem>>{};
    for (final e in items) {
      groups.putIfAbsent(_app.seriesPath(e.seriesId), () => []).add(e);
    }

    final left = SizedBox(
      width: 320,
      child: Column(children: [
        SizedBox(height: 260, child: ClipRRect(borderRadius: BorderRadius.circular(6), child: CoverImage(item: _cur, fit: BoxFit.contain))),
        const SizedBox(height: 10),
        Material(
          color: scheme.primary.withValues(alpha: 0.25),
          borderRadius: BorderRadius.circular(6),
          child: CheckboxListTile(
            dense: true,
            title: const Text('전체 선택/해제', style: TextStyle(fontWeight: FontWeight.w700)),
            secondary: Text('${_checked.length}/${items.length}'),
            value: _checked.length == items.length,
            onChanged: (v) => setState(() => v == true ? _checked.addAll(items) : _checked.clear()),
          ),
        ),
        const SizedBox(height: 6),
        Expanded(
          child: Container(
            decoration: BoxDecoration(border: Border.all(color: scheme.surfaceContainerHighest), borderRadius: BorderRadius.circular(6)),
            child: ListView(children: [
              for (final g in groups.entries) ...[
                Padding(
                  padding: const EdgeInsets.fromLTRB(10, 10, 10, 4),
                  child: Row(children: [
                    const Icon(Icons.folder, size: 16, color: Color(0xFFFFC107)),
                    const SizedBox(width: 6),
                    Expanded(child: Text(g.key.isEmpty ? '(묶음 없음)' : g.key, style: const TextStyle(fontWeight: FontWeight.w800))),
                  ]),
                ),
                for (final e in g.value)
                  Material(
                    color: e == _cur ? scheme.primary.withValues(alpha: 0.3) : Colors.transparent,
                    child: InkWell(
                      onTap: () => _load(e),
                      child: Row(children: [
                        Checkbox(value: _checked.contains(e), onChanged: (v) => setState(() => v == true ? _checked.add(e) : _checked.remove(e))),
                        Expanded(
                          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                            Text(e.fileName, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontWeight: FontWeight.w600)),
                            Text(
                              [e.volumeLabel, if (e.pages != null) '${e.pages}p', e.author].whereType<String>().join(' · '),
                              style: text.bodySmall,
                            ),
                          ]),
                        ),
                      ]),
                    ),
                  ),
              ],
            ]),
          ),
        ),
      ]),
    );

    Widget row(_Field f) => Padding(
          padding: const EdgeInsets.only(bottom: 8),
          child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
            SizedBox(
              width: 86,
              child: Padding(padding: const EdgeInsets.only(top: 12), child: Text(f.label, textAlign: TextAlign.right, style: const TextStyle(fontWeight: FontWeight.w700))),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: TextField(
                controller: _orig[f.key],
                maxLines: f.lines,
                keyboardType: f.number ? const TextInputType.numberWithOptions(decimal: true) : null,
                decoration: const InputDecoration(isDense: true, border: OutlineInputBorder()),
              ),
            ),
            Column(children: [
              IconButton(
                tooltip: '원본 → 일괄',
                icon: const Icon(Icons.chevron_right),
                onPressed: () => _batch[f.key]!.text = _orig[f.key]!.text,
              ),
              IconButton(
                tooltip: '일괄 → 원본',
                icon: const Icon(Icons.chevron_left),
                onPressed: () => _orig[f.key]!.text = _batch[f.key]!.text,
              ),
            ]),
            Expanded(
              child: TextField(
                controller: _batch[f.key],
                maxLines: f.lines,
                enabled: f.key != 'title' || _checked.length <= 1,
                keyboardType: f.number ? const TextInputType.numberWithOptions(decimal: true) : null,
                decoration: InputDecoration(
                  isDense: true,
                  border: const OutlineInputBorder(),
                  hintText: f.key == 'title' && _checked.length > 1 ? '(여러 권은 "자동 제목 입력")' : null,
                ),
              ),
            ),
          ]),
        );

    final right = Column(children: [
      // 위: 검색 / 이전·다음 권 / 일괄 적용
      Wrap(spacing: 8, runSpacing: 8, crossAxisAlignment: WrapCrossAlignment.center, children: [
        FilledButton.icon(onPressed: _busy ? null : () => _searchOnline(toBatch: false), icon: const Icon(Icons.travel_explore), label: const Text('지금 책 정보 검색')),
        FilledButton.tonalIcon(onPressed: _busy ? null : () => _searchOnline(toBatch: true), icon: const Icon(Icons.library_add_check), label: const Text('시리즈 정보 검색 → 일괄 칸')),
        OutlinedButton.icon(onPressed: () => _step(-1), icon: const Icon(Icons.chevron_left), label: const Text('이전 권')),
        OutlinedButton.icon(onPressed: () => _step(1), icon: const Icon(Icons.chevron_right), label: const Text('다음 권')),
        Row(mainAxisSize: MainAxisSize.min, children: [
          Checkbox(value: _overwriteEmpty, onChanged: (v) => setState(() => _overwriteEmpty = v ?? false)),
          const Text('빈 값도 덮어쓰기'),
        ]),
      ]),
      const SizedBox(height: 10),
      Row(children: [
        const SizedBox(width: 96),
        Expanded(child: Center(child: Text('원본 (지금 책)', style: text.titleSmall?.copyWith(fontWeight: FontWeight.w800)))),
        const SizedBox(width: 48),
        Expanded(child: Center(child: Text('일괄 편집 (체크한 ${_checked.length}권)', style: text.titleSmall?.copyWith(fontWeight: FontWeight.w800)))),
      ]),
      const SizedBox(height: 8),
      Expanded(child: ListView(children: [for (final f in _fields) row(f)])),
      const Divider(),
      Wrap(spacing: 8, runSpacing: 8, crossAxisAlignment: WrapCrossAlignment.center, children: [
        FilledButton.icon(
          style: FilledButton.styleFrom(backgroundColor: const Color(0xFFF59E0B), foregroundColor: Colors.black),
          onPressed: _busy ? null : _autoSeries,
          icon: const Icon(Icons.auto_fix_high),
          label: const Text('시리즈 자동 매칭'),
        ),
        OutlinedButton(onPressed: _busy ? null : _autoTitle, child: const Text('자동 제목 입력')),
        OutlinedButton(onPressed: _busy ? null : _autoVolume, child: const Text('자동 권수 입력')),
        OutlinedButton(onPressed: _busy ? null : _autoPages, child: const Text('자동 페이지 수 입력')),
        const SizedBox(width: 16),
        FilledButton.icon(
          style: FilledButton.styleFrom(backgroundColor: const Color(0xFF16A34A)),
          onPressed: _busy ? null : _saveCurrent,
          icon: const Icon(Icons.save),
          label: const Text('저장 (Ctrl+S)'),
        ),
        FilledButton.icon(
          onPressed: _busy || _checked.isEmpty ? null : _saveAll,
          icon: const Icon(Icons.save_as),
          label: Text('모두 저장 · ${_checked.length}권 (Ctrl+Shift+S)'),
        ),
      ]),
    ]);

    return CallbackShortcuts(
      bindings: {
        const SingleActivator(LogicalKeyboardKey.keyS, control: true): _saveCurrent,
        const SingleActivator(LogicalKeyboardKey.keyS, control: true, shift: true): _saveAll,
      },
      child: Focus(
        autofocus: true,
        child: Scaffold(
          appBar: AppBar(
            title: Text('메타데이터 관리 · ${items.length}권'),
            bottom: _busy ? const PreferredSize(preferredSize: Size.fromHeight(4), child: LinearProgressIndicator()) : null,
          ),
          body: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(children: [
              Expanded(child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [left, const SizedBox(width: 16), Expanded(child: right)])),
              if (_status.isNotEmpty)
                Align(alignment: Alignment.centerLeft, child: Padding(padding: const EdgeInsets.only(top: 8), child: Text(_status, style: text.bodySmall))),
            ]),
          ),
        ),
      ),
    );
  }
}
