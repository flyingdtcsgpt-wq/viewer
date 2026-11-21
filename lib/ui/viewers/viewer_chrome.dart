import 'dart:io';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../services/settings.dart';

/// 뷰어 공통 부품 (BookManager 스타일)
/// - 위 도구줄: 버튼 묶음(ToolGroup) 안에 아이콘 버튼(ToolBtn)
/// - 오른쪽 "뷰어 설정" 패널: 제목 + 선택 칸(SegmentRow)

const viewerBg = Color(0xFF1B1B1B);
const toolBg = Color(0xFF2A2A2A);
const toolActive = Color(0xFFE50914); // 선택된 버튼: 앱 포인트 색(빨강)

class ToolGroup extends StatelessWidget {
  final List<Widget> children;
  const ToolGroup(this.children, {super.key});
  @override
  Widget build(BuildContext context) => Container(
        margin: const EdgeInsets.symmetric(horizontal: 4),
        decoration: BoxDecoration(
          color: toolBg,
          borderRadius: BorderRadius.circular(8),
          border: Border.all(color: Colors.white12),
        ),
        clipBehavior: Clip.antiAlias,
        child: Row(mainAxisSize: MainAxisSize.min, children: children),
      );
}

class ToolBtn extends StatelessWidget {
  final IconData? icon;
  final String? label;
  final String tooltip;
  final bool active;
  final VoidCallback? onTap;
  final bool enabled; // false 면 흐리게 (onTap 이 없어도 다른 위젯이 눌림을 처리하면 true)
  const ToolBtn({super.key, this.icon, this.label, required this.tooltip, this.active = false, this.onTap, this.enabled = true});

  @override
  Widget build(BuildContext context) => Tooltip(
        message: tooltip,
        child: Material(
          color: active ? toolActive : Colors.transparent,
          child: InkWell(
            onTap: onTap,
            child: Container(
              height: 40,
              constraints: const BoxConstraints(minWidth: 40),
              padding: const EdgeInsets.symmetric(horizontal: 9),
              alignment: Alignment.center,
              child: Row(mainAxisSize: MainAxisSize.min, children: [
                if (icon != null) Icon(icon, size: 20, color: enabled ? Colors.white : Colors.white24),
                if (icon != null && label != null) const SizedBox(width: 6),
                if (label != null)
                  Text(label!, style: TextStyle(color: enabled ? Colors.white : Colors.white24, fontWeight: FontWeight.w600)),
              ]),
            ),
          ),
        ),
      );
}

/// 설정 패널의 한 줄 선택 (아이콘 + 글자 버튼들, 하나만 선택)
class SegmentRow<T> extends StatelessWidget {
  final String title;
  final List<(T, IconData?, String)> options;
  final T value;
  final ValueChanged<T> onChanged;
  const SegmentRow({super.key, required this.title, required this.options, required this.value, required this.onChanged});

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.only(bottom: 14),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(title, style: const TextStyle(color: Colors.white70, fontSize: 13, fontWeight: FontWeight.w600)),
          const SizedBox(height: 6),
          Container(
            decoration: BoxDecoration(borderRadius: BorderRadius.circular(8), border: Border.all(color: Colors.white12)),
            clipBehavior: Clip.antiAlias,
            child: Row(children: [
              for (final (v, icon, label) in options)
                Expanded(
                  child: Material(
                    color: v == value ? toolActive : toolBg,
                    child: InkWell(
                      onTap: () => onChanged(v),
                      child: Padding(
                        padding: const EdgeInsets.symmetric(vertical: 9),
                        child: Column(children: [
                          if (icon != null) Icon(icon, size: 18, color: Colors.white),
                          if (icon != null) const SizedBox(height: 3),
                          Text(label, textAlign: TextAlign.center, style: const TextStyle(color: Colors.white, fontSize: 12)),
                        ]),
                      ),
                    ),
                  ),
                ),
            ]),
          ),
        ]),
      );
}

/// 오른쪽 "뷰어 설정" 패널 틀
class ViewerSettingsPanel extends StatelessWidget {
  final List<Widget> children;
  final VoidCallback onClose;
  const ViewerSettingsPanel({super.key, required this.children, required this.onClose});

