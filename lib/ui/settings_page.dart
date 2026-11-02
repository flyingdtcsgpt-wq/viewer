import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';
import 'package:provider/provider.dart';

import '../app_state.dart';
import '../models/media_item.dart';
import '../services/settings.dart';
import '../services/storage_permission.dart';
import '../version.dart';
import 'admin_page.dart';

/// 환경 설정 — 왼쪽 분류 / 오른쪽 내용 (BookManager 스타일)
/// PC 는 큰 창(대화상자), 휴대폰은 전체 화면
Future<void> showSettings(BuildContext context) {
  final wide = MediaQuery.sizeOf(context).width >= 900;
  if (!wide) return Navigator.push(context, MaterialPageRoute(builder: (_) => const SettingsPage()));
  return showDialog(
    context: context,
    builder: (_) => Dialog(
      insetPadding: const EdgeInsets.all(40),
      clipBehavior: Clip.antiAlias,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
      child: const SizedBox(width: 1180, height: 820, child: _SettingsView(inDialog: true)),
    ),
  );
}

class SettingsPage extends StatelessWidget {
  const SettingsPage({super.key});
  @override
  Widget build(BuildContext context) => const Scaffold(body: SafeArea(child: _SettingsView(inDialog: false)));
}

class _Cat {
  final IconData icon;
  final String title, sub;
  final bool adminOnly;
  const _Cat(this.icon, this.title, this.sub, {this.adminOnly = false});
}

const _cats = [
  _Cat(Icons.tune, '일반', '화면 표시 · 자동 묶기'),
  _Cat(Icons.folder_copy, '라이브러리', '폴더 · 그룹 · 별칭', adminOnly: true),
  _Cat(Icons.inventory_2, '파일 처리', '가져오기 · 정리 규칙', adminOnly: true),
  _Cat(Icons.chrome_reader_mode, '뷰어', '넘기기 · 맞춤 · 효과'),
  _Cat(Icons.search, '메타데이터 검색 및 API', '검색 서비스 · 인증 정보', adminOnly: true),
  _Cat(Icons.auto_awesome, 'AI 도우미', 'Claude API', adminOnly: true),
  _Cat(Icons.person, '계정 · 보안', '사용자 · 권한 · 숨김'),
  _Cat(Icons.info_outline, '정보', '버전 · 데이터 위치'),
];

class _SettingsView extends StatefulWidget {
  final bool inDialog;
  const _SettingsView({required this.inDialog});
  @override
  State<_SettingsView> createState() => _SettingsViewState();
}

class _SettingsViewState extends State<_SettingsView> {
  int _cat = 0;

