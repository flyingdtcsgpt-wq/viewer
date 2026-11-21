import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:google_mobile_ads/google_mobile_ads.dart';

import '../edition.dart';
import 'settings.dart';

/// 광고 (플레이스토어판 안드로이드만. 전체판은 아무것도 하지 않는다)
///
/// - 아래 배너: 목록 화면 맨 아래 한 줄 (뷰어 · 빈 서재 화면에는 없음)
/// - 앱 열기 광고: 앱을 켤 때 잠깐. 처음 설치한 날은 보이지 않고, 4시간에 한 번까지. 1시간 넘게 쉬었다 돌아올 때도 같은 규칙
/// - 앱을 끌 때 광고는 넣지 않는다 (AdMob 정책상 앱을 나가는 중에 띄우는 광고는 허용되지 않음)
/// - 유럽 · 영국 등은 처음에 동의 창(Google UMP)을 띄우고, 동의 없이는 광고를 요청하지 않는다
class Ads {
  Ads._();

  static bool get enabled => kStore && Platform.isAndroid;

  // 실제 광고 단위는 빌드 때 --dart-define 으로 (없으면 구글 시험용 광고)
  static const bannerId = String.fromEnvironment('ADMOB_BANNER_ID', defaultValue: 'ca-app-pub-3940256099942544/9214589741');
  static const appOpenId = String.fromEnvironment('ADMOB_APP_OPEN_ID', defaultValue: 'ca-app-pub-3940256099942544/9257395921');

  /// 광고를 요청해도 되는 상태 (동의 · 초기화 끝)
  static final ready = ValueNotifier<bool>(false);
  static bool _started = false;
  static late Settings _s;
  static DateTime _launched = DateTime.now(); // start() 에서 다시 잡는다 (static 초기값은 처음 읽을 때 정해지므로)

  /// 지금 전면 광고가 끼어들어도 되는가 (main 이 넣어 준다: 홈 화면이고 위에 뜬 창 · 뷰어가 없을 때만 true).
  /// 만화 · 책 · 영상을 보는 중이나 안내 창 위에는 띄우지 않는다.
  static bool Function() canInterrupt = () => true;

  static Future<void> start(Settings s) async {
    if (!enabled || _started) return;
    _started = true;
    _s = s;
    _launched = DateTime.now();
    if (s.firstRunAt == 0) s.firstRunAt = DateTime.now().millisecondsSinceEpoch;
    try {
      // 동의 창: 사용자가 천천히 읽고 골라도 기다린다 (시간 제한을 두면 그 뒤로는 앱을 다시 켤 때까지 광고가 꺼진다)
      final done = Completer<void>();
      ConsentInformation.instance.requestConsentInfoUpdate(ConsentRequestParameters(), () {
        // 창이 필요 없으면 바로, 필요하면 사용자가 닫았을 때 불린다
        ConsentForm.loadAndShowConsentFormIfRequired((_) {
          if (!done.isCompleted) done.complete();
        }).catchError((_) {
          if (!done.isCompleted) done.complete();
        });
      }, (_) {
        if (!done.isCompleted) done.complete();
      });
      await done.future;
      if (!await ConsentInformation.instance.canRequestAds()) return;
      await MobileAds.instance.initialize();
      ready.value = true;
      _AppOpen.instance.start();
    } catch (e) {
      debugPrint('광고 시작 실패: $e');
    }
  }

  /// 설정 › 정보: 광고 개인정보 선택을 바꿀 수 있어야 하는 지역인가
  static Future<bool> privacyOptionsRequired() async {
    if (!enabled) return false;
    try {
      return await ConsentInformation.instance.getPrivacyOptionsRequirementStatus() == PrivacyOptionsRequirementStatus.required;
    } catch (_) {
      return false;
    }
  }

  static Future<void> showPrivacyOptions() => ConsentForm.showPrivacyOptionsForm((_) {});
}

/// 앱 열기 광고: 켤 때 · 오래 쉬었다 돌아올 때, 4시간에 한 번까지
class _AppOpen with WidgetsBindingObserver {
  _AppOpen._();
  static final instance = _AppOpen._();

  AppOpenAd? _ad;
  DateTime? _loadedAt;
  bool _showing = false;
  DateTime? _pausedAt;

  void start() {
    WidgetsBinding.instance.addObserver(this);
    _load(showWhenReady: true);
  }

  bool get _allowed {
    final s = Ads._s;
    // 설치한 첫날은 광고 없이
    if (DateTime.now().millisecondsSinceEpoch - s.firstRunAt < const Duration(hours: 24).inMilliseconds) return false;
    return DateTime.now().millisecondsSinceEpoch - s.adOpenShownAt >= const Duration(hours: 4).inMilliseconds;
  }

