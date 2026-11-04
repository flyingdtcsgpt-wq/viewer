import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../app_state.dart';
import '../../models/entry.dart';
import '../../models/media_item.dart';
import '../batch_editor_page.dart';
import '../../services/ext_archive.dart';
import 'archive_tool_pages.dart';
import 'convert_tool_pages.dart';

/// 파일 도구 모음 (BookManager "파일 도구" 탭)
class ToolsPage extends StatelessWidget {
  const ToolsPage({super.key});

  /// 도구에 넘길 대상: 고른 것(묶음이면 안의 권 전부), 없으면 지금 보이는 목록
  static List<MediaItem> targets(AppState s) {
    final sel = s.selectedItemsDeep;
    if (sel.isNotEmpty) return sel;
    return s.entries.whereType<ItemEntry>().map((e) => e.item).toList();
  }

  @override
  Widget build(BuildContext context) {
    final state = context.watch<AppState>();
    final items = targets(state);
    final zips = items.where((e) => e.extension == '.cbz' || e.extension == '.zip').toList();
    final txts = items.where((e) => e.extension == '.txt').toList();
    void go(Widget w) => Navigator.push(context, MaterialPageRoute(builder: (_) => w));

    final pdfs = items.where((e) => e.extension == '.pdf').toList();
    final epubs = items.where((e) => e.extension == '.epub').toList();
    final images = items.where((e) => e.kind == MediaKind.image).toList();
    final comics = items.where((e) => e.extension == '.cbz' || e.extension == '.zip' || (ExtArchive.supported && ExtArchive.handles(e.path))).toList();
    final shrinkable = [...zips, ...images.where((e) => const {'.jpg', '.jpeg', '.png'}.contains(e.extension))];

    final groups = <(String, List<_Tool>)>[
      ('텍스트', [
        _Tool(Icons.description, '텍본 정리기', '${txts.length}개', Colors.blue, txts.isEmpty ? null : () => go(TxtCleanPage(items: txts)),
            sub: 'UTF-8 변환 · 공백/빈 줄 정리'),
        _Tool(Icons.translate, '텍스트 인코딩 변환', '${txts.length}개', Colors.indigo, txts.isEmpty ? null : () => go(TxtCleanPage(items: txts)),
            sub: 'CP949 → UTF-8'),
      ]),
      ('문서 변환', [
        _Tool(Icons.article, 'TXT → EPUB', '${txts.length}개', Colors.blueGrey, txts.isEmpty ? null : () => go(TxtToEpubPage(items: txts)),
            sub: '자동 목차 · 표지'),
        _Tool(Icons.document_scanner, 'PDF → 텍스트', '${pdfs.length}개', Colors.brown, pdfs.isEmpty ? null : () => go(PdfToTextPage(items: pdfs)),
            sub: '스캔본은 글자 인식 · TXT/EPUB 으로'),
        _Tool(Icons.image, '이미지 → PDF', '${comics.length + images.length}개', Colors.orange,
            comics.isEmpty && images.isEmpty ? null : () => go(ImageToPdfPage(items: [...comics, ...images])),
            sub: '만화 한 권 → PDF · 그림 여러 장 → PDF 하나'),
        _Tool(Icons.layers, 'PDF 나누기 · 합치기', '${pdfs.length}개', Colors.red, pdfs.isEmpty ? null : () => go(PdfSplitMergePage(items: pdfs)),
            sub: 'N쪽마다 · 쪽 범위 · 여러 파일 차례대로'),
      ]),
      ('압축 파일 · 이미지', [
        _Tool(Icons.inventory_2, '압축 파일 구조 정리', '${zips.length}개', Colors.deepPurple, zips.isEmpty ? null : () => go(FlattenToolPage(items: zips)),
            sub: '폴더 없애기 · 쓰레기 파일 제거'),
        _Tool(Icons.drive_file_rename_outline, '내부 파일명 변경', '${zips.length}개', Colors.teal, zips.isEmpty ? null : () => go(RenameToolPage(items: zips)),
            sub: '000, 001… 번호 · 순서 바꾸기'),
        _Tool(Icons.add_photo_alternate, '표지 추가 및 교체', '${zips.length}개', Colors.deepOrange, zips.isEmpty ? null : () => go(CoverToolPage(items: zips)),
            sub: '이미지 파일 · 인터넷 검색 · 책 안 이미지'),
        _Tool(Icons.photo_size_select_large, '이미지 해상도 변경', '${shrinkable.length}개', Colors.blueGrey,
            shrinkable.isEmpty ? null : () => go(ImageResizePage(items: shrinkable)),
            sub: '큰 그림 줄여 용량 아끼기 (만화 · 그림)'),
        _Tool(Icons.compress, 'EPUB 용량 최적화', '${epubs.length}개', Colors.green, epubs.isEmpty ? null : () => go(EpubOptimizePage(items: epubs)),
            sub: '삽화 줄이기 · 다시 압축'),
      ]),
      ('정보', [
        _Tool(Icons.edit_note, '메타데이터 관리', '${items.length}개', Colors.green, items.isEmpty ? null : () => go(BatchEditorPage(items: items)),
            sub: '여러 권 정보 한 번에'),
      ]),
    ];

    return Scaffold(
      appBar: AppBar(title: const Text('파일 도구')),
      body: ListView(padding: const EdgeInsets.all(24), children: [
        Text('파일을 정리하고 변환하거나 품질을 개선하는 도구입니다.', style: Theme.of(context).textTheme.bodyMedium),
        const SizedBox(height: 4),
        Text(
          state.selectedItemsDeep.isNotEmpty
              ? '대상: 목록에서 고른 ${items.length}개'
              : '대상: 지금 목록에 보이는 ${items.length}개 (목록에서 먼저 고르면 그것만 대상이 됩니다)',
          style: Theme.of(context).textTheme.bodySmall,
        ),
        const SizedBox(height: 8),
        const Row(children: [
          Icon(Icons.circle, size: 10, color: Colors.green),
          Text(' 사용 가능   '),
          Icon(Icons.circle, size: 10, color: Colors.orange),
          Text(' 지금 대상 중에 맞는 파일 없음'),
        ]),
        const Divider(height: 32),
        Wrap(spacing: 32, runSpacing: 24, children: [
          for (final (title, tools) in groups)
            SizedBox(
              width: 380,
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text(title, style: Theme.of(context).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w800)),
                const Divider(),
                for (final t in tools) t,
              ]),
            ),
        ]),
      ]),
    );
  }
}

