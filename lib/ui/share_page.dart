import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../app_state.dart';
import '../services/settings.dart';
import '../services/share_server.dart';

/// 공유 서버 (BookManager "공유 서버" 탭): Web · OPDS + 서버 로그
class SharePage extends StatefulWidget {
  const SharePage({super.key});
  @override
  State<SharePage> createState() => _SharePageState();
}

class _SharePageState extends State<SharePage> {
  late final AppState _app = context.read<AppState>();
  late final Settings _s = context.read<Settings>();
  late final _port = TextEditingController(text: '${_s.sharePort}');
  late final _user = TextEditingController(text: _s.shareUser);
  late final _pw = TextEditingController(text: _s.sharePassword);
  List<String> _addrs = [];
  String? _addr;
  bool _hidePw = true;

  ShareServer get _srv => _app.share;

  @override
  void initState() {
    super.initState();
    ShareServer.addresses().then((a) => setState(() {
          _addrs = a;
          _addr = a.where((x) => x.contains('192.168.') || x.contains('10.') || x.contains('172.')).firstOrNull ?? a.firstOrNull;
        }));
  }

  String get _ip => (_addr ?? ' - 127.0.0.1').split(' - ').last;

  Future<void> _toggle() async {
    if (_srv.running) {
      await _srv.stop();
    } else {
      final port = int.tryParse(_port.text) ?? 8079;
      if (port < 1024 || port > 65535) {
        _toast('포트는 1024~65535 사이로 정하세요');
        return;
      }
      if (_pw.text.isEmpty) {
        _toast('비밀번호를 정해야 서버를 켤 수 있습니다 (같은 Wi-Fi 의 다른 사람이 보지 못하게)');
        return;
      }
      _s.sharePort = port;
      _s.shareUser = _user.text.trim();
      _s.sharePassword = _pw.text;
      _srv
        ..user = _user.text.trim()
        ..password = _pw.text
        ..asUserId = _s.shareAsUser < 0 ? null : _s.shareAsUser;
      try {
        await _srv.start(port);
      } catch (e) {
        _toast('켜지 못했습니다: $e (다른 프로그램이 포트를 쓰고 있을 수 있습니다)');
      }
    }
    if (mounted) setState(() {});
  }