  @override
  Widget build(BuildContext context) => Container(
        width: 330,
        color: const Color(0xFF232323),
        child: Column(children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 16, 12, 8),
            child: Row(children: [
              const Expanded(child: Text('뷰어 설정', style: TextStyle(color: Colors.white, fontSize: 18, fontWeight: FontWeight.w800))),
              IconButton(
                style: IconButton.styleFrom(backgroundColor: toolBg),
                onPressed: onClose,
                icon: const Icon(Icons.close, color: Colors.white),
              ),
            ]),
          ),
          Expanded(child: ListView(padding: const EdgeInsets.fromLTRB(20, 4, 20, 20), children: children)),
        ]),
      );
}

class PanelSection extends StatelessWidget {
  final String title;
  const PanelSection(this.title, {super.key});
  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.only(top: 6, bottom: 10),
        child: Text(title, style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w800, fontSize: 15)),
      );
}

/// 조작법 도움말. 손가락으로 쓰는 기기(휴대폰 · 태블릿)에서는 [touch] 를 먼저 보여 주고, 키보드 단축키는 그 아래에 둔다.
void showViewerHelp(BuildContext context, List<(String, String)> keys, {List<(String, String)> touch = const []}) {
  final mobile = Platform.isAndroid || Platform.isIOS;
  List<Widget> rows(List<(String, String)> list, {double keyWidth = 130}) => [
        for (final (k, v) in list)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 4),
            child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Container(
                width: keyWidth,
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                decoration: BoxDecoration(color: Colors.white10, borderRadius: BorderRadius.circular(4)),
                child: Text(k, style: mobile ? const TextStyle(fontWeight: FontWeight.w600) : const TextStyle(fontFamily: 'monospace')),
              ),
              const SizedBox(width: 12),
              Expanded(child: Padding(padding: const EdgeInsets.only(top: 3), child: Text(v))),
            ]),
          ),
      ];
  showDialog(
    context: context,
    builder: (ctx) => AlertDialog(
      title: Text(mobile ? '조작법' : '단축키'),
      content: SizedBox(
        width: 400,
        child: SingleChildScrollView(
          child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
            if (mobile && touch.isNotEmpty) ...[
              ...rows(touch, keyWidth: 124),
              const Padding(
                padding: EdgeInsets.only(top: 14, bottom: 4),
                child: Text('키보드를 연결했을 때', style: TextStyle(fontSize: 12, color: Colors.grey)),
              ),
            ],
            ...rows(keys),
          ]),
        ),
      ),
      actions: [TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('닫기'))],
    ),
  );
}

/// 눈 보호: 푸른빛을 줄여 따뜻한 색으로 바꾸고, 필요하면 어둡게 한다. 뷰어의 본문(쪽 · 글)을 감싼다.
/// 검은색은 검은 채로 두고 밝은 부분만 누그러뜨린다 (위에 색 막을 덮는 방식과 달리 어두운 화면이 뿌옇게 뜨지 않는다).
class EyeCare extends StatelessWidget {
  final Widget child;
  const EyeCare({super.key, required this.child});

  @override
  Widget build(BuildContext context) {
    final on = context.select<Settings, bool>((s) => s.eyeCare);
    final w = context.select<Settings, double>((s) => s.eyeCareWarm).clamp(0.0, 1.0);
    final d = 1 - context.select<Settings, double>((s) => s.eyeCareDim).clamp(0.0, 0.7);
    return StableFilter(
      filter: !on
          ? null
          : ColorFilter.matrix(<double>[
              d, 0, 0, 0, 0, //
              0, d * (1 - 0.20 * w), 0, 0, 0, // 초록을 조금
              0, 0, d * (1 - 0.60 * w), 0, 0, // 파랑을 많이 줄인다
              0, 0, 0, 1, 0,
            ]),
      child: child,
    );
  }
}

/// 색 거르개를 켰다 껐다 해도 안쪽 화면이 새로 만들어지지 않게 감싼다 (스크롤 위치 · 불러온 쪽 · 확대가 그대로 남는다)
class StableFilter extends StatefulWidget {
  final ColorFilter? filter;
  final Widget child;
  const StableFilter({super.key, required this.filter, required this.child});
  @override
  State<StableFilter> createState() => _StableFilterState();
}

class _StableFilterState extends State<StableFilter> {
  final _key = GlobalKey();
  @override
  Widget build(BuildContext context) {
    final kid = KeyedSubtree(key: _key, child: widget.child);
    final f = widget.filter;
    return f == null ? kid : ColorFiltered(colorFilter: f, child: kid);
  }
}

/// 색 뒤집기 (흰 종이 → 검은 바탕). 색상은 그대로 두고 밝기만 뒤집어 그림 · 형광펜 색이 덜 어색하다.
const invertKeepHue = ColorFilter.matrix(<double>[
  0.574, -1.430, -0.144, 0, 255, //
  -0.426, -0.430, -0.144, 0, 255, //
  -0.426, -1.430, 0.856, 0, 255, //
  0, 0, 0, 1, 0,
]);

