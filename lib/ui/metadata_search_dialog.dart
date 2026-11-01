import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../app_state.dart';
import '../models/media_item.dart';

Future<BookMetadata?> showMetadataSearch(BuildContext context, String initialQuery) =>
    showDialog<BookMetadata>(context: context, builder: (_) => _MetadataSearchDialog(initialQuery));

class _MetadataSearchDialog extends StatefulWidget {
  final String initialQuery;
  const _MetadataSearchDialog(this.initialQuery);

  @override
  State<_MetadataSearchDialog> createState() => _MetadataSearchDialogState();
}

class _MetadataSearchDialogState extends State<_MetadataSearchDialog> {
  late final _q = TextEditingController(text: widget.initialQuery);
  List<BookMetadata> _results = [];
  bool _loading = false;

  @override
  void initState() {
    super.initState();
    if (widget.initialQuery.isNotEmpty) _search();
  }

  Future<void> _search() async {
    setState(() => _loading = true);
    final r = await context.read<AppState>().metadata.search(_q.text);
    if (!mounted) return;
    setState(() {
      _results = r;
      _loading = false;
    });
  }

  @override
  Widget build(BuildContext context) {
    final size = MediaQuery.sizeOf(context);
    return Dialog(
      insetPadding: const EdgeInsets.all(16),
      child: SizedBox(
        width: size.width.clamp(0, 720).toDouble(),
        height: size.height * 0.85,
        child: Column(children: [
          Padding(
            padding: const EdgeInsets.all(16),
            child: TextField(
              controller: _q,
              autofocus: true,
              onSubmitted: (_) => _search(),
              decoration: InputDecoration(
                labelText: '제목 / 저자 / ISBN',
                border: const OutlineInputBorder(),
                suffixIcon: IconButton(icon: const Icon(Icons.search), onPressed: _search),
              ),
            ),
          ),
          if (_loading) const LinearProgressIndicator(),
          Expanded(
            child: _results.isEmpty && !_loading
                ? const Center(child: Text('검색 결과가 없습니다'))
                : ListView.separated(
                    itemCount: _results.length,
                    separatorBuilder: (_, _) => const Divider(height: 1),
                    itemBuilder: (_, i) {
                      final m = _results[i];
                      return ListTile(
                        leading: SizedBox(
                          width: 48,
                          child: m.coverUrl == null
                              ? const Icon(Icons.book)
                              : Image.network(m.coverUrl!, fit: BoxFit.cover, errorBuilder: (_, _, _) => const Icon(Icons.book)),
                        ),
                        title: Text(m.title),
                        subtitle: Text(
                          [m.author, m.publisher, m.year?.toString(), m.isbn].whereType<String>().join(' · '),
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                        ),
                        trailing: Chip(label: Text(m.source, style: const TextStyle(fontSize: 11))),
                        onTap: () => Navigator.pop(context, m),
                      );
                    },
                  ),
          ),
          Align(
            alignment: Alignment.centerRight,
            child: Padding(
              padding: const EdgeInsets.all(8),
              child: TextButton(onPressed: () => Navigator.pop(context), child: const Text('취소')),
            ),
          ),
        ]),
      ),
    );
  }
}