  void _toast(String m) => ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(m)));

  @override
  Widget build(BuildContext context) {
    if (!_app.isAdmin) return const Scaffold(body: Center(child: Text('관리자만 쓸 수 있습니다')));
    final scheme = Theme.of(context).colorScheme;
    final on = _srv.running;
    final base = 'http://$_ip:${on ? _srv.port : _port.text}';

    Widget box(String title, List<Widget> children) => Padding(
          padding: const EdgeInsets.only(bottom: 16),
          child: Material(
            color: scheme.surfaceContainer,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(10),
              side: BorderSide(color: scheme.surfaceContainerHighest),
            ),
            clipBehavior: Clip.antiAlias,
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text(title, style: TextStyle(color: scheme.primary, fontWeight: FontWeight.w800)),
                const SizedBox(height: 10),
                ...children,
              ]),
            ),
          ),
        );

    Widget url(String u) => Row(children: [
          Expanded(
            child: Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(color: Colors.black26, borderRadius: BorderRadius.circular(6)),
              child: SelectableText(u, style: const TextStyle(fontWeight: FontWeight.w700)),
            ),
          ),
          const SizedBox(width: 8),
          OutlinedButton.icon(
            onPressed: () {
              Clipboard.setData(ClipboardData(text: u));
              _toast('복사했습니다');
            },
            icon: const Icon(Icons.copy),
            label: const Text('URL 복사'),
          ),
        ]);

    final left = ListView(padding: const EdgeInsets.all(16), children: [
      box('서버', [
        const Text('PC 와 휴대폰/태블릿을 같은 네트워크(Wi-Fi)에 연결하세요. 숨긴 항목은 보이지 않고, 계정별 접근 권한도 지켜집니다.'),
        const SizedBox(height: 12),
        Row(children: [
          const Text('서버 주소  '),
          Expanded(
            child: DropdownButton<String>(
              isExpanded: true,
              value: _addr,
              items: [for (final a in _addrs) DropdownMenuItem(value: a, child: Text(a))],
              onChanged: (v) => setState(() => _addr = v),
            ),
          ),
          const SizedBox(width: 12),
          SizedBox(
            width: 110,
            child: TextField(
              controller: _port,
              enabled: !on,
              keyboardType: TextInputType.number,
              decoration: const InputDecoration(labelText: '포트', isDense: true, border: OutlineInputBorder()),
            ),
          ),
        ]),
        const SizedBox(height: 12),
        Row(children: [
          Expanded(
            child: TextField(
              controller: _user,
              enabled: !on,
              decoration: const InputDecoration(labelText: '아이디', isDense: true, border: OutlineInputBorder()),
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: TextField(
              controller: _pw,
              enabled: !on,
              obscureText: _hidePw,
              decoration: InputDecoration(
                labelText: '비밀번호',
                isDense: true,
                border: const OutlineInputBorder(),
                suffixIcon: IconButton(icon: Icon(_hidePw ? Icons.visibility : Icons.visibility_off), onPressed: () => setState(() => _hidePw = !_hidePw)),
              ),
            ),
          ),
        ]),
        const SizedBox(height: 12),
        Row(children: [
          const Text('이 아이디로 볼 수 있는 범위  '),
          Expanded(
            child: DropdownButton<int>(
              isExpanded: true,
              value: _app.users.any((u) => u.id == _s.shareAsUser && !u.isAdmin) ? _s.shareAsUser : -1,
              items: [
                const DropdownMenuItem(value: -1, child: Text('제한 없음 (숨김만 제외)')),
                for (final u in _app.users.where((u) => !u.isAdmin)) DropdownMenuItem(value: u.id!, child: Text('"${u.name}" 계정과 같게')),
              ],
              onChanged: on ? null : (v) => setState(() => _s.shareAsUser = v ?? -1),
            ),
          ),
        ]),
        Text('앱 계정 이름과 비밀번호로 로그인하면 그 계정의 접근 권한(폴더 · 종류 · 묶음)이 그대로 적용됩니다.',
            style: Theme.of(context).textTheme.bodySmall),
        const SizedBox(height: 12),
        FilledButton.icon(
          style: FilledButton.styleFrom(backgroundColor: on ? Colors.redAccent : null, padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 16)),
          onPressed: _toggle,
          icon: const Icon(Icons.power_settings_new),
          label: Text(on ? '서버 끄기' : '서버 켜기'),
        ),
      ]),
      box('Web 공유 (브라우저 접속)', [
        const Text('브라우저에서 라이브러리를 둘러보고 검색하고 내려받을 수 있습니다.'),
        const SizedBox(height: 8),
        url('$base/'),
      ]),
      box('OPDS 공유 (Panels, ComicGlass, KyBook 등)', [
        const Text('리더 앱의 "OPDS 카탈로그 추가"에 아래 주소와 아이디/비밀번호를 넣으세요. 묶음(시리즈) 단위로 탐색하고 검색할 수 있습니다.'),
        const SizedBox(height: 8),
        url('$base/opds'),
      ]),
      box('준비 중', const [
        Text('WebDAV 공유, 휴대폰 앱 연동(QR 기기 등록), HTTPS 는 다음 단계에서 추가합니다.', style: TextStyle(color: Colors.grey)),
      ]),
    ]);

    final log = StreamBuilder<void>(
      stream: _srv.changes,
      builder: (_, _) => Container(
        margin: const EdgeInsets.all(16),
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(color: Colors.black, borderRadius: BorderRadius.circular(8)),
        child: ListView(children: [
          if (_srv.logs.isEmpty) const Text('[INFO] 서버 로그가 준비되었습니다.', style: TextStyle(fontFamily: 'monospace', color: Colors.white70)),
          for (final l in _srv.logs) Text(l, style: const TextStyle(fontFamily: 'monospace', fontSize: 12, color: Colors.white70)),
        ]),
      ),
    );

    return Scaffold(
      appBar: AppBar(title: Row(children: [
        const Text('공유 서버'),
        const SizedBox(width: 12),
        Icon(Icons.circle, size: 12, color: on ? Colors.greenAccent : Colors.grey),
        Text(on ? '  켜짐' : '  꺼짐', style: const TextStyle(fontSize: 14)),
      ])),
      body: MediaQuery.sizeOf(context).width >= 900
          ? Row(children: [
              Expanded(flex: 5, child: left),
              Expanded(flex: 4, child: Column(children: [
                Padding(padding: const EdgeInsets.only(top: 16), child: Text('서버 상태 로그', style: TextStyle(color: scheme.primary, fontWeight: FontWeight.w800))),
                Expanded(child: log),
              ])),
            ])
          : Column(children: [Expanded(child: left), SizedBox(height: 200, child: log)]),
    );
  }
}