  @override
  Widget build(BuildContext context) {
    final admin = context.watch<AppState>().isAdmin;
    final cats = [for (var i = 0; i < _cats.length; i++) if (admin || !_cats[i].adminOnly) i];
    if (!cats.contains(_cat)) _cat = cats.first;
    final narrow = MediaQuery.sizeOf(context).width < 700;
    final scheme = Theme.of(context).colorScheme;

    final header = Padding(
      padding: const EdgeInsets.fromLTRB(24, 18, 12, 10),
      child: Row(children: [
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text('환경 설정', style: Theme.of(context).textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w800)),
            Text('앱 표시와 파일 작업 환경을 설정합니다. 바꾸면 바로 저장됩니다.', style: Theme.of(context).textTheme.bodySmall),
          ]),
        ),
        IconButton(onPressed: () => Navigator.pop(context), icon: const Icon(Icons.close)),
      ]),
    );

    final catList = ListView(padding: const EdgeInsets.all(12), children: [
      for (final i in cats)
        Padding(
          padding: const EdgeInsets.only(bottom: 6),
          child: Material(
            color: i == _cat ? scheme.secondaryContainer : Colors.transparent,
            borderRadius: BorderRadius.circular(10),
            child: InkWell(
              borderRadius: BorderRadius.circular(10),
              onTap: () => setState(() => _cat = i),
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
                child: Row(children: [
                  Icon(_cats[i].icon, size: 22),
                  const SizedBox(width: 14),
                  Expanded(
                    child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                      Text(_cats[i].title, style: const TextStyle(fontWeight: FontWeight.w700)),
                      Text(_cats[i].sub, style: Theme.of(context).textTheme.bodySmall),
                    ]),
                  ),
                ]),
              ),
            ),
          ),
        ),
    ]);

    final content = switch (_cat) {
      0 => const _General(),
      1 => const _Library(),
      2 => const _FileHandling(),
      3 => const _Viewer(),
      4 => const _Sources(),
      5 => const _Ai(),
      6 => const _Account(),
      _ => const _About(),
    };

    return Column(children: [
      header,
      const Divider(height: 1),
      Expanded(
        child: narrow
            ? Column(children: [
                SizedBox(
                  height: 56,
                  child: ListView(scrollDirection: Axis.horizontal, padding: const EdgeInsets.symmetric(horizontal: 8), children: [
                    for (final i in cats)
                      Padding(
                        padding: const EdgeInsets.all(6),
                        child: ChoiceChip(label: Text(_cats[i].title), selected: i == _cat, onSelected: (_) => setState(() => _cat = i)),
                      ),
                  ]),
                ),
                Expanded(child: content),
              ])
            : Row(children: [
                SizedBox(width: 300, child: catList),
                const VerticalDivider(width: 1),
                Expanded(child: content),
              ]),
      ),
    ]);
  }
}

// ---------------- 공통 부품 ----------------

class _Page extends StatelessWidget {
  final String title;
  final String? desc;
  final List<Widget> children;
  const _Page(this.title, this.children, {this.desc});
  @override
  Widget build(BuildContext context) => ListView(padding: const EdgeInsets.fromLTRB(28, 22, 28, 28), children: [
        Text(title, style: Theme.of(context).textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w800)),
        if (desc != null) Padding(padding: const EdgeInsets.only(top: 6), child: Text(desc!, style: Theme.of(context).textTheme.bodySmall)),
        const SizedBox(height: 16),
        ...children,
      ]);
}

class _Card extends StatelessWidget {
  final Widget child;
  const _Card(this.child);
  @override
  Widget build(BuildContext context) => Container(
        margin: const EdgeInsets.only(bottom: 12),
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(
          color: Theme.of(context).colorScheme.surfaceContainer,
          borderRadius: BorderRadius.circular(10),
          border: Border.all(color: Theme.of(context).colorScheme.surfaceContainerHighest),
        ),
        child: child,
      );
}

class _TextSetting extends StatefulWidget {
  final String label;
  final String? help;
  final String value;
  final bool obscure;
  final ValueChanged<String> onSave;
  const _TextSetting({required this.label, this.help, required this.value, this.obscure = false, required this.onSave});
  @override
  State<_TextSetting> createState() => _TextSettingState();
}

class _TextSettingState extends State<_TextSetting> {
  late final _c = TextEditingController(text: widget.value);
  late bool _hide = widget.obscure;
  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 6),
        child: TextField(
          controller: _c,
          obscureText: _hide,
          onSubmitted: widget.onSave,
          onTapOutside: (_) => widget.onSave(_c.text.trim()),
          onChanged: widget.onSave,
          decoration: InputDecoration(
            labelText: widget.label,
            helperText: widget.help,
            border: const OutlineInputBorder(),
            suffixIcon: widget.obscure
                ? IconButton(icon: Icon(_hide ? Icons.visibility : Icons.visibility_off), onPressed: () => setState(() => _hide = !_hide))
                : null,
          ),
        ),
      );
}

Widget _seg<T>(String title, T value, List<(T, String)> options, ValueChanged<T> onChanged) => Padding(
      padding: const EdgeInsets.only(bottom: 14),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text(title, style: const TextStyle(fontWeight: FontWeight.w600)),
        const SizedBox(height: 6),
        SegmentedButton<T>(
          showSelectedIcon: false,
          segments: [for (final (v, l) in options) ButtonSegment(value: v, label: Text(l))],
          selected: {value},
          onSelectionChanged: (v) => onChanged(v.first),
        ),
      ]),
    );

