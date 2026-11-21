import 'dart:io';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../edition.dart';
import '../services/settings.dart';
import 'store_import.dart';

/// 사용법 안내 (전체판 · 플레이스토어판 공통, 내용은 판과 기기에 맞춰 달라진다)
///
/// - 앱을 켜면(로그인하면) 뜬다. "다시 보지 않기" 를 누르면 그 뒤로는 뜨지 않는다 ([Settings.guideHidden]).
/// - 언제든 다시 볼 수 있다: 메뉴 › 사용법 안내, 위쪽 ? , 설정 › 정보 (여기서 "켤 때 보기" 도 다시 켤 수 있다).
/// [atStart]: 앱을 켤 때 저절로 뜬 것 ("다시 보지 않기" 단추를 보여 준다)
Future<void> showAppGuide(BuildContext context, {bool atStart = false}) {
  final narrow = MediaQuery.sizeOf(context).width < 700;
  if (narrow) {
    return Navigator.push(context, MaterialPageRoute(fullscreenDialog: true, builder: (_) => _GuidePage(atStart: atStart, dialog: false)));
  }
  return showDialog(
    context: context,
    builder: (_) => Dialog(
      clipBehavior: Clip.antiAlias,
      child: ConstrainedBox(constraints: const BoxConstraints(maxWidth: 640, maxHeight: 780), child: _GuidePage(atStart: atStart, dialog: true)),
    ),
  );
}

/// 홈 화면을 감싸 두면, 홈이 처음 나타날 때 안내를 띄운다 ("다시 보지 않기" 를 누르기 전까지 켤 때마다)
class GuideAtStart extends StatefulWidget {
  final Widget child;
  const GuideAtStart({super.key, required this.child});
  @override
  State<GuideAtStart> createState() => _GuideAtStartState();
}

class _GuideAtStartState extends State<GuideAtStart> {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || context.read<Settings>().guideHidden) return;
      showAppGuide(context, atStart: true);
    });
  }

  @override
  Widget build(BuildContext context) => widget.child;
}

class _Topic {
  final IconData icon;
  final String title;
  final List<(String, String)> lines; // (굵은 머리말, 설명) — 머리말이 비면 그냥 문단
  const _Topic(this.icon, this.title, this.lines);
}

