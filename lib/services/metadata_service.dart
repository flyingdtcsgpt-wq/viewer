import 'dart:convert';

import 'package:http/http.dart' as http;

import '../models/media_item.dart';
import 'settings.dart';

/// 제목/저자/ISBN 으로 인터넷에서 책 정보를 찾는다.
/// - Google Books (키 없이도 동작, 키가 있으면 한도 증가)
/// - Open Library (무료)
/// - Kakao 책 검색 (한국 도서에 강함, REST 키 필요)
class MetadataService {
  final Settings settings;
  MetadataService(this.settings);

  Future<List<BookMetadata>> search(String query) async {
    final q = query.trim();
    if (q.isEmpty) return [];
    final isbn = q.replaceAll(RegExp(r'[^0-9Xx]'), '');
    final isIsbn = (isbn.length == 10 || isbn.length == 13) && isbn.length >= q.length - 4;

    final s = settings;
    final results = await Future.wait([
      if (s.sourceEnabled('kakao')) _safe(() => _kakao(isIsbn ? isbn : q, isIsbn)),
      if (s.sourceEnabled('naver')) _safe(() => _naver(isIsbn ? isbn : q, isIsbn)),
      if (s.sourceEnabled('google')) _safe(() => _google(isIsbn ? 'isbn:$isbn' : q)),
      if (s.sourceEnabled('openlibrary')) _safe(() => _openLibrary(isIsbn ? isbn : q, isIsbn)),
    ]);
    return results.expand((e) => e).toList();
  }

  Future<List<BookMetadata>> _safe(Future<List<BookMetadata>> Function() f) async {
    try {
      return await f().timeout(const Duration(seconds: 10));
    } catch (_) {
      return [];
    }
  }

  Future<List<BookMetadata>> _kakao(String q, bool isIsbn) async {
    if (settings.kakaoKey.isEmpty) return [];
    final uri = Uri.https('dapi.kakao.com', '/v3/search/book',
        {'query': q, 'size': '10', if (isIsbn) 'target': 'isbn'});
    final res = await http.get(uri, headers: {'Authorization': 'KakaoAK ${settings.kakaoKey}'});
    if (res.statusCode != 200) return [];
    final docs = (jsonDecode(res.body)['documents'] as List?) ?? [];
    return docs.map((d) {
      final isbns = (d['isbn'] as String? ?? '').split(' ');
      return BookMetadata(
        source: 'Kakao',
        title: d['title'] ?? '',
        author: (d['authors'] as List?)?.join(', '),
        publisher: d['publisher'],
        isbn: isbns.lastWhere((s) => s.length == 13, orElse: () => isbns.first),
        year: int.tryParse((d['datetime'] as String? ?? '').split('-').first),
        description: d['contents'],
        coverUrl: (d['thumbnail'] as String?)?.isEmpty ?? true ? null : d['thumbnail'],
      );
    }).toList();
  }

  /// 네이버 책 검색 (developers.naver.com 에서 Client ID / Secret 발급)
  Future<List<BookMetadata>> _naver(String q, bool isIsbn) async {
    if (settings.naverId.isEmpty || settings.naverSecret.isEmpty) return [];
    final uri = Uri.https('openapi.naver.com', '/v1/search/book.json', {'query': q, 'display': '20'});
    final res = await http.get(uri, headers: {
      'X-Naver-Client-Id': settings.naverId,
      'X-Naver-Client-Secret': settings.naverSecret,
    });
    if (res.statusCode != 200) return [];
    String clean(dynamic v) => (v as String? ?? '').replaceAll(RegExp(r'<[^>]+>'), '').trim();
    final items = (jsonDecode(utf8.decode(res.bodyBytes))['items'] as List?) ?? [];
    return items.map((d) {
      final isbns = clean(d['isbn']).split(' ');
      final date = clean(d['pubdate']);
      return BookMetadata(
        source: 'Naver',
        title: clean(d['title']),
        author: clean(d['author']).replaceAll('^', ', '),
        publisher: clean(d['publisher']),
        isbn: isbns.where((s) => s.length == 13).firstOrNull ?? isbns.first,
        year: date.length >= 4 ? int.tryParse(date.substring(0, 4)) : null,
        description: clean(d['description']),
        coverUrl: clean(d['image']).isEmpty ? null : clean(d['image']),
      );
    }).toList();
  }

  Future<List<BookMetadata>> _google(String q) async {
    final params = {'q': q, 'maxResults': '10'};
    if (settings.googleBooksKey.isNotEmpty) params['key'] = settings.googleBooksKey;
    final res = await http.get(Uri.https('www.googleapis.com', '/books/v1/volumes', params));
    if (res.statusCode != 200) return [];
    final items = (jsonDecode(res.body)['items'] as List?) ?? [];
    return items.map((it) {
      final v = it['volumeInfo'] as Map<String, dynamic>;
      final ids = (v['industryIdentifiers'] as List?) ?? [];
      String? isbn = ids.where((e) => e['type'] == 'ISBN_13').map((e) => e['identifier'] as String).firstOrNull ??
          ids.where((e) => e['type'] == 'ISBN_10').map((e) => e['identifier'] as String).firstOrNull;
      String? cover = (v['imageLinks']?['thumbnail'] ?? v['imageLinks']?['smallThumbnail']) as String?;
      cover = cover?.replaceFirst('http://', 'https://').replaceFirst('&edge=curl', '');
      return BookMetadata(
        source: 'Google',
        title: [v['title'], v['subtitle']].whereType<String>().join(': '),
        author: (v['authors'] as List?)?.join(', '),
        publisher: v['publisher'],
        isbn: isbn,
        year: int.tryParse(((v['publishedDate'] as String?) ?? '').split('-').first),
        description: v['description'],
        coverUrl: cover,
      );
    }).toList();
  }

  Future<List<BookMetadata>> _openLibrary(String q, bool isIsbn) async {
    final res = await http.get(Uri.https('openlibrary.org', '/search.json',
        {isIsbn ? 'isbn' : 'q': q, 'limit': '10', 'fields': 'title,author_name,publisher,isbn,first_publish_year,cover_i'}));
    if (res.statusCode != 200) return [];
    final docs = (jsonDecode(res.body)['docs'] as List?) ?? [];
    return docs.map((d) {
      final coverId = d['cover_i'];
      return BookMetadata(
        source: 'OpenLibrary',
        title: d['title'] ?? '',
        author: (d['author_name'] as List?)?.join(', '),
        publisher: (d['publisher'] as List?)?.firstOrNull,
        isbn: (d['isbn'] as List?)?.cast<String>().where((s) => s.length == 13).firstOrNull,
        year: d['first_publish_year'],
        coverUrl: coverId == null ? null : 'https://covers.openlibrary.org/b/id/$coverId-L.jpg',
      );
    }).toList();
  }
}