// ---------------- 분류별 내용 ----------------

class _General extends StatelessWidget {
  const _General();
  @override
  Widget build(BuildContext context) {
    final s = context.watch<Settings>();
    return _Page('일반', [
      _Card(Column(children: [
        SwitchListTile(
          contentPadding: EdgeInsets.zero,
          title: const Text('밝은 화면'),
          subtitle: const Text('끄면 넷플릭스풍 어두운 화면'),
          value: s.lightMode,
          onChanged: (v) => s.lightMode = v,
        ),
        SwitchListTile(
          contentPadding: EdgeInsets.zero,
          title: const Text('시리즈 자동 묶기'),
          subtitle: const Text('스캔/가져오기 후 "명탐정 코난 01권" 같은 파일명을 보고 묶음으로 정리'),
          value: s.autoGroup,
          onChanged: (v) => s.autoGroup = v,
        ),
      ])),
      _Card(_seg<int>('기본 목록 보기', s.viewMode, const [(0, '표'), (1, '격자'), (2, '카드 목록')], (v) => s.viewMode = v)),
    ]);
  }
}

/// 라이브러리 폴더: 그룹 · 별칭 · 순서 (끌어서 순서 바꾸기)
class _Library extends StatefulWidget {
  const _Library();
  @override
  State<_Library> createState() => _LibraryState();
}

class _LibraryState extends State<_Library> {
  int? _sel;
  final _alias = TextEditingController();
  final _group = TextEditingController();

  void _select(int i, List<LibraryFolder> list) {
    setState(() => _sel = i);
    _alias.text = list[i].alias;
    _group.text = list[i].group;
  }

  void _saveSel(Settings s) {
    final list = s.libraryFolders;
    final i = _sel;
    if (i == null || i >= list.length) return;
    list[i]
      ..alias = _alias.text.trim()
      ..group = _group.text.trim();
    s.libraryFolders = list;
  }