const _storeTopics = [
  _Topic(Icons.add_circle_outline, '파일 넣기', [
    ('', 'ARARIFlex 는 내 기기에 있는 만화 · 책 · 영상 파일을 보는 앱입니다. 볼 파일은 직접 넣어 주세요. 넣는 방법은 세 가지입니다.'),
    ('가져오기', '홈 화면 위의 ＋ 를 누르고 "파일 고르기" 나 "폴더 통째로" 를 고릅니다. 폴더를 고르면 안의 폴더 구조까지 그대로 들어옵니다.'),
    ('공유', '파일 관리자 · 브라우저 · 메신저에서 파일을 길게 눌러 공유 › ARARIFlex 를 고릅니다.'),
    ('PC 에서 USB 로', 'PC 에 연결(파일 전송)한 뒤 내장 저장공간 › Android › data › com.arariflex.app › files › ARARIFlex 안의 만화 · 책 · 영상 폴더에 복사합니다. '
        '앱을 다시 열면 저절로 서재에 나타납니다.'),
    ('볼 수 있는 파일', '만화 CBZ · ZIP / 책 EPUB · PDF · TXT / 영상 MP4 · MKV · AVI 등'),
  ]),
  _Topic(Icons.folder_special_outlined, '복사 · 옮기기 · 지우기', [
    ('', '가져온 파일은 모두 앱 전용 "ARARIFlex 폴더" 에 들어가고, 앱은 이 폴더 안의 파일만 보여 줍니다.'),
    ('복사', '원래 있던 파일은 그대로 두고 ARARIFlex 폴더에 하나 더 만듭니다. 그만큼 저장공간을 더 씁니다.'),
    ('옮기기', 'ARARIFlex 폴더에 넣은 뒤 원래 있던 파일을 지웁니다. 저장공간을 아낄 수 있습니다.'),
    ('삭제', '앱에서 삭제하면 ARARIFlex 폴더 안의 그 파일이 지워집니다. "복사" 로 넣었던 파일이면 원래 있던 곳의 파일은 남아 있고, '
        '"옮기기" 나 USB 로 넣은 파일이면 하나뿐인 파일이 없어집니다.'),
    ('앱을 지울 때', 'ARARIFlex 폴더의 파일도 함께 지워집니다. 남기려면 지울 때 나오는 "앱 데이터 보관" 을 고르세요.'),
  ]),
  _Topic(Icons.home_outlined, '서재 둘러보기', [
    ('홈', '보던 작품(이어 보기)과 최근에 넣은 작품이 나옵니다. 표지를 누르면 바로 열리고, 길게 누르면 정보 · 평점 · 표지를 고칠 수 있습니다.'),
    ('만화 · 책 · 영상 탭', '화면 아래 탭으로 종류별 목록을 봅니다. 위에서 검색하고 정렬을 바꿀 수 있습니다.'),
    ('시리즈 묶음', '"코난 01권, 02권…" 처럼 이름이 이어지는 파일은 저절로 한 묶음이 됩니다. 묶음을 누르면 안의 권이 나옵니다.'),
    ('고르기', '목록에서 표지를 길게 누르면 선택됩니다. 여러 개를 골라 묶기 · 다른 묶음으로 옮기기 · 읽음 표시 · 삭제를 할 수 있습니다.'),
    ('☰ 메뉴', '왼쪽 위 ☰ 에서 즐겨찾기 · 최근 본 것 · 읽는 중 · 다 읽음 · 열람 기록 · 설정으로 갑니다.'),
  ]),
  _Topic(Icons.auto_stories_outlined, '만화 보기', [
    ('넘기기', '화면 왼쪽 · 오른쪽 가장자리를 누르거나 옆으로 밉니다. 가운데를 누르면 위아래 메뉴가 나타났다 사라집니다.'),
    ('한 손으로 볼 때', '⚙ 의 "누를 때 다음 쪽" 에서 오른손잡이(오른쪽을 누르면 다음) · 왼손잡이(왼쪽을 누르면 다음)를 고릅니다. 책 뷰어에도 같이 적용됩니다.'),
    ('확대', '두 손가락으로 벌리거나, 같은 자리를 두 번 누릅니다. 확대한 동안에는 한 손가락으로 끌어 움직이고, 두 번 누르면 원래 크기로 돌아옵니다.'),
    ('보기 방식', '위쪽 메뉴나 ⚙ 에서 한 장 · 두 장 · 스크롤(웹툰), 읽는 방향(오른쪽에서 왼쪽), 화면 맞춤을 바꿉니다.'),
    ('다음 권', '마지막 쪽에서 한 번 더 넘기면 다음 권으로 갈지 묻습니다. 다음 권이 없으면 "마지막 권입니다" 라고 알려 줍니다.'),
    ('눈 보호', '위쪽 "눈 보호" 단추를 누르면 푸른빛을 줄여 따뜻한 색으로 보여 줍니다. 세기와 밝기는 ⚙ 에서 조절합니다.'),
    ('볼륨 버튼', '설정 › 뷰어에서 볼륨 버튼으로 넘기기와 화면 켜 두기를 켤 수 있습니다.'),
  ]),
  _Topic(Icons.menu_book_outlined, '책 보기 (EPUB · TXT · PDF)', [
    ('넘기기', '화면 좌우 가장자리를 누르면 한 화면씩 넘어가고, 위아래로 밀어 읽을 수도 있습니다. 가운데를 누르면 메뉴가 나옵니다.'),
    ('글자 · 줄 간격', '위쪽 메뉴에서 글자 크기와 줄 간격을 바로 바꿉니다. 글꼴 · 문단 간격 · 본문 폭은 ⚙ 에 있습니다.'),
    ('어두운 화면 · 눈 보호', '"다크" 단추로 검은 바탕 ↔ 밝은 바탕을 바꾸고(PDF 는 색 뒤집기), "눈 보호" 단추로 푸른빛을 줄여 따뜻한 색으로 봅니다. 세피아 · 그린 같은 다른 테마와 눈 보호 세기는 ⚙ 에서 고릅니다.'),
    ('찾아가기', '아래 이동 막대를 끌면 책의 아무 곳으로 갑니다. 목차 · 책에서 찾기도 쓸 수 있고, 글자를 골라 형광펜을 칠해 둘 수도 있습니다.'),
    ('책갈피', '위쪽 책갈피 단추를 누르면 지금 보는 곳이 표시되고, 다시 누르면 지워집니다. 나중에 그 자리로 바로 갈 수 있습니다(바로 옆 책갈피 목록 단추를 누르면 목록이 뜨고, 고르면 그 자리로 갑니다). 읽던 위치는 책갈피 없이도 저절로 기억됩니다.'),
    ('읽던 곳', '읽던 위치는 저절로 기억되어 다음에 열면 이어서 나옵니다.'),
  ]),
  _Topic(Icons.movie_outlined, '영상 보기', [
    ('조작', '화면을 누르면 재생 · 일시정지와 탐색 막대가 나옵니다. 화면 왼쪽 · 오른쪽을 두 번 누르면 10초 뒤 · 앞으로 건너뜁니다.'),
    ('위쪽 메뉴', '재생 속도, 자막(자막 파일 불러오기 · 크기 · 싱크 맞추기), 오디오 트랙, A-B(구간 반복)을 고릅니다.'),
    ('A-B 구간 반복', '반복할 구간의 시작에서 한 번, 끝에서 한 번 누르면 그 사이를 되풀이합니다. 한 번 더 누르면 풀립니다.'),
    ('이어 보기', '보던 위치를 기억해 다음에 이어서 재생합니다.'),
  ]),
  _Topic(Icons.task_alt, '읽은 표시와 "보던 작품"', [
    ('', '끝까지 보면 저절로 "다 봄" 이 됩니다. 정보 화면이나 선택 막대에서 읽음 · 안 읽음으로 직접 바꿀 수도 있습니다.'),
    ('열람 기록', '☰ 메뉴 › 열람 기록에 작품을 연 날과 그때 본 곳이 남습니다. 같은 작품을 같은 날 여러 번 열어도 한 줄입니다.'),
    ('보던 작품에서 빼기', '홈의 "보던 작품" 카드 오른쪽 위 × 를 누르면 목록에서만 빠집니다. 읽던 위치는 그대로 남고, 다시 열면 돌아옵니다.'),
    ('설정', '살짝 열어만 본 작품을 넣지 않기, 다 본 권의 다음 권 보여 주기는 설정 › 일반에서 바꿉니다.'),
  ]),
  _Topic(Icons.privacy_tip_outlined, '광고와 개인정보', [
    ('광고', '무료로 제공하기 위해 목록 화면 아래와 앱을 켤 때 가끔 광고가 나옵니다. 만화 · 책 · 영상을 보는 동안에는 나오지 않습니다.'),
    ('내 파일과 기록', '회원 가입이 없고, 넣은 파일과 읽은 기록은 이 기기 안에만 있습니다. 자세한 내용은 설정 › 정보 › 개인정보 처리방침에 있습니다.'),
    ('저작권', 'ARARIFlex 는 콘텐츠를 제공하지 않는 뷰어입니다. 직접 구입했거나 이용 권한이 있는 파일만 넣어 주세요.'),
  ]),
];

