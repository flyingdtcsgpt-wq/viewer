import 'dart:async';

import 'package:flutter/material.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';
import 'package:provider/provider.dart';

import '../../app_state.dart';
import '../../models/media_item.dart';
import '../../services/settings.dart';
import '../detail_page.dart';

/// 영상 플레이어 (media_kit / libmpv — 거의 모든 코덱, 자막 지원)
/// - 이어보기: 마지막 위치 자동 저장/복원
/// - 배속, A-B 구간 반복, 이전/다음 영상
/// - 키보드: Space 재생/정지, ←/→ 탐색, F 전체화면 (기본 컨트롤 제공)
class VideoPlayerPage extends StatefulWidget {
  final List<MediaItem> playlist;
  final int initialIndex;
  const VideoPlayerPage({super.key, required this.playlist, required this.initialIndex});

  @override
  State<VideoPlayerPage> createState() => _VideoPlayerPageState();
}

class _VideoPlayerPageState extends State<VideoPlayerPage> {
  late final AppState _app = context.read<AppState>();
  late final Settings _settings = context.read<Settings>();
  final _player = Player();
  late final _video = VideoController(_player);
  final _subs = <StreamSubscription>[];
  Timer? _saveTimer;

  late int _index = widget.initialIndex;
  Duration? _a, _b; // 구간 반복
  bool _resumed = false;

  MediaItem get _item => widget.playlist[_index];

  @override
  void initState() {
    super.initState();
    _subs.add(_player.stream.position.listen(_onPosition));
    _subs.add(_player.stream.duration.listen((d) {
      if (d > Duration.zero) _resume(d);
    }));
    _subs.add(_player.stream.completed.listen((done) {
      if (done && _b == null && _index < widget.playlist.length - 1) _openAt(_index + 1);
    }));
    _saveTimer = Timer.periodic(const Duration(seconds: 5), (_) => _save());
    _openAt(_index);
  }

  @override
  void dispose() {
    _saveTimer?.cancel();
    _save().then((_) => _app.refresh());
    for (final s in _subs) {
      s.cancel();
    }
    _player.dispose();
    super.dispose();
  }

  Future<void> _openAt(int i) async {
    if (_player.state.duration > Duration.zero) await _save();
    setState(() {
      _index = i;
      _a = _b = null;
      _resumed = false;
    });
    await _player.open(Media(_item.path));
    await _player.setRate(_settings.videoRate);
  }

  /// 저장된 위치에서 이어보기 (끝부분이면 처음부터)
  void _resume(Duration total) {
    if (_resumed) return;
    _resumed = true;
    final ms = int.tryParse(_item.position ?? '') ?? 0;
    final at = Duration(milliseconds: ms);
    if (at > const Duration(seconds: 5) && at < total - const Duration(seconds: 10)) {
      _player.seek(at);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text('${_fmt(at)} 부터 이어서 재생'),
          action: SnackBarAction(label: '처음부터', onPressed: () => _player.seek(Duration.zero)),
        ));
      }
    }
  }

  void _onPosition(Duration pos) {
    final a = _a, b = _b;
    if (a != null && b != null && pos >= b) _player.seek(a);
  }

  Future<void> _save() {
    final pos = _player.state.position;
    final total = _player.state.duration;
    if (total <= Duration.zero) return Future.value();
    return _app.saveProgress(_item, '${pos.inMilliseconds}', pos.inMilliseconds / total.inMilliseconds);
  }

  void _abLoop() {
    final pos = _player.state.position;
    setState(() {
      if (_a == null) {
        _a = pos;
      } else if (_b == null && pos > _a!) {
        _b = pos;
      } else {
        _a = _b = null;
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final rate = context.select<Settings, double>((s) => s.videoRate);
    final abLabel = _a == null ? 'A-B' : (_b == null ? 'A ${_fmt(_a!)} → B?' : '${_fmt(_a!)}~${_fmt(_b!)}');

    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: Colors.black,
        foregroundColor: Colors.white,
        title: Text(_item.title, overflow: TextOverflow.ellipsis),
        actions: [
          IconButton(
            tooltip: '이전 영상',
            icon: const Icon(Icons.skip_previous),
            onPressed: _index > 0 ? () => _openAt(_index - 1) : null,
          ),
          IconButton(
            tooltip: '다음 영상',
            icon: const Icon(Icons.skip_next),
            onPressed: _index < widget.playlist.length - 1 ? () => _openAt(_index + 1) : null,
          ),
          TextButton(
            style: TextButton.styleFrom(foregroundColor: _a != null ? Colors.amber : Colors.white),
            onPressed: _abLoop,
            child: Text(abLabel),
          ),
          PopupMenuButton<double>(
            tooltip: '재생 속도',
            initialValue: rate,
            onSelected: (v) {
              _settings.videoRate = v;
              _player.setRate(v);
            },
            itemBuilder: (_) => [
              for (final r in const [0.5, 0.75, 1.0, 1.25, 1.5, 1.75, 2.0, 3.0])
                PopupMenuItem(value: r, child: Text('${r}x')),
            ],
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12),
              child: Center(child: Text('${rate}x', style: const TextStyle(color: Colors.white))),
            ),
          ),
          IconButton(
            tooltip: '정보 / 태그',
            icon: const Icon(Icons.info_outline),
            onPressed: () => Navigator.push(context, MaterialPageRoute(builder: (_) => DetailPage(item: _item))),
          ),
        ],
      ),
      body: Video(controller: _video),
    );
  }
}

String _fmt(Duration d) {
  final h = d.inHours, m = d.inMinutes % 60, s = d.inSeconds % 60;
  String two(int v) => v.toString().padLeft(2, '0');
  return h > 0 ? '$h:${two(m)}:${two(s)}' : '${two(m)}:${two(s)}';
}