  @override
  Widget build(BuildContext context) {
    final s = context.watch<Settings>();
    final state = context.read<AppState>();
    final list = s.libraryFolders;
    final scheme = Theme.of(context).colorScheme;

    // 미리보기: 그룹별로 묶어서
    final groups = <String, List<LibraryFolder>>{};
    for (final f in list) {
      groups.putIfAbsent(f.group, () => []).add(f);
    }

    return _Page(
      '라이브러리',
      desc: '책·만화·영상이 들어 있는 폴더를 등록합니다. NAS 나 외장 드라이브 폴더도 됩니다. 끌어서 순서를 바꾸고, 눌러서 별칭과 그룹을 정하세요.',
      [
        Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Expanded(
            flex: 3,
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Row(children: [
                const Text('등록 폴더', style: TextStyle(fontWeight: FontWeight.w700)),
                const Spacer(),
                FilledButton.icon(
                  onPressed: () async {
                    if (!await ensureStorageAccess(context)) return;
                    final dir = await FilePicker.getDirectoryPath(dialogTitle: '라이브러리 폴더 선택');
                    if (dir != null) await state.addWatchFolder(dir);
                  },
                  icon: const Icon(Icons.create_new_folder),
                  label: const Text('추가'),
                ),
              ]),
              const SizedBox(height: 8),
              Container(
                height: 380,
                decoration: BoxDecoration(border: Border.all(color: scheme.surfaceContainerHighest), borderRadius: BorderRadius.circular(8)),
                child: list.isEmpty
                    ? const Center(child: Text('아직 등록한 폴더가 없습니다'))
                    : ReorderableListView.builder(
                        buildDefaultDragHandles: false,
                        itemCount: list.length,
                        onReorderItem: (a, b) {
                          final l = [...list];
                          final x = l.removeAt(a);
                          l.insert(b, x);
                          s.libraryFolders = l;
                          setState(() => _sel = null);
                        },
                        itemBuilder: (_, i) {
                          final f = list[i];
                          final (dirs, files) = state.libraryCounts(f.path);
                          return Material(
                            key: ValueKey(f.path),
                            color: i == _sel ? scheme.secondaryContainer : Colors.transparent,
                            child: ListTile(
                              leading: ReorderableDragStartListener(index: i, child: const Icon(Icons.drag_indicator)),
                              title: Text(f.name + (f.group.isNotEmpty ? '   · ${f.group}' : ''), style: const TextStyle(fontWeight: FontWeight.w700)),
                              subtitle: Text('${f.path}\n폴더 $dirs · 파일 $files', maxLines: 2),
                              isThreeLine: true,
                              onTap: () => _select(i, list),
                              trailing: IconButton(
                                tooltip: '목록에서 빼기 (파일은 그대로)',
                                icon: Icon(Icons.delete_outline, color: scheme.error),
                                onPressed: () {
                                  s.libraryFolders = [...list]..removeAt(i);
                                  setState(() => _sel = null);
                                },
                              ),
                            ),
                          );
                        },
                      ),
              ),
              if (_sel != null && _sel! < list.length) ...[
                const SizedBox(height: 10),
                _Card(Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text('경로   ${list[_sel!].path}', style: Theme.of(context).textTheme.bodySmall),
                  const SizedBox(height: 10),
                  Row(children: [
                    Expanded(
                      child: TextField(
                        controller: _alias,
                        onChanged: (_) => _saveSel(s),
                        decoration: const InputDecoration(labelText: '별칭', hintText: '라이브러리에 표시할 이름', border: OutlineInputBorder()),
                      ),
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: TextField(
                        controller: _group,
                        onChanged: (_) => _saveSel(s),
                        decoration: const InputDecoration(labelText: '그룹', hintText: '예) 테스트, 만화, 소설', border: OutlineInputBorder()),
                      ),
                    ),
                  ]),
                ])),
              ],
              const SizedBox(height: 10),
              OutlinedButton.icon(
                onPressed: state.scanning ? null : state.rescanAll,
                icon: const Icon(Icons.refresh),
                label: const Text('모든 폴더 다시 스캔'),
              ),
            ]),
          ),
          const SizedBox(width: 20),
          Expanded(
            flex: 2,
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              const Text('라이브러리 미리보기', style: TextStyle(fontWeight: FontWeight.w700)),
              const SizedBox(height: 4),
              Text('사이드바에 이 순서와 그룹으로 보입니다.', style: Theme.of(context).textTheme.bodySmall),
              const SizedBox(height: 8),
              _Card(Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                for (final g in groups.entries) ...[
                  if (g.key.isNotEmpty)
                    Padding(padding: const EdgeInsets.only(top: 8, bottom: 4), child: Text(g.key, style: Theme.of(context).textTheme.labelSmall)),
                  for (final f in g.value)
                    Padding(
                      padding: EdgeInsets.only(left: g.key.isEmpty ? 0 : 12, top: 4, bottom: 4),
                      child: Text(f.name, style: const TextStyle(fontWeight: FontWeight.w600)),
                    ),
                ],
              ])),
            ]),
          ),
        ]),
      ],
    );
  }
}

