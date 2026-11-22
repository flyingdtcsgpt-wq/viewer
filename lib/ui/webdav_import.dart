import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:provider/provider.dart';

import '../app_state.dart';
import '../edition.dart';
import '../models/media_item.dart';
import '../services/remote.dart';
import '../services/settings.dart';
import '../services/storage_permission.dart';
import '../services/webdav_client.dart';
import 'browser.dart' show fileSize;
import 'import_dialog.dart';
import 'series_widgets.dart' show friendlyPath;
import 'viewers/open_item.dart';

/// NAS · WebDAV: 서버에 접속해 폴더를 둘러보고
/// - 폴더를 서재에 연결 (받지 않고 그 자리에서 바로 보기)
/// - 파일을 눌러 바로 보기
/// - 고른 파일 · 폴더를 이 기기로 받기 (밖에서 인터넷 없이 보려면)
Future<void> openWebDavImport(BuildContext context) =>
    Navigator.push(context, MaterialPageRoute(builder: (_) => const WebDavImportPage()));

class WebDavImportPage extends StatefulWidget {
  const WebDavImportPage({super.key});
  @override
  State<WebDavImportPage> createState() => _WebDavImportPageState();
}

class _WebDavImportPageState extends State<WebDavImportPage> {
  late final Settings _s = context.read<Settings>();
  final _name = TextEditingController();
  final _url = TextEditingController();
  final _user = TextEditingController();
  final _pw = TextEditingController();
  bool _insecure = false;

  WebDavClient? _client;
  String _path = '/';
  List<DavEntry> _entries = [];
  final Map<String, DavEntry> _picked = {}; // 고른 파일 · 폴더 (경로 → 항목, 다른 폴더로 옮겨 가도 남음)
  bool _busy = false;
  String _status = '';
  bool _stop = false;
  double? _progress;

  @override
  void dispose() {
    for (final c in [_name, _url, _user, _pw]) {
      c.dispose();
    }
    super.dispose();
  }

