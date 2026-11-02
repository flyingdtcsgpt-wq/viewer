import 'package:flutter/material.dart';

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

/// 단축키 도움말
void showViewerHelp(BuildContext context, List<(String, String)> keys) => showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('단축키'),
        content: SizedBox(
          width: 380,
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            for (final (k, v) in keys)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 4),
                child: Row(children: [
                  Container(
                    width: 130,
                    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                    decoration: BoxDecoration(color: Colors.white10, borderRadius: BorderRadius.circular(4)),
                    child: Text(k, style: const TextStyle(fontFamily: 'monospace')),
                  ),
                  const SizedBox(width: 12),
                  Expanded(child: Text(v)),
                ]),
              ),
          ]),
        ),
        actions: [TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('닫기'))],
      ),
    );