class _FileHandling extends StatelessWidget {
  const _FileHandling();
  @override
  Widget build(BuildContext context) {
    final s = context.watch<Settings>();
    return _Page('파일 처리', [
      _Card(Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        _seg<StorageMode>('파일 가져올 때 기본 동작', s.defaultStorage, const [
          (StorageMode.reference, '원본 위치 참조'),
          (StorageMode.managed, '정리 폴더로 옮기기'),
        ], (v) => s.defaultStorage = v),
        ListTile(
          contentPadding: EdgeInsets.zero,
          title: const Text('정리 대상 폴더'),
          subtitle: Text(s.libraryRoot ?? '지정 안 됨'),
          trailing: const Icon(Icons.folder),
          onTap: () async {
            final d = await FilePicker.getDirectoryPath(dialogTitle: '정리 대상 폴더 선택');
            if (d != null) s.libraryRoot = d;
          },
        ),
        SwitchListTile(
          contentPadding: EdgeInsets.zero,
          title: const Text('정리할 때 이동 (끄면 복사)'),
          value: s.moveFiles,
          onChanged: (v) => s.moveFiles = v,
        ),
        _TextSetting(
          label: '정리 규칙',
          help: '{kind} {author} {series} {title} {year} 사용 가능. 예) {kind}/{author}/{series}/{title}',
          value: s.organizePattern,
          onSave: (v) => s.organizePattern = v,
        ),
      ])),
    ]);
  }
}

class _Viewer extends StatelessWidget {
  const _Viewer();
  @override
  Widget build(BuildContext context) {
    final s = context.watch<Settings>();
    return _Page('뷰어', desc: '뷰어 안의 ⚙ 설정과 같은 값입니다.', [
      _Card(Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        _seg<int>('페이지 맞춤', s.viewerFit, const [(0, '가로'), (1, '높이'), (2, '전체'), (3, '원본')], (v) => s.viewerFit = v),
        _seg<int>('만화 보기 모드', s.comicMode, const [(0, '한장'), (1, '두장'), (2, '스크롤')], (v) => s.comicMode = v),
        _seg<bool>('읽기방향', s.comicRtl, const [(false, '왼쪽에서 오른쪽'), (true, '오른쪽에서 왼쪽')], (v) => s.comicRtl = v),
        _seg<bool>('커버 표시 (두장보기)', s.comicCoverAlone, const [(false, '두장보기에 포함'), (true, '단독 표시')], (v) => s.comicCoverAlone = v),
        _seg<int>('넘김효과', s.viewerEffect, const [(0, '없음'), (1, '슬라이드'), (2, '페이드'), (3, '책 넘김')], (v) => s.viewerEffect = v),
        _seg<bool>('배경', s.viewerImmersive, const [(false, '단색'), (true, '몰입형')], (v) => s.viewerImmersive = v),
        SwitchListTile(contentPadding: EdgeInsets.zero, title: const Text('화면 좌우 눌러 넘기기'), value: s.tapToTurn, onChanged: (v) => s.tapToTurn = v),
        SwitchListTile(contentPadding: EdgeInsets.zero, title: const Text('아래 썸네일 / 장 탐색 바'), value: s.viewerSlider, onChanged: (v) => s.viewerSlider = v),
        const SizedBox(height: 8),
        OutlinedButton(onPressed: s.resetViewer, child: const Text('뷰어 설정 초기화')),
      ])),
    ]);
  }
}

class _Sources extends StatelessWidget {
  const _Sources();
  @override
  Widget build(BuildContext context) {
    final s = context.watch<Settings>();
    Widget source(String key, String name, String desc, {List<Widget> fields = const []}) => _Card(Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(children: [
              Expanded(child: Text(name, style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 16))),
              Switch(value: s.sourceEnabled(key), onChanged: (v) => s.setSourceEnabled(key, v)),
            ]),
            Text(desc, style: Theme.of(context).textTheme.bodySmall),
            ...fields,
          ],
        ));
    return _Page(
      '검색 API 설정',
      desc: '켜 둔 소스만 "인터넷에서 정보 가져오기"(통합검색)에 쓰입니다.',
      [
        source('kakao', '카카오 책 검색', '국내 도서의 저자, 출판사, ISBN, 소개와 표지를 검색합니다.', fields: [
          _TextSetting(label: 'REST API 키', help: 'developers.kakao.com 에서 무료 발급', value: s.kakaoKey, obscure: true, onSave: (v) => s.kakaoKey = v),
        ]),
        source('naver', '네이버 책 검색', '국내 도서 정보와 표지를 검색합니다.', fields: [
          _TextSetting(label: 'Client ID', help: 'developers.naver.com → 애플리케이션 등록 → 검색 API', value: s.naverId, onSave: (v) => s.naverId = v),
          _TextSetting(label: 'Client Secret', value: s.naverSecret, obscure: true, onSave: (v) => s.naverSecret = v),
        ]),
        source('google', 'Google Books', '해외 도서와 일부 국내 도서. 키 없이도 동작하지만 하루 요청 수가 적습니다.', fields: [
          _TextSetting(label: 'API 키 (선택)', value: s.googleBooksKey, obscure: true, onSave: (v) => s.googleBooksKey = v),
        ]),
        source('openlibrary', 'Open Library', '해외 도서 표지와 기본 정보 (키 필요 없음).'),
      ],
    );
  }
}

