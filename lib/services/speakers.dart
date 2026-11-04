/// 대사를 누가 했는지 찾기 (오프라인 · 규칙 기반)
///
/// 한국 소설에 흔한 꼴을 본다:
///   "정말이야." 민호가 속삭였다.        ← 대사 뒤 서술
///   수아가 고개를 저으며 말했다. "아니." ← 대사 앞 서술
/// 이름 뒤 조사(이/가/은/는/께서) + 말하는 동사가 가까이 있으면 그 이름을 화자로 본다.
/// 영어 원서: "…," said Holmes. / Holmes said, "…" / Mr. Holmes asked. (호칭은 떼고 성으로 묶음: Sherlock Holmes = Holmes)
/// 화자가 안 적힌 대사가 대사만으로 이어지면 앞의 두 사람이 번갈아 말한 것으로 본다 ([alternate]).
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

  // ---- 영어 ----
  static const _enVerbs = r'(?:said|says|asked|asks|replied|answered|cried|whispered|shouted|muttered|murmured|exclaimed|added|continued|called|remarked|observed|returned|repeated|insisted|admitted|explained|snapped|growled|sighed|laughed|demanded|inquired|interrupted|declared|protested|began|went on)';
  static const _enName = r"((?:(?:Mr|Mrs|Ms|Dr|Prof|Sir|Lady|Lord|Miss|Captain|Colonel|Inspector|Doctor|Professor|Uncle|Aunt)\.?\s)?[A-Z][a-z'’]+(?:\s[A-Z][a-z'’]+){0,2})";
  static final _enAfterVerbFirst = RegExp('^\\s*,?\\s*(?:[a-z]+ly\\s+)?$_enVerbs\\s+$_enName');
  static final _enAfterNameFirst = RegExp('^\\s*,?\\s*$_enName\\s+(?:[a-z]+ly\\s+)?$_enVerbs\\b');
  static final _enBefore = RegExp('$_enName\\b[^.!?"“”]{0,40}?\\b$_enVerbs\\b[^.!?"“”]*[,:.]?\\s*\$');
  static final _enAny1 = RegExp('$_enName\\s+(?:[a-z]+ly\\s+)?$_enVerbs\\b');
  static final _enAny2 = RegExp('\\b$_enVerbs\\s+$_enName');
  static const _enStop = {
    'He', 'She', 'I', 'They', 'We', 'You', 'It', 'The', 'His', 'Her', 'Their', 'There', 'Then', 'And', 'But', 'This', 'That',
    'One', 'Someone', 'Everyone', 'Nobody', 'Somebody', 'A', 'An', 'My', 'Our', 'Your', 'What', 'When', 'Where', 'Why', 'How',
    'Yes', 'No', 'Oh', 'Well', 'Now', 'So', 'If', 'As', 'At', 'In', 'On', 'For', 'With', 'Who',
  };
  static final _title = RegExp(r'^(?:Mr|Mrs|Ms|Dr|Prof|Sir|Lady|Lord|Miss|Captain|Colonel|Inspector|Doctor|Professor|Uncle|Aunt)\.?\s+');

  /// 영어 이름 → 묶는 이름 (호칭 떼고 성: "Mr. Sherlock Holmes" → "Holmes")
  static String? _cleanEn(String? n) {
    if (n == null) return null;
    final t = n.trim().replaceFirst(_title, '');
    final words = t.split(RegExp(r'\s+')).where((w) => w.isNotEmpty).toList();
    // "Then Holmes said" 처럼 앞에 붙은 보통 낱말은 뗀다
    while (words.isNotEmpty && _enStop.contains(words.first)) {
      words.removeAt(0);
    }
    if (words.isEmpty) return null;
    final key = words.last.replaceAll(RegExp(r"['’]s$"), '');
    if (key.length < 2 || _enStop.contains(key)) return null;
    return key;
  }

  /// 대사 바로 뒤 서술에서 화자 ("…" 민호가 속삭였다 / "…," said Holmes)
  static String? after(String narration) =>
      _clean(_after.firstMatch(narration)?.group(1)) ??
      _cleanEn(_enAfterVerbFirst.firstMatch(narration)?.group(1)) ??
      _cleanEn(_enAfterNameFirst.firstMatch(narration)?.group(1));

  /// 대사 바로 앞 서술에서 화자 (민호가 말했다. "…" / Holmes said, "…")
  static String? before(String narration) => _clean(_before.firstMatch(narration)?.group(1)) ?? _cleanEn(_enBefore.firstMatch(narration)?.group(1));

  /// 문단의 대사 화자: 지문에서 찾으면 이름, 못 찾으면 null, 대사가 없는 문단이면 ''
  static String? paragraphSpeaker(List<(int, String)> segs) {
    var any = false;
    for (var k = 0; k < segs.length; k++) {
      if (segs[k].$1 != 1) continue;
      any = true;
      final n = speakerAt(segs, k);
      if (n != null) return n;
    }
    return any ? null : '';
  }

  /// 대사만 있는 문단인가 (서술은 문장부호 정도)
  static bool dialogueOnly(List<(int, String)> segs) =>
      segs.any((e) => e.$1 == 1) && segs.where((e) => e.$1 == 0).every((e) => e.$2.replaceAll(RegExp(r'[\s.,!?…—–-]'), '').isEmpty);

  /// 주고받는 대사: [back] 은 바로 앞 문단부터 거꾸로 (그 문단의 화자 · 대사만인가).
  /// 대사가 이어지는 동안 가장 가까운 알려진 화자 X 가 홀수 칸 앞이면 그 앞의 다른 사람 Y, 짝수 칸 앞이면 X.
  /// 대사 없는 문단이나 화자를 모르는 서술 섞인 문단을 만나면 확신이 없어 null.
  static String? alternate(List<(String?, bool)> back) {
    String? x, y;
    var dx = 0;
    for (var j = 0; j < back.length; j++) {
      final (who, only) = back[j];
      if (who == '') break;
      if (who != null) {
        if (x == null) {
          x = who;
          dx = j + 1;
        } else if (who != x) {
          y = who;
          break;
        }
      } else if (!only) {
        break;
      }
    }
    if (x == null) return null;
    return dx.isEven ? x : y;
  }

  /// 자동 배역: 인물 순위(말한 횟수 순)대로 서로 다른 목소리를 돌려 쓴다. 순위에 없는 이름은 이름으로 정해진 자리
  static String? autoVoice(String name, List<String> ranked, List<String> pool) {
    if (pool.isEmpty) return null;
    var i = ranked.indexOf(name);
    if (i < 0) i = name.codeUnits.fold(0, (a, b) => (a * 31 + b) & 0x7fffffff);
    return pool[i % pool.length];
  }

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
      for (final re in [_enAny1, _enAny2]) {
        for (final m in re.allMatches(t)) {
          final n = _cleanEn(m.group(1));
          if (n != null) count[n] = (count[n] ?? 0) + 1;
        }
      }
    }
    final list = count.entries.where((e) => e.value >= 2 || count.length < 8).map((e) => (e.key, e.value)).toList()
      ..sort((a, b) => b.$2.compareTo(a.$2));
    return list.take(limit).toList();
  }
}