  void _toast(String m) => ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(m)));

  static bool _wanted(DavEntry e) => !e.dir && kindForPath(e.name) != null;

  Future<void> _connect() async {
    var url = _url.text.trim();
    if (url.isEmpty) return _toast('주소를 넣으세요 (예: https://192.168.0.10:5006/books)');
    if (!url.startsWith('http')) url = 'http://$url';
    final c = WebDavClient(url, user: _user.text.trim(), password: _pw.text, insecure: _insecure);
    setState(() => _busy = true);
    try {
      final list = await c.list(c.base.path);
      // 잘 되면 서버 목록에 저장. 비밀번호는 이 기기에만 저장한다 (받지 않고 바로 보려면 필요 · 백업 파일에는 넣지 않음)
      if (mounted) context.read<AppState>().saveNasAccount(c);
      final servers = _s.davServers.where((m) => m['url'] != url).toList()
        ..insert(0, {'name': _name.text.trim().isEmpty ? Uri.parse(url).host : _name.text.trim(), 'url': url, 'user': _user.text.trim(), 'insecure': '$_insecure'});
      _s.davServers = servers.take(10).toList();
      setState(() {
        _client = c;
        _path = c.base.path;
        _entries = list;
        _picked.clear();
      });
    } catch (e) {
      _toast('$e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _open(String path) async {
    final c = _client;
    if (c == null) return;
    setState(() => _busy = true);
    try {
      final list = await c.list(path);
      setState(() {
        _path = path;
        _entries = list;
      });
    } catch (e) {
      _toast('$e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  String get _parent {
    final t = _path.replaceAll(RegExp(r'/+$'), '');
    final i = t.lastIndexOf('/');
    return i <= 0 ? '/' : '${t.substring(0, i)}/';
  }

  bool get _atTop => _client == null || _path.replaceAll(RegExp(r'/+$'), '') == _client!.base.path.replaceAll(RegExp(r'/+$'), '');

  Future<String> _defaultTarget() async {
    final host = _client?.base.host ?? 'webdav';
    if (_s.libraryRoot != null && _s.libraryRoot!.isNotEmpty) return p.join(_s.libraryRoot!, 'NAS', host);
    if (Platform.isAndroid) {
      if (await hasAllFilesAccess()) return '/storage/emulated/0/Download/ARARIFlex/$host';
      return p.join(((await getExternalStorageDirectory()) ?? await getApplicationDocumentsDirectory()).path, 'NAS', host);
    }
    return p.join((await getApplicationDocumentsDirectory()).path, 'ARARIFlex 받은 파일', host);
  }

  Future<void> _download() async {
    final c = _client;
    if (c == null || _picked.isEmpty) return;
    var target = await _defaultTarget();
    if (!mounted) return;
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, set) => AlertDialog(
          title: const Text('이 기기로 받기'),
          content: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(kStore
                ? '고른 파일을 이 기기의 ARARIFlex 폴더로 받아 서재에 넣습니다. 밖에서 인터넷 없이 볼 때 쓰세요. (집에서는 받지 않고 "바로 보기" 로 충분합니다)'
                : '고른 파일을 아래 폴더에 받은 뒤, 서재에 넣는 창(묶기 · 숨김 등)을 엽니다. 서버의 폴더 구조는 그대로 둡니다.'),
            const SizedBox(height: 10),
            SelectableText(friendlyPath(target), style: const TextStyle(fontSize: 12)),
            if (!kStore)
              TextButton(
                onPressed: () async {
                  final d = await FilePicker.getDirectoryPath(dialogTitle: '받을 폴더');
                  if (d != null) set(() => target = d);
                },
                child: const Text('다른 폴더'),
              ),
          ]),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('취소')),
            FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('받기')),
          ],
        ),
      ),
    );
    if (ok != true || !mounted) return;
    setState(() {
      _busy = true;
      _stop = false;
      _progress = null;
      _status = '받을 파일을 찾는 중…';
    });
    final got = <String>[];
    var failed = 0;
    try {
      final files = <DavEntry>[];
      final seen = <String>{};
      for (final x in _picked.values) {
        for (final e in x.dir ? await c.walk(x.path, _wanted, cancelled: () => _stop) : [x]) {
          if (seen.add(e.path)) files.add(e); // 폴더와 그 안 파일을 같이 골라도 한 번만
        }
      }
      final base = c.base.path.replaceAll(RegExp(r'/+$'), '');
      final total = files.fold<int>(0, (a, e) => a + e.size);
      var doneBytes = 0;
      for (var i = 0; i < files.length && !_stop; i++) {
        final e = files[i];
        // 서버의 폴더 구조를 그대로 (맨 위 주소 아래부터)
        var rel = e.path.startsWith(base) ? e.path.substring(base.length) : e.path;
        rel = rel.split('/').where((x) => x.isNotEmpty).map((x) => x.replaceAll(RegExp(r'[<>:"|?*]'), '_')).join(Platform.pathSeparator);
        final to = p.join(target, rel);
        if (await File(to).exists() && await File(to).length() == e.size && e.size > 0) {
          got.add(to); // 이미 받은 것
          doneBytes += e.size;
          continue;
        }
        try {
          await c.download(e, to, cancelled: () => _stop, onProgress: (g, t) {
            if (!mounted) return;
            setState(() {
              _status = '${i + 1} / ${files.length} · ${e.name} · ${fileSize(g)}${t > 0 ? ' / ${fileSize(t)}' : ''}';
              _progress = total > 0 ? ((doneBytes + g) / total).clamp(0.0, 1.0) : (i + (t > 0 ? g / t : 0)) / files.length;
            });
          });
          got.add(to);
        } catch (err) {
          if (_stop) break;
          failed++;
        }
        doneBytes += e.size;
      }
    } catch (e) {
      _toast('$e');
    } finally {
      if (mounted) {
        setState(() {
          _busy = false;
          _progress = null;
          _status = '받음 ${got.length}개${failed > 0 ? ' · 실패 $failed개' : ''}${_stop ? ' · 멈춤' : ''}';
        });
      }
    }
    if (got.isEmpty || !mounted) return;
    if (kStore) {
      // 플레이스토어판: 받은 곳이 ARARIFlex 폴더 안이라 훑으면 서재에 들어온다
      await context.read<AppState>().rescanWhenFree();
      if (mounted) _toast('${got.length}개를 받아 서재에 넣었습니다');
      return;
    }
    await showImportDialog(context, files: got);
  }

  /// 지금 보는 폴더를 서재에 연결 (받지 않고 바로 보기)
  Future<void> _link() async {
    final c = _client;
    if (c == null) return;
    final state = context.read<AppState>();
    final shown = Uri.decodeFull(_path).replaceAll(RegExp(r'/+$'), '');
    final name = TextEditingController(text: shown.split('/').where((x) => x.isNotEmpty).lastOrNull ?? c.base.host);
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        icon: const Icon(Icons.add_link),
        title: const Text('이 폴더를 서재에 연결'),
        content: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text('${c.base.host}$shown', style: const TextStyle(fontSize: 12)),
          const SizedBox(height: 10),
          const Text('파일을 받지 않고, 볼 때 그 자리에서 엽니다. 만화는 보는 쪽만, PDF 는 필요한 부분만, 영상은 재생하는 만큼만 받습니다. '
              'NAS 에 파일을 넣거나 지우면 서재에도 반영됩니다.\n\n'
              'NAS 와 같은 네트워크(집 Wi-Fi)에 있거나, 밖에서 들어오는 주소(QuickConnect · DDNS)일 때 볼 수 있습니다. '
              '밖에서 인터넷 없이 보려면 파일을 골라 "받기" 를 쓰세요.'),
          const SizedBox(height: 10),
          TextField(controller: name, decoration: const InputDecoration(labelText: '서재에 보일 이름', border: OutlineInputBorder(), isDense: true)),
        ]),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('취소')),
          FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('연결')),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    final err = await state.linkNasFolder(c, Uri.decodeFull(_path), name: name.text.trim());
    if (!mounted) return;
    _toast(err ?? '연결했습니다. 안의 파일을 서재에 올리는 중입니다 (표지는 하나씩 만들어집니다)');
    if (err == null) Navigator.pop(context);
  }

  /// 파일 하나를 받지 않고 바로 보기 (서재에도 들어가 읽던 위치가 남는다)
  Future<void> _view(DavEntry e) async {
    final c = _client;
    if (c == null) return;
    final state = context.read<AppState>();
    state.saveNasAccount(c);
    setState(() => _busy = true);
    try {
      final item = await state.addRemoteFile('${Remote.originOf(c.base.toString())}${e.path}', e.size);
      if (item != null && mounted) await openItem(context, item, siblings: [item]);
    } catch (err) {
      _toast('$err');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Widget _form() {
    final saved = _s.davServers;
    return ListView(padding: const EdgeInsets.all(16), children: [
      const Text('시놀로지 · 큐냅 · 아이피타임 NAS, 클라우드(WebDAV 지원), 다른 PC 의 ARARIFlex 공유 서버에 있는 책 · 만화 · 영상을 '
          '받지 않고 바로 보거나(폴더 연결 · 눌러서 보기), 이 기기로 받아 옵니다.'),
      const SizedBox(height: 4),
      Text('비밀번호는 이 기기에만 저장합니다 (바로 보려면 필요합니다. 백업 파일에는 들어가지 않습니다).', style: Theme.of(context).textTheme.bodySmall),
      const SizedBox(height: 4),
      Text('예) 시놀로지: https://NAS주소:5006/폴더 · ARARIFlex: http(s)://PC주소:포트/dav/', style: Theme.of(context).textTheme.bodySmall),
      if (saved.isNotEmpty) ...[
        const SizedBox(height: 12),
        const Text('저장한 서버', style: TextStyle(fontWeight: FontWeight.bold)),
        for (final m in saved)
          ListTile(
            contentPadding: EdgeInsets.zero,
            leading: const Icon(Icons.dns),
            title: Text(m['name'] ?? m['url'] ?? ''),
            subtitle: Text('${m['url']}${(m['user'] ?? '').isEmpty ? '' : ' · ${m['user']}'}'),
            onTap: () => setState(() {
              _name.text = m['name'] ?? '';
              _url.text = m['url'] ?? '';
              _user.text = m['user'] ?? '';
              _insecure = m['insecure'] == 'true';
              _pw.text = _s.nasPassword(Remote.originOf(_url.text.startsWith('http') ? _url.text : 'http://${_url.text}'));
            }),
            trailing: IconButton(
              tooltip: '목록에서 지우기',
              icon: const Icon(Icons.close),
              onPressed: () => setState(() => _s.davServers = saved.where((x) => x['url'] != m['url']).toList()),
            ),
          ),
      ],
      const SizedBox(height: 12),
      TextField(controller: _name, decoration: const InputDecoration(labelText: '이름 (선택)', border: OutlineInputBorder(), isDense: true)),
      const SizedBox(height: 10),
      TextField(
        controller: _url,
        keyboardType: TextInputType.url,
        decoration: const InputDecoration(labelText: '주소', hintText: 'https://192.168.0.10:5006/books', border: OutlineInputBorder(), isDense: true),
      ),
      const SizedBox(height: 10),
      Row(children: [
        Expanded(child: TextField(controller: _user, decoration: const InputDecoration(labelText: '아이디', border: OutlineInputBorder(), isDense: true))),
        const SizedBox(width: 10),
        Expanded(
          child: TextField(controller: _pw, obscureText: true, decoration: const InputDecoration(labelText: '비밀번호', border: OutlineInputBorder(), isDense: true)),
        ),
      ]),
      SwitchListTile(
        contentPadding: EdgeInsets.zero,
        title: const Text('인증서 확인 안 함'),
        subtitle: const Text('NAS · ARARIFlex 가 직접 만든 인증서(HTTPS)를 쓸 때. 집 안 네트워크에서만 켜세요'),
        value: _insecure,
        onChanged: (v) => setState(() => _insecure = v),
      ),
      const SizedBox(height: 8),
      FilledButton.icon(onPressed: _busy ? null : _connect, icon: const Icon(Icons.login), label: Text(_busy ? '연결 중…' : '연결')),
    ]);
  }

  Widget _browser() {
    final files = _entries.where(_wanted).toList();
    return Column(children: [
      ListTile(
        leading: IconButton(
          tooltip: '위 폴더',
          icon: const Icon(Icons.arrow_upward),
          onPressed: _busy || _atTop ? null : () => _open(_parent),
        ),
        title: Text(Uri.decodeFull(_path), maxLines: 1, overflow: TextOverflow.ellipsis),
        subtitle: Text('${_client!.base.host} · 폴더 ${_entries.where((e) => e.dir).length} · 파일 ${files.length}'),
        trailing: TextButton(
          onPressed: _busy
              ? null
              : () => setState(() {
                    final all = files.every((e) => _picked.containsKey(e.path));
                    for (final e in files) {
                      all ? _picked.remove(e.path) : _picked[e.path] = e;
                    }
                  }),
          child: const Text('이 폴더 파일 모두'),
        ),
      ),
      const Divider(height: 1),
      Expanded(
        child: ListView(children: [
          for (final e in _entries)
            if (e.dir)
              ListTile(
                leading: Checkbox(
                  value: _picked.containsKey(e.path),
                  onChanged: _busy ? null : (v) => setState(() => v! ? _picked[e.path] = e : _picked.remove(e.path)),
                ),
                title: Text(e.name),
                subtitle: const Text('폴더 · 고르면 안의 파일 전부'),
                trailing: const Icon(Icons.chevron_right),
                onTap: _busy ? null : () => _open(e.path),
              )
            else if (_wanted(e))
              ListTile(
                leading: Checkbox(
                  value: _picked.containsKey(e.path),
                  onChanged: _busy ? null : (v) => setState(() => v! ? _picked[e.path] = e : _picked.remove(e.path)),
                ),
                title: Text(e.name),
                subtitle: Text('${fileSize(e.size)} · 누르면 바로 보기'),
                trailing: IconButton(tooltip: '받지 않고 바로 보기', icon: const Icon(Icons.play_circle_outline), onPressed: _busy ? null : () => _view(e)),
                onTap: _busy ? null : () => _view(e),
              ),
        ]),
      ),
      if (_busy && _progress != null) LinearProgressIndicator(value: _progress),
      Padding(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 14),
        child: Row(children: [
          Expanded(child: Text(_status.isEmpty ? '고른 것 ${_picked.length}개' : _status, maxLines: 2)),
          if (_busy && _progress != null) TextButton(onPressed: () => setState(() => _stop = true), child: const Text('멈춤')),
          const SizedBox(width: 8),
          OutlinedButton.icon(
            onPressed: _busy || _picked.isEmpty ? null : _download,
            icon: const Icon(Icons.download),
            label: Text('받기 (${_picked.length})'),
          ),
          const SizedBox(width: 8),
          FilledButton.icon(
            onPressed: _busy ? null : _link,
            icon: const Icon(Icons.add_link),
            label: const Text('이 폴더 연결'),
          ),
        ]),
      ),
    ]);
  }

  @override
  Widget build(BuildContext context) => Scaffold(
        appBar: AppBar(
          title: const Text('NAS · WebDAV'),
          actions: [
            if (_client != null)
              TextButton(
                onPressed: _busy ? null : () => setState(() => _client = null),
                child: const Text('다른 서버'),
              ),
          ],
        ),
        body: _client == null ? _form() : _browser(),
      );
}