class _Ai extends StatelessWidget {
  const _Ai();
  @override
  Widget build(BuildContext context) {
    final s = context.watch<Settings>();
    return _Page('AI 도우미', desc: '파일명 분석, 태그 추천, 시리즈 권수/연재 상태, 뜻풀이, AI 사서 채팅에 쓰입니다. 키를 비워두면 AI 기능이 숨겨집니다.', [
      _Card(Column(children: [
        _TextSetting(label: 'Claude API 키', help: 'console.anthropic.com 에서 발급', value: s.aiKey, obscure: true, onSave: (v) => s.aiKey = v),
        _TextSetting(label: 'AI 모델', help: '예) claude-haiku-5-5 (저렴/빠름), claude-sonnet-5-5', value: s.aiModel, onSave: (v) => s.aiModel = v),
      ])),
    ]);
  }
}

class _Account extends StatelessWidget {
  const _Account();
  @override
  Widget build(BuildContext context) {
    final state = context.watch<AppState>();
    return _Page('계정 · 보안', [
      _Card(ListTile(
        contentPadding: EdgeInsets.zero,
        leading: Icon(state.isAdmin ? Icons.admin_panel_settings : Icons.person, size: 36),
        title: Text(state.user?.name ?? ''),
        subtitle: Text(state.isAdmin ? '관리자' : '사용자'),
        trailing: OutlinedButton.icon(
          onPressed: () {
            Navigator.pop(context);
            state.logout();
          },
          icon: const Icon(Icons.logout),
          label: const Text('로그아웃'),
        ),
      )),
      if (state.isAdmin)
        _Card(ListTile(
          contentPadding: EdgeInsets.zero,
          leading: const Icon(Icons.manage_accounts, size: 32),
          title: const Text('사용자 · 접근 권한 · 숨김 비밀번호'),
          subtitle: const Text('사용자 추가/삭제, 사용자별로 볼 수 있는 묶음 정하기, 숨김 목록 비밀번호'),
          trailing: const Icon(Icons.chevron_right),
          onTap: () => Navigator.push(context, MaterialPageRoute(builder: (_) => const AdminPage())),
        )),
      if (state.hiddenUnlocked)
        _Card(ListTile(
          contentPadding: EdgeInsets.zero,
          leading: const Icon(Icons.lock_open),
          title: const Text('숨김 목록이 열려 있습니다'),
          trailing: FilledButton(onPressed: state.lockHidden, child: const Text('잠그기')),
        )),
    ]);
  }
}

class _About extends StatelessWidget {
  const _About();
  @override
  Widget build(BuildContext context) => _Page('정보', [
        _Card(Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          const Text('MediaShelf', style: TextStyle(fontSize: 22, fontWeight: FontWeight.w900, color: Color(0xFFE50914))),
          const Text('Version $appVersion'),
          const SizedBox(height: 12),
          FutureBuilder<Directory>(
            future: getApplicationSupportDirectory(),
            builder: (_, snap) => Text('데이터 위치 (라이브러리 DB · 표지 캐시): ${snap.data?.path ?? '…'}', style: Theme.of(context).textTheme.bodySmall),
          ),
        ])),
      ]);
}