/// 전체판 (PC · 안드로이드 직접 설치). [touch]: 손가락으로 쓰는 기기 (휴대폰 · 태블릿)
List<_Topic> _fullTopics(bool touch) => [
      _Topic(Icons.add_circle_outline, '작품 넣기 (관리자)', [
        ('', 'ARARIFlex 는 내 기기 · 내 폴더에 있는 책 · 만화 · 그림 · 영상을 모아 보는 서재입니다. 먼저 볼 것이 들어 있는 폴더를 알려 주세요.'),
        ('폴더 추가', touch
            ? '왼쪽 위 ☰ 메뉴 › 폴더 추가. 처음에는 "모든 파일 접근" 을 허용해야 폴더 안을 읽을 수 있습니다.'
            : '위쪽 빨간 ＋ 추가 › 폴더 추가. 찾은 파일 목록이 나오고, 체크한 것만 들어갑니다.'),
        ('추가 방식', '"원본 위치에 연결" 은 파일을 그 자리에 둔 채 목록에만 올립니다(기본). "라이브러리 폴더로 복사 · 이동" 은 정리 폴더에 사본을 만들거나 옮깁니다.'),
        ('파일 추가 · NAS', '파일만 골라 넣거나, NAS · WebDAV · 다른 PC 의 ARARIFlex 에서 받아 올 수도 있습니다.'),
        ('새 파일 찾기', touch ? '등록한 폴더에 파일을 더 넣었으면 ☰ 메뉴 › 다시 스캔.' : '등록한 폴더에 파일을 더 넣었으면 F5(다시 스캔)를 누릅니다.'),
        ('볼 수 있는 파일', '만화 CBZ · ZIP · CBR · RAR · 7Z(RAR · 7Z 는 PC) / 책 EPUB · PDF · TXT / 그림 / 영상 MP4 · MKV · AVI 등'),
      ]),
      _Topic(Icons.dashboard_outlined, '둘러보기 · 고르기', [
        if (touch) ...[
          ('열기 · 고르기', '표지를 누르면 열리고, 길게 누르면 선택됩니다. 선택하면 위에 묶기 · 다른 묶음으로 · 읽음 표시 · 정보 · 삭제가 나옵니다.'),
          ('화면', '아래 탭(홈 · 책 · 만화 · 그림 · 영상)과 왼쪽 위 ☰ 메뉴(즐겨찾기 · 읽는 중 · 폴더 · 묶음 · 설정)를 씁니다.'),
        ] else ...[
          ('열기 · 고르기', '한 번 클릭 = 고르기, 더블클릭(Enter) = 열기, Ctrl+클릭 = 여러 개, 오른쪽 클릭 = 메뉴. 고르면 위 작업 줄에 삭제 · 묶기 · 메타데이터 등이 나타납니다.'),
          ('화면', '왼쪽에서 모아보기 · 라이브러리 폴더 · 묶음 · 태그를 고르고, 아래 막대에서 격자 / 표 / 카드 보기와 표지 크기를 바꿉니다.'),
          ('단축키', 'Del 삭제, Esc 선택 해제 · 위로, Alt+← → 뒤로 · 앞으로, Ctrl+A 전체 선택, F5 다시 스캔.'),
        ],
        ('시리즈 묶음', '"코난 01권, 02권…" 처럼 이름이 이어지는 파일은 저절로 한 묶음이 됩니다. 직접 묶거나 다른 묶음으로 옮길 수도 있습니다.'),
        ('정보 고치기', '상세 화면에서 제목 · 저자 · 권수 · 태그 · 표지를 고치고, "인터넷에서 정보 가져오기" 로 책 정보를 채울 수 있습니다.'),
      ]),
      _Topic(Icons.delete_outline, '삭제할 때 — 무엇이 지워지나', [
        ('목록에서만 제거', 'ARARIFlex 목록에서만 빠지고 파일은 그대로 남습니다. 등록한 폴더 안의 파일이면 다시 스캔할 때 다시 나타납니다.'),
        ('파일까지 삭제', 'ARARIFlex 에 등록된 바로 그 파일을 지웁니다(삭제 창에 위치가 나옵니다). "원본 위치에 연결" 로 넣었다면 그 파일이 곧 원본입니다. '
            '"복사" 로 넣었다면 라이브러리 폴더 안의 사본만 지워지고, 복사해 온 원래 파일은 그대로 남습니다.'),
      ]),
      _Topic(Icons.auto_stories_outlined, '만화 보기', [
        if (touch) ...[
          ('넘기기', '화면 왼쪽 · 오른쪽 가장자리를 누르거나 옆으로 밉니다. 가운데를 누르면 위아래 메뉴가 나타났다 사라집니다.'),
          ('한 손으로 볼 때', '⚙ 의 "누를 때 다음 쪽" 에서 오른손잡이(오른쪽을 누르면 다음) · 왼손잡이(왼쪽을 누르면 다음)를 고릅니다. 책 뷰어에도 같이 적용됩니다.'),
          ('확대', '두 손가락으로 벌리거나 같은 자리를 두 번 누릅니다. 확대한 동안에는 한 손가락으로 끌어 움직이고, 두 번 누르면 원래 크기로 돌아옵니다.'),
        ] else ...[
          ('넘기기', '← → · Space · PgUp PgDn · 마우스 휠, 또는 화면 좌우를 클릭합니다. 가운데를 클릭하면 메뉴가 나타났다 사라집니다.'),
          ('확대', '더블클릭하거나 Ctrl+휠. 확대한 동안에는 끌어서 움직입니다. F = 전체화면, B = 책갈피.'),
        ],
        ('보기 방식', '위쪽 메뉴나 ⚙ 에서 한 장 · 두 장 · 스크롤(웹툰), 읽는 방향, 화면 맞춤, 넘김 효과를 바꿉니다.'),
        ('눈 보호', '위쪽 "눈 보호" 단추를 누르면 푸른빛을 줄여 따뜻한 색으로 보여 줍니다. 세기와 밝기는 ⚙ 에서 조절합니다.'),
        ('다음 권', '마지막 쪽에서 한 번 더 넘기면 다음 권으로 갈지 묻습니다. 다음 권이 없으면 "마지막 권입니다" 라고 알려 줍니다.'),
      ]),
      _Topic(Icons.image_outlined, '그림 보기', [
        ('보기 방식', '위쪽 단추(⇄)에서 고릅니다: 좌우로 넘기기 · 위아래로 넘기기(한 장씩) · 위아래로 이어 보기(그림을 세로로 이어 붙여 죽 내려 보기).'),
        ('확대 · 슬라이드쇼', touch
            ? '한 장씩 볼 때는 두 손가락이나 두 번 누르기로 확대합니다. ▶ 단추는 슬라이드쇼입니다.'
            : '한 장씩 볼 때는 더블클릭 · 휠(위아래로 넘길 때는 Ctrl+휠)로 확대합니다. Space 는 슬라이드쇼입니다.'),
      ]),
      _Topic(Icons.menu_book_outlined, '책 보기 (EPUB · TXT · PDF)', [
        ('넘기기', touch ? '화면 좌우 가장자리를 누르면 한 화면씩 넘어가고, 위아래로 밀어 읽을 수도 있습니다.' : '← → · Space · PgUp PgDn 으로 한 화면씩, 마우스 휠로 스크롤합니다.'),
        ('글자 · 줄 간격', '위쪽 메뉴에서 글자 크기와 줄 간격을 바로 바꿉니다. 글꼴 · 문단 간격 · 본문 폭 · 테마는 ⚙ 에 있습니다.'),
        ('어두운 화면 · 눈 보호', '"다크" 단추로 검은 바탕 ↔ 밝은 바탕을 바꾸고(PDF 는 색 뒤집기), "눈 보호" 단추로 푸른빛을 줄여 따뜻한 색으로 봅니다. 세기는 ⚙ 또는 설정 › 뷰어.'),
        ('찾아가기', '아래 이동 막대를 끌면 책의 아무 곳으로 갑니다. 목차 · 책에서 찾기, 글자를 골라 형광펜 · 복사 · 검색 · AI 뜻풀이도 쓸 수 있습니다.'),
        ('책갈피', '위쪽 책갈피 단추를 누르면 지금 보는 곳이 표시되고, 다시 누르면 지워집니다. 나중에 그 자리로 바로 갈 수 있습니다(바로 옆 책갈피 목록 단추를 누르면 목록이 뜨고, 고르면 그 자리로 갑니다). 읽던 위치는 책갈피 없이도 저절로 기억됩니다.'),
        ('소리 내어 읽기', 'TTS 단추를 누르면 읽어 줍니다. 설정 › 읽어주기에서 자연스러운 음성을 한 번 받아 두면 훨씬 듣기 좋습니다. '
            '인물별 목소리 · 취침 타이머 · 오디오북 파일로 저장도 여기서 합니다.'),
      ]),
      _Topic(Icons.movie_outlined, '영상 보기', [
        ('조작', touch
            ? '화면을 누르면 재생 · 일시정지와 탐색 막대가 나옵니다. 화면 왼쪽 · 오른쪽을 두 번 누르면 10초 뒤 · 앞으로 건너뜁니다.'
            : '화면에 마우스를 올리면 재생 · 탐색 막대가 나옵니다. Space = 재생 · 일시정지, ← → = 건너뛰기, F = 전체화면.'),
        ('위쪽 메뉴', '재생 속도, 자막(자막 파일 불러오기 · 크기 · 싱크 맞추기), 오디오 트랙, A-B(구간 반복)을 고릅니다.'),
        ('A-B 구간 반복', '반복할 구간의 시작에서 한 번, 끝에서 한 번 누르면 그 사이를 되풀이합니다. 한 번 더 누르면 풀립니다.'),
      ]),
      _Topic(Icons.task_alt, '읽은 표시와 "보던 작품"', [
        ('', '끝까지 보면 저절로 "다 봄" 이 됩니다. ${touch ? '선택 막대나 상세 화면' : '오른쪽 클릭 메뉴나 상세 화면'}에서 읽음 · 안 읽음으로 직접 바꿀 수도 있습니다.'),
        ('보던 작품에서 빼기', '홈의 "보던 작품" 카드 × 를 누르면 목록에서만 빠집니다. 읽던 위치는 남고, 다시 열면 돌아옵니다.'),
        ('설정', '살짝 열어만 본 작품을 넣지 않기, 다 본 권의 다음 권 보여 주기는 설정 › 일반에서 바꿉니다.'),
      ]),
      _Topic(Icons.lock_outline, '계정 · 숨김', [
        ('가족 계정', '관리자 메뉴에서 계정을 더 만들고, 계정마다 볼 수 있는 폴더 · 종류 · 묶음을 정할 수 있습니다. 읽은 기록은 계정마다 따로입니다.'),
        ('숨김', '관리자 메뉴에서 숨김 비밀번호를 정한 뒤, 숨길 것을 골라 "숨기기". 다시 보려면 검색창에 숨김 비밀번호를 입력하고 Enter 를 누릅니다.'),
        ('비밀번호를 잊었을 때', '데이터 폴더(설정 › 정보에 위치가 나옵니다)에 RESET_PASSWORD.txt 라는 빈 파일을 만들고 앱을 다시 켭니다.'),
      ]),
      _Topic(Icons.widgets_outlined, '그 밖의 기능', [
        ('공유 서버', '같은 Wi-Fi 의 다른 기기 브라우저나 OPDS · WebDAV 앱에서 이 서재를 볼 수 있습니다.${touch ? '' : ' …(더보기) › 공유 서버.'}'),
        ('파일 도구', 'TXT → EPUB, 스캔 PDF → 텍스트, 이미지 → PDF, PDF 나누기 · 합치기, 만화 해상도 줄이기 등.${touch ? '' : ' …(더보기) › 파일 도구.'}'),
        ('AI 도우미', '설정 › AI 도우미에 API 키를 넣으면 파일명 분석 · 태그 추천 · 뜻풀이 · 화자 분석을 쓸 수 있습니다.'),
        ('백업', '설정 › 정보 › 서재 백업 · 복원. 서재 목록 · 읽은 위치 · 설정을 파일 하나로 남깁니다(책 파일은 들어가지 않습니다).'),
        if (!touch) ('휴대용 모드', '포터블 zip 을 쓰면 모든 데이터가 앱 폴더 안에 저장되어 USB 로 다른 PC 에 그대로 옮길 수 있습니다.'),
      ]),
    ];