/// 서재에 연결한 NAS 폴더 하나: 다시 훑기 · 연결 끊기
Future<void> showNasFolder(BuildContext context, NasFolder f) async {
  final state = context.read<AppState>();
  final offline = state.offlineNas.contains(f.url);
  final v = await showDialog<int>(
    context: context,
    builder: (ctx) => AlertDialog(
      icon: const Icon(Icons.dns_outlined),
      title: Text(f.label),
      content: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
        SelectableText(f.url, style: const TextStyle(fontSize: 12)),
        const SizedBox(height: 10),
        Text(offline
            ? '지금은 이 NAS 에 연결할 수 없습니다. NAS 가 켜져 있고 같은 네트워크(Wi-Fi)인지 확인한 뒤 "다시 훑기" 를 누르세요. 목록과 읽던 위치는 그대로 남아 있습니다.'
            : '서재에 ${state.nasCount(f)}개가 올라와 있습니다. 받지 않고 볼 때마다 그 자리에서 엽니다. NAS 에 파일을 넣거나 지우면 앱을 열 때(10분에 한 번) 반영됩니다.'),
      ]),
      actions: [
        TextButton(onPressed: () => Navigator.pop(ctx, 2), child: const Text('연결 끊기')),
        TextButton(onPressed: () => Navigator.pop(ctx, 1), child: const Text('다시 훑기')),
        FilledButton(onPressed: () => Navigator.pop(ctx), child: const Text('닫기')),
      ],
    ),
  );
  if (!context.mounted) return;
  if (v == 1) {
    await state.rescanNas();
    if (context.mounted && state.offlineNas.contains(f.url)) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('NAS 에 연결할 수 없습니다')));
    }
  } else if (v == 2) {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('연결을 끊을까요?'),
        content: Text('"${f.label}" 의 ${state.nasCount(f)}개가 서재 목록에서 빠집니다.\n\nNAS 의 파일은 그대로 남습니다. 다만 읽던 위치와 책갈피는 사라집니다.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('취소')),
          FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('연결 끊기')),
        ],
      ),
    );
    if (ok == true) await state.unlinkNasFolder(f);
  }
}
