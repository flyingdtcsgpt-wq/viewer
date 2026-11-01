import 'package:path/path.dart' as p;

import '../models/series.dart';

/// 파일명에서 "시리즈 제목 + 권/화 번호"를 뽑는다.
class ParsedName {
  final String title; // 시리즈 제목 후보 (권 번호 제외)
  final double? volume;
  final bool explicitVolume; // "3권", "vol.3", "E03" 처럼 확실한 표시가 있었는지
  final SeriesStatus statusHint; // 파일명에 (완결) 등이 있으면
  const ParsedName(this.title, this.volume, {this.explicitVolume = false, this.statusHint = SeriesStatus.unknown});

  @override
  String toString() => 'ParsedName($title, $volume, explicit=$explicitVolume)';
}

final _brackets = RegExp(r'\[[^\]]*\]|\([^)]*\)|\{[^}]*\}|【[^】]*】');
final _completed = RegExp(r'(\(|\[|\s)(완결|완|完|complete[d]?)(\)|\]|\s|$)', caseSensitive: false);
final _ongoing = RegExp(r'(\(|\[)(연재중?|미완|ongoing)(\)|\])', caseSensitive: false);

// 순서대로 시도 (앞쪽일수록 확실한 표시)
final _patterns = <(RegExp, bool)>[
  // S01E02 → "제목 시즌1" 의 2화
  (RegExp(r'^(.*?)[\s._\-]*s(\d{1,2})[\s._\-]*e(\d{1,4})', caseSensitive: false), true),
  // 제3권, 3권, 3화, 3편, 03巻, 3話
  (RegExp(r'^(.*?)[\s._\-]*제?\s*(\d{1,4}(?:\.\d)?)\s*(?:권|화|편|부|巻|話|卷)'), true),
  // vol.3, v03, volume 3, #3, ep3, e03, chapter 3, ch.3
  // (앞에 구분자가 있어야 함: "Code 3" 의 e 를 오인하지 않도록)
  (RegExp(r'^(.*?)[\s._\-]+(?:vol(?:ume)?|v|#|ep(?:isode)?|e|ch(?:apter)?)\.?\s*(\d{1,4}(?:\.\d)?)(?!\d)', caseSensitive: false), true),
  // "제목 03" / "제목_003" / "제목-3" (끝에 붙은 숫자)
  (RegExp(r'^(.*?)[\s._\-]+(\d{1,4}(?:\.\d)?)$'), false),
  // "제목03" (띄어쓰기 없이 끝에 숫자, 3자리 이하)
  (RegExp(r'^(.*?\D)(\d{1,3})$'), false),
];

ParsedName parseName(String pathOrName) {
  final raw = p.basenameWithoutExtension(pathOrName);
  final status = _completed.hasMatch(raw)
      ? SeriesStatus.completed
      : (_ongoing.hasMatch(raw) ? SeriesStatus.ongoing : SeriesStatus.unknown);

  // [작가] (스캔) 같은 꼬리표 제거, 구분자 정리
  var name = raw.replaceAll(_brackets, ' ').replaceAll('_', ' ').replaceAll(RegExp(r'\s+'), ' ').trim();
  // "1-5권" 같은 합본 범위는 앞 번호만
  name = name.replaceAllMapped(RegExp(r'(\d+)\s*[-~]\s*\d+\s*(권|화)'), (m) => '${m[1]}${m[2]}');

  for (final (re, explicit) in _patterns) {
    final m = re.firstMatch(name);
    if (m == null) continue;
    var title = _cleanTitle(m.group(1)!);
    double? vol;
    if (m.groupCount >= 3 && m.group(3) != null) {
      // S01E02
      final season = int.parse(m.group(2)!);
      vol = double.tryParse(m.group(3)!);
      if (season > 1) title = '$title 시즌$season';
    } else {
      vol = double.tryParse(m.group(2)!);
    }
    // 연도(1950~2099)로 보이는 4자리 숫자는 권 번호가 아님
    if (!explicit && vol != null && vol >= 1950 && vol <= 2099) continue;
    if (title.isEmpty) continue;
    return ParsedName(title, vol, explicitVolume: explicit, statusHint: status);
  }
  return ParsedName(_cleanTitle(name), null, statusHint: status);
}

String _cleanTitle(String s) =>
    s.replaceAll(RegExp(r'[\s._\-~:]+$'), '').replaceAll(RegExp(r'^[\s._\-~:]+'), '').trim();

/// 비교용 키: 공백/기호 제거, 소문자
String normalizeTitle(String s) => s.toLowerCase().replaceAll(RegExp(r'[\s._\-~:·!?,()\[\]]+'), '');

/// B 가 A 의 파생 시리즈인가? ("명탐정 코난" → "명탐정 코난 제로의 일상")
bool isSpinOffOf(String parent, String child) {
  final a = parent.trim(), b = child.trim();
  if (a.length < 2 || b.length <= a.length) return false;
  if (!b.toLowerCase().startsWith(a.toLowerCase())) return false;
  final next = b.substring(a.length);
  return RegExp(r'^[\s:\-~:·(\[]').hasMatch(next);
}
