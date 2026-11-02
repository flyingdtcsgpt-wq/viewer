import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../app_state.dart';
import '../models/media_item.dart';

/// 통합검색 결과 + 적용할 항목
class MetaPick {
  final BookMetadata meta;
  final Set<String> fields;
  const MetaPick(this.meta, this.fields);
}

const metaFields = [
  ('cover', '표지'),
  ('title', '제목'),
  ('author', '저자'),
  ('publisher', '출판사'),
  ('isbn', 'ISBN'),
  ('year', '연도'),
  ('description', '줄거리'),
];

/// BookManager 스타일 통합검색 창: 왼쪽 결과 목록 / 오른쪽 상세 / 적용할 항목 고르기
Future<MetaPick?> showMetadataSearch(BuildContext context, String initialQuery, {String? title}) =>
    showDialog<MetaPick>(context: context, builder: (_) => _MetadataSearchDialog(initialQuery, title));

class _MetadataSearchDialog extends StatefulWidget {
  final String initialQuery;
  final String? title;
  const _MetadataSearchDialog(this.initialQuery, this.title);

  @override
  State<_MetadataSearchDialog> createState() => _MetadataSearchDialogState();
}

class _MetadataSearchDialogState extends State<_MetadataSearchDialog> {
  late final _q = TextEditingController(text: widget.initialQuery);
  List<BookMetadata> _results = [];
  int _sel = 0;
  bool _loading = false;
  String? _sourceFilter;
  final _fields = {for (final f in metaFields) f.$1};

  @override
  void initState() {
    super.initState();
    if (widget.initialQuery.isNotEmpty) WidgetsBinding.instance.addPostFrameCallback((_) => _search());
  }

  Future<void> _search() async {
    setState(() => _loading = true);
    final r = await context.read<AppState>().metadata.search(_q.text);
    if (!mounted) return;
    setState(() {
      _results = r;
      _sel = 0;
      _loading = false;
    });
  }

  /// AI 로 원제/정확한 검색어 찾기 (파일명이 지저분할 때)
  Future<void> _aiQuery() async {
    final app = context.read<AppState>();
    setState(() => _loading = true);
    try {
      final r = await app.ai.parseFileName(_q.text);
      final q = (r['query'] ?? r['title'] ?? '').toString();
      if (q.isNotEmpty) _q.text = q;
    } catch (_) {}
    await _search();
  }

