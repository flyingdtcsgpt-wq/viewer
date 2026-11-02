import 'package:flutter_test/flutter_test.dart';
import 'package:media_shelf/services/natural_tts.dart';
import 'package:media_shelf/services/speakers.dart';

void main() {
  test('대사 뒤 서술에서 화자', () {
    expect(Speakers.after(' 민호가 속삭였다.'), '민호');
    expect(Speakers.after(' 수아는 고개를 저으며 대답했다.'), '수아');
    expect(Speakers.after(' 김 선생이 물었다.'), isNull); // 띄어 쓴 성+직함은 모름 → 기본 대사 음성
    expect(Speakers.after(' 그가 말했다.'), isNull); // 대명사는 화자로 보지 않음
    expect(Speakers.after(' 바람이 불었다.'), isNull); // 말하는 동사가 없음
  });

  test('대사 앞 서술에서 화자', () {
    expect(Speakers.before('풍차지기가 물었다. '), '풍차지기');
    expect(Speakers.before('지훈이 천천히 입을 열었다. '), '지훈');
  });

  test('문단 조각에서 화자 찾기', () {
    final segs = <(int, String)>[(1, '"무슨 일로 왔느냐."'), (0, ' 풍차지기가 물었다.')];
    expect(Speakers.speakerAt(segs, 0), '풍차지기');
    final segs2 = <(int, String)>[(0, '민호가 말했다. '), (1, '"노래를 들으러 왔어요."')];
    expect(Speakers.speakerAt(segs2, 1), '민호');
  });

  test('등장인물 목록', () {
    final paras = [
      '"정말이야." 민호가 속삭였다.',
      '"또 시작이네." 수아가 말했다.',
      '"정말이라니까." 민호가 외쳤다.',
      '"알았어." 수아는 대답했다.',
      '바람이 불었다.',
    ];
    final names = Speakers.scan(paras).map((e) => e.$1).toList();
    expect(names, containsAll(['민호', '수아']));
  });

  test('자연 음성 문장 나누기', () {
    final parts = chunkText('${'가' * 50}. ${'나' * 50}. ${'다' * 50}.', maxLen: 120);
    expect(parts.length, 2);
    expect(parts.every((x) => x.length <= 120), isTrue);
    final long = chunkText(List.filled(40, '아주 긴 문장').join(', '), maxLen: 120);
    expect(long.every((x) => x.length <= 121), isTrue);
    expect(NaturalTts.langOf('안녕하세요'), 'ko');
    expect(NaturalTts.langOf('Hello world.'), 'en');
    expect(preprocessText('가', 'ko'), startsWith('<ko>'));
  });
}