  void _load({bool showWhenReady = false}) {
    if (!_allowed) return;
    AppOpenAd.load(
      adUnitId: Ads.appOpenId,
      request: const AdRequest(),
      adLoadCallback: AppOpenAdLoadCallback(
        onAdLoaded: (ad) {
          _ad = ad;
          _loadedAt = DateTime.now();
          // 켤 때: 금방 준비된 경우에만 (이미 쓰기 시작한 뒤에 갑자기 끼어들지 않게). 늦게 준비되면 다음에 돌아올 때 쓴다
          if (showWhenReady && DateTime.now().difference(Ads._launched) < const Duration(seconds: 8)) _show();
        },
        onAdFailedToLoad: (_) => _ad = null,
      ),
    );
  }

  void _show() {
    final ad = _ad;
    if (ad == null || _showing || !_allowed) return;
    // 뷰어 · 창이 떠 있으면 끼어들지 않는다 (광고는 남겨 두었다가 다음 기회에)
    if (!Ads.canInterrupt()) return;
    // 불러온 지 4시간이 지난 광고는 쓰지 않는다 (AdMob 권장)
    if (_loadedAt != null && DateTime.now().difference(_loadedAt!) > const Duration(hours: 4)) {
      ad.dispose();
      _ad = null;
      _load();
      return;
    }
    _showing = true;
    ad.fullScreenContentCallback = FullScreenContentCallback(
      onAdShowedFullScreenContent: (_) => Ads._s.adOpenShownAt = DateTime.now().millisecondsSinceEpoch,
      onAdDismissedFullScreenContent: (a) {
        _showing = false;
        a.dispose();
        _ad = null;
      },
      onAdFailedToShowFullScreenContent: (a, _) {
        _showing = false;
        a.dispose();
        _ad = null;
      },
    );
    ad.show();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.paused) {
      _pausedAt = DateTime.now();
    } else if (state == AppLifecycleState.resumed) {
      final away = _pausedAt == null ? Duration.zero : DateTime.now().difference(_pausedAt!);
      _pausedAt = null;
      // 1시간 넘게 쉬었다 돌아올 때만
      if (away < const Duration(hours: 1) || !_allowed) return;
      if (_ad != null) {
        _show();
      } else {
        _load();
      }
    }
  }
}

/// 목록 화면 아래 배너 (광고가 없으면 자리도 차지하지 않는다)
class AdBanner extends StatefulWidget {
  const AdBanner({super.key});
  @override
  State<AdBanner> createState() => _AdBannerState();
}

class _AdBannerState extends State<AdBanner> {
  BannerAd? _ad;
  bool _loaded = false;
  int _width = 0;

  @override
  void initState() {
    super.initState();
    Ads.ready.addListener(_maybeLoad);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _maybeLoad();
  }

  Future<void> _maybeLoad() async {
    if (!Ads.enabled || !Ads.ready.value || !mounted) return;
    final width = MediaQuery.sizeOf(context).width.truncate();
    if (_ad != null && width == _width) return;
    _width = width;
    // 작은 띠 배너(높이 50~90). "큰" 적응형 배너는 화면의 1/6 쯤을 차지해 거슬린다
    // ignore: deprecated_member_use
    final size = await AdSize.getAnchoredAdaptiveBannerAdSize(MediaQuery.orientationOf(context), width);
    if (size == null || !mounted) return;
    _ad?.dispose();
    _loaded = false;
    _ad = BannerAd(
      adUnitId: Ads.bannerId,
      size: size,
      request: const AdRequest(),
      listener: BannerAdListener(
        onAdLoaded: (_) {
          if (mounted) setState(() => _loaded = true);
        },
        onAdFailedToLoad: (ad, _) {
          ad.dispose();
          if (mounted) {
            setState(() {
              _ad = null;
              _loaded = false;
            });
          }
        },
      ),
    )..load();
  }

  @override
  void dispose() {
    Ads.ready.removeListener(_maybeLoad);
    _ad?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final ad = _ad;
    if (!Ads.enabled || ad == null || !_loaded) return const SizedBox.shrink();
    return Container(
      color: Theme.of(context).colorScheme.surfaceContainerLowest,
      // 아래 탭과 붙어 잘못 눌리지 않게 위아래로 조금 띄운다
      padding: const EdgeInsets.symmetric(vertical: 4),
      alignment: Alignment.center,
      child: SizedBox(width: ad.size.width.toDouble(), height: ad.size.height.toDouble(), child: AdWidget(ad: ad)),
    );
  }
}