class _Tool extends StatelessWidget {
  final IconData icon;
  final String title, count;
  final String? sub;
  final Color color;
  final VoidCallback? onTap;
  const _Tool(this.icon, this.title, this.count, this.color, this.onTap, {this.sub});

  @override
  Widget build(BuildContext context) {
    final ready = onTap != null;
    final soon = count.isEmpty;
    return Opacity(
      opacity: soon ? 0.45 : 1,
      child: ListTile(
        contentPadding: const EdgeInsets.symmetric(vertical: 4),
        leading: Container(
          width: 44,
          height: 44,
          decoration: BoxDecoration(color: color.withValues(alpha: 0.8), borderRadius: BorderRadius.circular(10)),
          child: Icon(icon, color: Colors.white),
        ),
        title: Text(title, style: const TextStyle(fontWeight: FontWeight.w700)),
        subtitle: sub == null ? null : Text(sub!),
        trailing: Row(mainAxisSize: MainAxisSize.min, children: [
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
            decoration: BoxDecoration(
              border: Border.all(color: soon ? Colors.grey : (ready ? Colors.green : Colors.orange)),
              borderRadius: BorderRadius.circular(4),
            ),
            child: Text(soon ? '준비 중' : (ready ? '사용 가능 · $count' : '대상 없음'),
                style: TextStyle(fontSize: 11, color: soon ? Colors.grey : (ready ? Colors.green : Colors.orange))),
          ),
          if (ready) const Icon(Icons.chevron_right),
        ]),
        onTap: onTap,
      ),
    );
  }
}