class _GuidePage extends StatelessWidget {
  final bool atStart, dialog;
  const _GuidePage({required this.atStart, required this.dialog});

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    final scheme = Theme.of(context).colorScheme;
    final settings = context.read<Settings>();
    final topics = kStore ? _storeTopics : _fullTopics(Platform.isAndroid || Platform.isIOS);
    // 머리말 색: 어두운 화면에서는 빨강을 조금 밝게 (작은 글씨가 잘 읽히게)
    final headColor = Theme.of(context).brightness == Brightness.dark ? Color.lerp(scheme.primary, Colors.white, 0.35)! : scheme.primary;

    final list = ListView(padding: const EdgeInsets.fromLTRB(12, 4, 12, 12), children: [
      Padding(
        padding: const EdgeInsets.fromLTRB(8, 4, 8, 10),
        child: Text('제목을 누르면 내용이 펼쳐집니다.', style: text.bodySmall?.copyWith(color: scheme.onSurfaceVariant)),
      ),
      for (final (i, t) in topics.indexed)
        Card(
          margin: const EdgeInsets.only(bottom: 8),
          clipBehavior: Clip.antiAlias,
          child: ExpansionTile(
            initiallyExpanded: i == 0,
            shape: const Border(),
            leading: Icon(t.icon, color: scheme.primary),
            title: Text('${i + 1}. ${t.title}', style: const TextStyle(fontWeight: FontWeight.w700)),
            childrenPadding: const EdgeInsets.fromLTRB(16, 0, 16, 14),
            expandedCrossAxisAlignment: CrossAxisAlignment.start,
            children: [
              for (final (head, body) in t.lines)
                Padding(
                  padding: const EdgeInsets.only(bottom: 8),
                  child: Text.rich(TextSpan(children: [
                    if (head.isNotEmpty) TextSpan(text: '$head  ', style: TextStyle(fontWeight: FontWeight.w700, color: headColor)),
                    TextSpan(text: body),
                  ]), style: text.bodyMedium?.copyWith(height: 1.45)),
                ),
              if (i == 0 && kStore)
                Align(
                  alignment: Alignment.centerLeft,
                  child: FilledButton.tonalIcon(
                    onPressed: () {
                      final nav = Navigator.of(context);
                      final root = nav.context;
                      nav.pop();
                      openStoreImport(root);
                    },
                    icon: const Icon(Icons.add),
                    label: const Text('지금 가져오기'),
                  ),
                ),
            ],
          ),
        ),
      Padding(
        padding: const EdgeInsets.fromLTRB(8, 4, 8, 0),
        child: Text('이 안내는 메뉴의 "사용법 안내", 또는 설정 › 정보에서 언제든 다시 볼 수 있습니다.',
            style: text.bodySmall?.copyWith(color: scheme.onSurfaceVariant)),
      ),
    ]);

    final footer = SafeArea(
      top: false,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
        child: Row(children: [
          if (atStart)
            TextButton(
              onPressed: () {
                settings.guideHidden = true;
                Navigator.pop(context);
              },
              child: const Text('다시 보지 않기'),
            ),
          const Spacer(),
          FilledButton(onPressed: () => Navigator.pop(context), child: Text(atStart ? '시작하기' : '닫기')),
        ]),
      ),
    );

    if (!dialog) {
      return Scaffold(
        appBar: AppBar(title: const Text('사용법 안내')),
        body: Column(children: [Expanded(child: list), const Divider(height: 1), footer]),
      );
    }
    return Column(children: [
      Padding(
        padding: const EdgeInsets.fromLTRB(24, 18, 12, 6),
        child: Row(children: [
          Expanded(child: Text('사용법 안내', style: text.titleLarge?.copyWith(fontWeight: FontWeight.w800))),
          IconButton(onPressed: () => Navigator.pop(context), icon: const Icon(Icons.close)),
        ]),
      ),
      Expanded(child: list),
      const Divider(height: 1),
      footer,
    ]);
  }
}
