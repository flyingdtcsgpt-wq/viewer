/// 묶음(시리즈). 몇 단계든 중첩된다.
/// 예) 명탐정 코난 ─┬─ 명탐정 코난 (본편)      ─ 1권, 2권 …
///                  ├─ 제로의 일상            ─ 1권 …
///                  └─ 극장판                 ─ 1편, 2편 …
enum SeriesStatus { unknown, ongoing, completed, hiatus }

String statusLabel(SeriesStatus s) => switch (s) {
      SeriesStatus.unknown => '',
      SeriesStatus.ongoing => '연재중',
      SeriesStatus.completed => '완결',
      SeriesStatus.hiatus => '휴재',
    };

class Series {
  int? id;
  int? parentId;
  String title;
  String? author;
  String? description;
  String? coverPath; // 비어 있으면 첫 권 커버 사용
  int? total; // 전체 권(화) 수 — 알고 있을 때만
  SeriesStatus status;
  bool hidden; // 숨김이면 하위 묶음/권 전부 숨김
  DateTime addedAt;

  Series({
    this.id,
    this.parentId,
    required this.title,
    this.author,
    this.description,
    this.coverPath,
    this.total,
    this.status = SeriesStatus.unknown,
    this.hidden = false,
    DateTime? addedAt,
  }) : addedAt = addedAt ?? DateTime.now();

  Map<String, Object?> toMap() => {
        if (id != null) 'id': id,
        'parent_id': parentId,
        'title': title,
        'author': author,
        'description': description,
        'cover_path': coverPath,
        'total': total,
        'status': status.name,
        'hidden': hidden ? 1 : 0,
        'added_at': addedAt.millisecondsSinceEpoch,
      };

  factory Series.fromMap(Map<String, Object?> m) => Series(
        id: m['id'] as int?,
        parentId: m['parent_id'] as int?,
        title: m['title'] as String,
        author: m['author'] as String?,
        description: m['description'] as String?,
        coverPath: m['cover_path'] as String?,
        total: m['total'] as int?,
        status: SeriesStatus.values.asNameMap()[m['status'] as String? ?? ''] ?? SeriesStatus.unknown,
        hidden: (m['hidden'] as int?) == 1,
        addedAt: DateTime.fromMillisecondsSinceEpoch(m['added_at'] as int),
      );
}
