import 'package:path/path.dart' as p;

enum MediaKind { book, comic, image, video }

/// 원본 파일을 어떻게 다루는지: 제자리 참조 / 라이브러리 폴더로 이동(또는 복사)
enum StorageMode { reference, managed }

const bookExts = {'.epub', '.pdf', '.txt', '.mobi', '.azw3', '.fb2', '.djvu'};
const comicExts = {'.cbz', '.zip', '.cbr', '.rar', '.cb7', '.7z'};
const imageExts = {'.jpg', '.jpeg', '.png', '.gif', '.webp', '.bmp', '.tif', '.tiff', '.heic', '.avif'};
const videoExts = {'.mp4', '.mkv', '.avi', '.mov', '.wmv', '.webm', '.m4v', '.ts', '.flv'};

MediaKind? kindForPath(String path) {
  final ext = p.extension(path).toLowerCase();
  if (bookExts.contains(ext)) return MediaKind.book;
  if (comicExts.contains(ext)) return MediaKind.comic;
  if (imageExts.contains(ext)) return MediaKind.image;
  if (videoExts.contains(ext)) return MediaKind.video;
  return null;
}

String kindLabel(MediaKind k) => switch (k) {
      MediaKind.book => '책',
      MediaKind.comic => '만화',
      MediaKind.image => '그림',
      MediaKind.video => '영상',
    };

class MediaItem {
  int? id;
  String path;
  MediaKind kind;
  StorageMode storage;
  String title;
  String? author;
  String? publisher;
  String? isbn;
  String? series;
  int? year;
  String? description;
  String? coverPath;
  List<String> tags;
  int rating; // 0~5
  bool favorite;
  int size;
  DateTime addedAt;
  bool missing; // 원본 파일이 사라졌는지
  double progress; // 0.0 ~ 1.0 읽은/본 비율
  String? position; // 뷰어별 위치 (텍스트 블록 번호, 페이지, 영상 ms)
  DateTime? lastOpened;

  MediaItem({
    this.id,
    required this.path,
    required this.kind,
    this.storage = StorageMode.reference,
    required this.title,
    this.author,
    this.publisher,
    this.isbn,
    this.series,
    this.year,
    this.description,
    this.coverPath,
    List<String>? tags,
    this.rating = 0,
    this.favorite = false,
    this.size = 0,
    DateTime? addedAt,
    this.missing = false,
    this.progress = 0,
    this.position,
    this.lastOpened,
  })  : tags = tags ?? [],
        addedAt = addedAt ?? DateTime.now();

  String get extension => p.extension(path).toLowerCase();
  String get fileName => p.basename(path);

  Map<String, Object?> toMap() => {
        if (id != null) 'id': id,
        'path': path,
        'kind': kind.name,
        'storage': storage.name,
        'title': title,
        'author': author,
        'publisher': publisher,
        'isbn': isbn,
        'series': series,
        'year': year,
        'description': description,
        'cover_path': coverPath,
        'tags': tags.join(','),
        'rating': rating,
        'favorite': favorite ? 1 : 0,
        'size': size,
        'added_at': addedAt.millisecondsSinceEpoch,
        'missing': missing ? 1 : 0,
        'progress': progress,
        'position': position,
        'last_opened': lastOpened?.millisecondsSinceEpoch,
      };

  factory MediaItem.fromMap(Map<String, Object?> m) => MediaItem(
        id: m['id'] as int?,
        path: m['path'] as String,
        kind: MediaKind.values.byName(m['kind'] as String),
        storage: StorageMode.values.byName(m['storage'] as String),
        title: m['title'] as String,
        author: m['author'] as String?,
        publisher: m['publisher'] as String?,
        isbn: m['isbn'] as String?,
        series: m['series'] as String?,
        year: m['year'] as int?,
        description: m['description'] as String?,
        coverPath: m['cover_path'] as String?,
        tags: ((m['tags'] as String?) ?? '')
            .split(',')
            .map((e) => e.trim())
            .where((e) => e.isNotEmpty)
            .toList(),
        rating: (m['rating'] as int?) ?? 0,
        favorite: (m['favorite'] as int?) == 1,
        size: (m['size'] as int?) ?? 0,
        addedAt: DateTime.fromMillisecondsSinceEpoch(m['added_at'] as int),
        missing: (m['missing'] as int?) == 1,
        progress: (m['progress'] as num?)?.toDouble() ?? 0,
        position: m['position'] as String?,
        lastOpened: m['last_opened'] == null ? null : DateTime.fromMillisecondsSinceEpoch(m['last_opened'] as int),
      );
}

/// 인터넷에서 가져온 책 정보 후보
class BookMetadata {
  final String source;
  final String title;
  final String? author;
  final String? publisher;
  final String? isbn;
  final int? year;
  final String? description;
  final String? coverUrl;

  const BookMetadata({
    required this.source,
    required this.title,
    this.author,
    this.publisher,
    this.isbn,
    this.year,
    this.description,
    this.coverUrl,
  });
}
