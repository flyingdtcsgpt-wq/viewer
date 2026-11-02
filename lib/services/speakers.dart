/// 대사를 누가 했는지 찾기 (오프라인 · 규칙 기반)
///
/// 한국 소설에 흔한 꼴을 본다:
///   "정말이야." 민호가 속삭였다.        ← 대사 뒤 서술
///   수아가 고개를 저으며 말했다. "아니." ← 대사 앞 서술
/// 이름 뒤 조사(이/가/은/는/께서) + 말하는 동사가 가까이 있으면 그 이름을 화자로 본다.
class Speakers {
  Speakers._();

  static const _verbs = r'(?:말했|말한|말하|물었|묻는|속삭|외쳤|외친|대답|답했|중얼|소리쳤|소리친|소리질|덧붙|되물|투덜|말을 이|입을 열|대꾸|반문|설명했|부르짖|웃으며|웃었|한숨|고함|소리를 질|다그쳤|재촉|중얼거|읊조|내뱉|타일렀|불렀|소리쳐|말끝을|쏘아붙|따졌|맞받|대답한|말씀하)';
  static const _particles = r'(?:이가|께서|가|이|은|는)';

  /// 이름처럼 보이지만 사람 이름이 아닌 말
  static const _stop = {
    '그', '그녀', '그는', '나', '내', '너', '네', '우리', '그들', '그녀들', '저', '제', '당신', '자네', '누군가', '누구',
    '아이', '아이들', '남자', '여자', '사람', '사람들', '모두', '다들', '둘', '셋', '하나', '목소리', '말', '소리', '대답',
    '그것', '이것', '저것', '그쪽', '이쪽', '상대', '상대방', '녀석', '놈', '그놈', '그분', '이분', '선생', '노인', '소년', '소녀',
  };

  static final _after = RegExp('^\\s*,?\\s*([가-힣]{1,6}?)$_particles\\s[^.!?"“”]{0,24}?$_verbs');
  static final _before = RegExp('([가-힣]{1,6}?)$_particles\\s[^.!?"“”]{0,24}?$_verbs[^.!?"“”]*[.:]?\\s*\$');
  static final _anywhere = RegExp('([가-힣]{1,6}?)$_particles\\s[^.!?"“”\\n]{0,24}?$_verbs');

  static String? _clean(String? n) {
    if (n == null) return null;
    final t = n.trim();
    if (t.isEmpty || _stop.contains(t)) return null;
    return t;
  }

  /// 대사 바로 뒤 서술에서 화자 ("…" 민호가 속삭였다)
  static String? after(String narration) => _clean(_after.firstMatch(narration)?.group(1));

  /// 대사 바로 앞 서술에서 화자 (민호가 말했다. "…")
  static String? before(String narration) => _clean(_before.firstMatch(narration)?.group(1));

  /// 문단 조각들 (종류 0 서술 / 1 대사 / 2 속마음) 중 [i] 번째 대사의 화자
  static String? speakerAt(List<(int, String)> segs, int i) {
    if (i + 1 < segs.length && segs[i + 1].$1 == 0) {
      final n = after(segs[i + 1].$2);
      if (n != null) return n;
    }
    if (i > 0 && segs[i - 1].$1 == 0) {
      final n = before(segs[i - 1].$2);
      if (n != null) return n;
    }
    return null;
  }

  /// 책 전체에서 등장인물 후보 (말하는 장면에 나온 횟수 순)
  static List<(String, int)> scan(Iterable<String> paragraphs, {int limit = 30}) {
    final count = <String, int>{};
    for (final t in paragraphs) {
      if (!t.contains('"') && !t.contains('“') && !t.contains('「')) continue;
      for (final m in _anywhere.allMatches(t)) {
        final n = _clean(m.group(1));
        if (n != null) count[n] = (count[n] ?? 0) + 1;
      }
    }
    final list = count.entries.where((e) => e.value >= 2 || count.length < 8).map((e) => (e.key, e.value)).toList()
      ..sort((a, b) => b.$2.compareTo(a.$2));
    return list.take(limit).toList();
  }
}