/// 위 도구줄의 "눈 보호" 단추 (켜기 · 끄기. 세기는 ⚙ 또는 설정 › 뷰어)
class EyeCareBtn extends StatelessWidget {
  const EyeCareBtn({super.key});
  @override
  Widget build(BuildContext context) {
    final s = context.watch<Settings>();
    return ToolBtn(
      icon: Icons.remove_red_eye_outlined,
      label: '눈 보호',
      tooltip: '눈 보호: 푸른빛을 줄여 따뜻한 색으로 (세기는 ⚙ 뷰어 설정)',
      active: s.eyeCare,
      onTap: () => s.eyeCare = !s.eyeCare,
    );
  }
}

/// ⚙ 뷰어 설정 패널에 넣는 "눈 보호" 묶음: 켜기 · 따뜻한 정도 · 어둡게
class EyeCarePanel extends StatelessWidget {
  const EyeCarePanel({super.key});

  @override
  Widget build(BuildContext context) {
    final s = context.watch<Settings>();
    Widget slider(String label, double value, double max, ValueChanged<double> onChanged) => Row(children: [
          SizedBox(width: 72, child: Text(label, style: const TextStyle(color: Colors.white70, fontSize: 13))),
          Expanded(child: Slider(value: value.clamp(0.0, max), max: max, onChanged: s.eyeCare ? onChanged : null)),
          SizedBox(width: 40, child: Text('${(value / max * 100).round()}%', style: const TextStyle(color: Colors.white70))),
        ]);
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      const PanelSection('눈 보호'),
      SegmentRow<bool>(
        title: '푸른빛 줄이기 (책 · 만화 · PDF 에 함께 적용)',
        value: s.eyeCare,
        onChanged: (v) => s.eyeCare = v,
        options: const [(true, null, '켜기'), (false, null, '끄기')],
      ),
      slider('따뜻하게', s.eyeCareWarm, 1, (v) => s.eyeCareWarm = v),
      slider('어둡게', s.eyeCareDim, 0.7, (v) => s.eyeCareDim = v),
    ]);
  }
}

/// 책갈피 목록: 누르면 그 자리로 가고, × 로 지운다
/// [marks] 책갈피한 자리(쪽 번호 등), [label] 목록에 보일 글, [onGo] 그 자리로 이동, [onRemove] 지우기
void showBookmarkSheet(
  BuildContext context, {
  required List<int> marks,
  required String Function(int mark) label,
  required void Function(int mark) onGo,
  required void Function(int mark) onRemove,
}) {
  final sorted = [...marks]..sort();
  showModalBottomSheet<void>(
    context: context,
    showDragHandle: true,
    builder: (ctx) => SafeArea(
      child: ListView(shrinkWrap: true, children: [
        ListTile(
          leading: const Icon(Icons.bookmarks_outlined),
          title: Text(sorted.isEmpty ? '책갈피' : '책갈피 ${sorted.length}개 — 누르면 그 자리로 갑니다'),
        ),
        if (sorted.isEmpty)
          const ListTile(title: Text('아직 책갈피가 없습니다. 바로 왼쪽의 책갈피 단추를 누르면 지금 보는 곳이 표시됩니다.')),
        for (final m in sorted)
          ListTile(
            leading: const Icon(Icons.bookmark, color: Colors.redAccent),
            title: Text(label(m), maxLines: 2, overflow: TextOverflow.ellipsis),
            onTap: () {
              Navigator.pop(ctx);
              onGo(m);
            },
            trailing: IconButton(
              tooltip: '책갈피 지우기',
              icon: const Icon(Icons.close),
              onPressed: () {
                Navigator.pop(ctx);
                onRemove(m);
              },
            ),
          ),
      ]),
    ),
  );
}

/// 위 도구줄의 "책갈피 목록" 단추 (책갈피 단추 옆). 개수를 보여 주고, 누르면 목록이 뜬다
class BookmarkListBtn extends StatelessWidget {
  final int count;
  final VoidCallback onTap;
  const BookmarkListBtn({super.key, required this.count, required this.onTap});
  @override
  Widget build(BuildContext context) => ToolBtn(
        icon: Icons.bookmarks_outlined,
        label: count > 0 ? '$count' : null,
        tooltip: '책갈피 목록 — 책갈피한 곳으로 바로 가기',
        onTap: onTap,
      );
}