  @override
  Widget build(BuildContext context) {
    final size = MediaQuery.sizeOf(context);
    final scheme = Theme.of(context).colorScheme;
    final text = Theme.of(context).textTheme;
    final ai = context.read<AppState>().ai.enabled;
    final sources = {for (final r in _results) r.source}.toList();
    final shown = _sourceFilter == null ? _results : _results.where((r) => r.source == _sourceFilter).toList();
    final cur = shown.isEmpty ? null : shown[_sel.clamp(0, shown.length - 1)];
    final wide = size.width >= 900;

    final list = Container(
      decoration: BoxDecoration(color: scheme.surfaceContainer, borderRadius: BorderRadius.circular(8)),
      child: shown.isEmpty
          ? Center(child: Text(_loading ? '검색 중…' : '검색 결과가 없습니다'))
          : ListView.builder(
              itemCount: shown.length,
              itemBuilder: (_, i) {
                final m = shown[i];
                final on = i == _sel;
                return Material(
                  color: on ? scheme.primary.withValues(alpha: 0.35) : Colors.transparent,
                  child: InkWell(
                    onTap: () => setState(() => _sel = i),
                    onDoubleTap: () => Navigator.pop(context, MetaPick(m, _fields)),
                    child: Padding(
                      padding: const EdgeInsets.all(10),
                      child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                        SizedBox(
                          width: 54,
                          height: 78,
                          child: ClipRRect(
                            borderRadius: BorderRadius.circular(3),
                            child: m.coverUrl == null
                                ? Container(color: scheme.surfaceContainerHigh, child: const Icon(Icons.book))
                                : Image.network(m.coverUrl!, fit: BoxFit.cover, errorBuilder: (_, _, _) => const Icon(Icons.book)),
                          ),
                        ),
                        const SizedBox(width: 12),
                        Expanded(
                          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                            Text(m.title, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontWeight: FontWeight.w800)),
                            if (m.description != null)
                              Text(m.description!, maxLines: 1, overflow: TextOverflow.ellipsis, style: text.bodySmall),
                            const SizedBox(height: 4),
                            Text(
                              [m.source, m.author, m.publisher, m.year?.toString()].whereType<String>().where((x) => x.isNotEmpty).join('  |  '),
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: text.bodySmall?.copyWith(color: const Color(0xFFFFB300)),
                            ),
                          ]),
                        ),
                      ]),
                    ),
                  ),
                );
              },
            ),
    );

    final detail = cur == null
        ? const SizedBox()
        : Container(
            padding: const EdgeInsets.all(18),
            decoration: BoxDecoration(color: scheme.surfaceContainer, borderRadius: BorderRadius.circular(8)),
            child: ListView(children: [
              Text(cur.title, style: text.headlineSmall?.copyWith(fontWeight: FontWeight.w900)),
              const SizedBox(height: 14),
              Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                SizedBox(
                  width: 190,
                  height: 270,
                  child: ClipRRect(
                    borderRadius: BorderRadius.circular(4),
                    child: cur.coverUrl == null
                        ? Container(color: scheme.surfaceContainerHigh, child: const Center(child: Text('표지 없음')))
                        : Image.network(cur.coverUrl!, fit: BoxFit.cover, errorBuilder: (_, _, _) => const Icon(Icons.book)),
                  ),
                ),
                const SizedBox(width: 18),
                Expanded(
                  child: Column(children: [
                    for (final (icon, label, value) in [
                      (Icons.person, '작가', cur.author),
                      (Icons.business, '출판사', cur.publisher),
                      (Icons.qr_code, 'ISBN', cur.isbn),
                      (Icons.event, '출간', cur.year?.toString()),
                      (Icons.public, '출처', cur.source),
                    ])
                      Container(
                        padding: const EdgeInsets.symmetric(vertical: 8),
                        decoration: BoxDecoration(border: Border(bottom: BorderSide(color: scheme.surfaceContainerHighest))),
                        child: Row(children: [
                          Icon(icon, size: 16, color: Colors.grey),
                          const SizedBox(width: 8),
                          SizedBox(width: 70, child: Text(label, style: text.bodySmall)),
                          Expanded(child: SelectableText(value ?? '-')),
                        ]),
                      ),
                  ]),
                ),
              ]),
              const SizedBox(height: 16),
              Text('줄거리', style: text.labelLarge?.copyWith(color: const Color(0xFFFFB300))),
              const SizedBox(height: 6),
              SelectableText(cur.description?.isNotEmpty == true ? cur.description! : '-', style: const TextStyle(height: 1.6)),
            ]),
          );

    return Dialog(
      insetPadding: const EdgeInsets.all(24),
      child: SizedBox(
        width: wide ? 1180 : size.width,
        height: size.height * 0.88,
        child: Padding(
          padding: const EdgeInsets.all(18),
          child: Column(children: [
            // 위: 제목 / AI 원제 찾기 / 검색창
            Wrap(spacing: 10, runSpacing: 10, crossAxisAlignment: WrapCrossAlignment.center, children: [
              Text(widget.title ?? '정보 가져오기', style: text.titleLarge?.copyWith(color: const Color(0xFF4FA3FF), fontWeight: FontWeight.w900)),
              if (ai) OutlinedButton.icon(onPressed: _loading ? null : _aiQuery, icon: const Icon(Icons.auto_fix_high), label: const Text('AI 원제 찾기')),
              SizedBox(
                width: wide ? 420 : double.infinity,
                child: TextField(
                  controller: _q,
                  autofocus: true,
                  onSubmitted: (_) => _search(),
                  decoration: const InputDecoration(isDense: true, border: OutlineInputBorder(), hintText: '제목 / 저자 / ISBN'),
                ),
              ),
              FilledButton.icon(onPressed: _loading ? null : _search, icon: const Icon(Icons.search), label: const Text('검색')),
            ]),
            const SizedBox(height: 8),
            // 출처 필터
            Row(children: [
              ChoiceChip(label: Text('전체 ${_results.length}'), selected: _sourceFilter == null, onSelected: (_) => setState(() => _sourceFilter = null)),
              for (final src in sources)
                Padding(
                  padding: const EdgeInsets.only(left: 6),
                  child: ChoiceChip(
                    label: Text('$src ${_results.where((r) => r.source == src).length}'),
                    selected: _sourceFilter == src,
                    onSelected: (_) => setState(() {
                      _sourceFilter = src;
                      _sel = 0;
                    }),
                  ),
                ),
            ]),
            if (_loading) const LinearProgressIndicator(),
            const SizedBox(height: 8),
            Expanded(
              child: wide
                  ? Row(children: [Expanded(flex: 5, child: list), const SizedBox(width: 12), Expanded(flex: 6, child: detail)])
                  : Column(children: [Expanded(child: list), if (cur != null) SizedBox(height: 300, child: detail)]),
            ),
            const SizedBox(height: 10),
            // 아래: 덮어쓸 항목 / 닫기 / 선택
            Row(children: [
              const Text('적용할 항목  '),
              Expanded(
                child: Wrap(spacing: 4, children: [
                  for (final (k, l) in metaFields)
                    FilterChip(
                      label: Text(l),
                      selected: _fields.contains(k),
                      onSelected: (v) => setState(() => v ? _fields.add(k) : _fields.remove(k)),
                    ),
                ]),
              ),
              TextButton.icon(onPressed: () => Navigator.pop(context), icon: const Icon(Icons.close), label: const Text('닫기')),
              const SizedBox(width: 8),
              FilledButton.icon(
                onPressed: cur == null ? null : () => Navigator.pop(context, MetaPick(cur, {..._fields})),
                icon: const Icon(Icons.check),
                label: const Text('선택'),
              ),
            ]),
          ]),
        ),
      ),
    );
  }
}
