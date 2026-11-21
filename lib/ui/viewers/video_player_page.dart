import 'dart:async';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';
import 'package:provider/provider.dart';

import '../../app_state.dart';
import '../../models/media_item.dart';
import '../../services/linked.dart';
import '../../services/settings.dart';
import '../detail_page.dart';
import 'viewer_chrome.dart';

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
  // GPU 디코딩 (설정에서 끌 수 있음 — 일부 오래된 그래픽카드에서 화면이 깨질 때)
  late final _video = VideoController(_player, configuration: VideoControllerConfiguration(enableHardwareAcceleration: _settings.videoHwdec));
  double _subDelay = 0; // 자막 싱크 (초)
  final _subs = <StreamSubscription>[];
  Timer? _saveTimer;

  late int _index = widget.initialIndex;
  Duration? _a, _b; // 구간 반복
  bool _resumed = false;
  bool _wasFinished = false; // 다 본 영상을 다시 연 것 (1분 넘게 다시 보기 전에는 "다 봄" 유지)

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
    // 연결한 폴더의 영상은 경로로 열 수 없어 content:// 주소로 넘긴다 (플레이어가 그 주소를 직접 연다)
    await _player.open(Media(await Linked.uri(_item.path) ?? _item.path));
    await _player.setRate(_settings.videoRate);
  }

  /// 저장된 위치에서 이어보기 (끝부분이면 처음부터)
  void _resume(Duration total) {
    if (_resumed) return;
    _resumed = true;
    final ms = int.tryParse(_item.position ?? '') ?? 0;
    final at = Duration(milliseconds: ms);
    // 다 본 영상은 처음부터 (끝부분에서 멈춘 자리로 가지 않게)
    _wasFinished = _item.progress >= 0.98;
    if (!_wasFinished && at > const Duration(seconds: 5) && at < total - const Duration(seconds: 10)) {
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
    // 다 본 영상을 잠깐 다시 틀어 본 것으로 "보는 중" 이 되지 않게
    if (_wasFinished && pos < const Duration(minutes: 1)) return Future.value();
    // 끝부분(엔딩 · 예고)만 남았으면 다 본 것으로: 남은 시간이 전체의 6% 이하(최대 3분)
    final left = total - pos;
    final tail = Duration(milliseconds: (total.inMilliseconds * 0.06).round().clamp(0, 180000));
    final ratio = left <= tail ? 1.0 : pos.inMilliseconds / total.inMilliseconds;
    return _app.saveProgress(_item, '${pos.inMilliseconds}', ratio);
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
          _subtitleMenu(),
          _audioMenu(),
          // 덜 쓰는 것은 ⋮ 안에 (휴대폰에서 위쪽 단추가 넘치지 않게)
          PopupMenuButton<int>(
            tooltip: '더보기',
            icon: const Icon(Icons.more_vert, color: Colors.white),
            onSelected: (v) {
              if (v == 0) {
                Navigator.push(context, MaterialPageRoute(builder: (_) => DetailPage(item: _item)));
              } else {
                _help();
              }
            },
            itemBuilder: (_) => const [
              PopupMenuItem(value: 0, child: ListTile(leading: Icon(Icons.info_outline), title: Text('정보 / 태그'), dense: true)),
              PopupMenuItem(value: 1, child: ListTile(leading: Icon(Icons.help_outline), title: Text('조작법'), dense: true)),
            ],
          ),
        ],
      ),
      // 휴대폰 · 태블릿: 화면 왼쪽 · 오른쪽을 두 번 누르면 10초 뒤 · 앞으로 (기본값은 꺼져 있다)
      body: MaterialVideoControlsTheme(
        normal: kDefaultMaterialVideoControlsThemeData.copyWith(seekOnDoubleTap: true),
        fullscreen: kDefaultMaterialVideoControlsThemeDataFullscreen.copyWith(seekOnDoubleTap: true),
        child: Video(
        controller: _video,
        subtitleViewConfiguration: SubtitleViewConfiguration(
          style: TextStyle(
            fontSize: context.select<Settings, double>((s) => s.subtitleSize),
            color: Colors.white,
            fontWeight: FontWeight.w600,
            height: 1.35,
            shadows: const [Shadow(blurRadius: 4, color: Colors.black), Shadow(offset: Offset(1, 1), color: Colors.black)],
          ),
        ),
      ),
      ),
    );
  }

  void _help() => showViewerHelp(context, const [
        ('Space', '재생 · 일시정지'),
        ('← →', '2초 뒤 · 앞으로'),
        ('J / I', '10초 뒤 · 앞으로'),
        ('↑ ↓', '음량'),
        ('F / Esc', '전체화면 / 나가기'),
        ('A-B', '구간 반복: 시작에서 한 번, 끝에서 한 번 · 한 번 더 누르면 해제'),
        ('1.0x', '재생 속도'),
        ('자막 단추', '자막 고르기 · 자막 파일 불러오기 · 크기 · 싱크'),
      ], touch: const [
        ('화면 누르기', '재생 · 일시정지, 탐색 막대, 전체화면 단추 보이기'),
        ('왼쪽 · 오른쪽 두 번 누르기', '10초 뒤 · 앞으로'),
        ('A-B', '구간 반복: 시작에서 한 번, 끝에서 한 번 · 한 번 더 누르면 해제'),
        ('1.0x', '재생 속도'),
        ('자막 단추', '자막 고르기 · 자막 파일 불러오기 · 크기 · 싱크'),
        ('이전 · 다음 단추', '같은 묶음의 앞 · 뒤 영상'),
      ]);

  // ---------------- 자막 / 오디오 ----------------

  Future<void> _setSubDelay(double v) async {
    setState(() => _subDelay = v);
    final p = _player.platform;
    if (p is NativePlayer) await p.setProperty('sub-delay', v.toStringAsFixed(2));
  }

  String _trackName(String id, String? title, String? lang) {
    final parts = [title, lang].whereType<String>().where((e) => e.isNotEmpty);
    return parts.isEmpty ? '트랙 $id' : '${parts.join(' · ')}  (#$id)';
  }

  Widget _subtitleMenu() => StreamBuilder<Tracks>(
        stream: _player.stream.tracks,
        builder: (context, _) {
          final tracks = _player.state.tracks.subtitle.where((t) => t.id != 'auto' && t.id != 'no').toList();
          final cur = _player.state.track.subtitle;
          final size = _settings.subtitleSize;
          return PopupMenuButton<String>(
            tooltip: '자막',
            icon: Icon(cur.id == 'no' ? Icons.subtitles_off : Icons.subtitles, color: Colors.white),
            onSelected: (v) async {
              switch (v) {
                case 'off':
                  await _player.setSubtitleTrack(SubtitleTrack.no());
                case 'auto':
                  await _player.setSubtitleTrack(SubtitleTrack.auto());
                case 'file':
                  final f = await FilePicker.pickFile(
                    dialogTitle: '자막 파일 (srt · ass · smi · vtt)',
                    type: FileType.custom,
                    allowedExtensions: const ['srt', 'ass', 'ssa', 'smi', 'sami', 'vtt', 'sub'],
                  );
                  if (f?.path != null) await _player.setSubtitleTrack(SubtitleTrack.uri(f!.path!, title: f.name));
                case 'big':
                  _settings.subtitleSize = (size + 4).clamp(16, 96);
                case 'small':
                  _settings.subtitleSize = (size - 4).clamp(16, 96);
                case 'later':
                  await _setSubDelay(_subDelay + 0.5);
                case 'earlier':
                  await _setSubDelay(_subDelay - 0.5);
                case 'sync0':
                  await _setSubDelay(0);
                default:
                  final t = tracks.where((t) => 'sub:${t.id}' == v).firstOrNull;
                  if (t != null) await _player.setSubtitleTrack(t);
              }
              if (mounted) setState(() {});
            },
            itemBuilder: (_) => [
              CheckedPopupMenuItem(value: 'off', checked: cur.id == 'no', child: const Text('자막 끄기')),
              CheckedPopupMenuItem(value: 'auto', checked: cur.id == 'auto', child: const Text('자동 (같은 이름 자막 / 내장 첫 자막)')),
              for (final t in tracks)
                CheckedPopupMenuItem(value: 'sub:${t.id}', checked: cur.id == t.id, child: Text(_trackName(t.id, t.title, t.language))),
              const PopupMenuDivider(),
              const PopupMenuItem(value: 'file', child: ListTile(leading: Icon(Icons.folder_open), title: Text('자막 파일 불러오기…'), dense: true)),
              const PopupMenuDivider(),
              PopupMenuItem(value: 'big', child: Text('자막 크게  (지금 ${size.round()})')),
              const PopupMenuItem(value: 'small', child: Text('자막 작게')),
              const PopupMenuDivider(),
              PopupMenuItem(value: 'later', child: Text('자막 늦게 +0.5초  (지금 ${_subDelay.toStringAsFixed(1)}초)')),
              const PopupMenuItem(value: 'earlier', child: Text('자막 빠르게 -0.5초')),
              const PopupMenuItem(value: 'sync0', child: Text('싱크 초기화')),
            ],
          );
        },
      );

  Widget _audioMenu() => StreamBuilder<Tracks>(
        stream: _player.stream.tracks,
        builder: (context, _) {
          final tracks = _player.state.tracks.audio.where((t) => t.id != 'auto' && t.id != 'no').toList();
          if (tracks.length < 2) return const SizedBox();
          final cur = _player.state.track.audio;
          return PopupMenuButton<String>(
            tooltip: '오디오 트랙',
            icon: const Icon(Icons.audiotrack, color: Colors.white),
            onSelected: (v) async {
              final t = tracks.where((t) => t.id == v).firstOrNull;
              if (t != null) await _player.setAudioTrack(t);
              if (mounted) setState(() {});
            },
            itemBuilder: (_) => [
              for (final t in tracks) CheckedPopupMenuItem(value: t.id, checked: cur.id == t.id, child: Text(_trackName(t.id, t.title, t.language))),
            ],
          );
        },
      );
}

String _fmt(Duration d) {
  final h = d.inHours, m = d.inMinutes % 60, s = d.inSeconds % 60;
  String two(int v) => v.toString().padLeft(2, '0');
  return h > 0 ? '$h:${two(m)}:${two(s)}' : '${two(m)}:${two(s)}';
}
