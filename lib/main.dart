import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:media_kit/media_kit.dart';
import 'package:provider/provider.dart';

import 'app_state.dart';
import 'db/library_db.dart';
import 'services/cover_service.dart';
import 'services/settings.dart';
import 'ui/home_page.dart';
import 'ui/login_page.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  MediaKit.ensureInitialized(); // 영상 플레이어(libmpv)
  _registerNativeLicenses();
  final settings = Settings();
  await settings.load();
  final db = await LibraryDb.open();
  final covers = CoverService();
  await covers.init();
  final state = AppState(db, settings, covers);
  await state.load();

  runApp(MultiProvider(
    providers: [
      ChangeNotifierProvider.value(value: settings),
      ChangeNotifierProvider.value(value: state),
    ],
    child: const MediaShelfApp(),
  ));
}

class MediaShelfApp extends StatelessWidget {
  const MediaShelfApp({super.key});

  @override
  Widget build(BuildContext context) {
    final light = context.select<Settings, bool>((s) => s.lightMode);
    return MaterialApp(
      title: 'MediaShelf',
      debugShowCheckedModeBanner: false,
      theme: appTheme(Brightness.light),
      darkTheme: appTheme(Brightness.dark),
      themeMode: light ? ThemeMode.light : ThemeMode.dark, // 기본은 넷플릭스풍 어두운 화면
      // 로그인 전에는 아무 목록도 보이지 않는다
      home: context.select<AppState, bool>((s) => s.user != null) ? const HomePage() : const LoginPage(),
    );
  }
}

/// 넷플릭스풍: 거의 검은 배경 + 빨간 포인트
const brandRed = Color(0xFFE50914);

ThemeData appTheme(Brightness b) {
  final dark = b == Brightness.dark;
  final scheme = ColorScheme.fromSeed(
    seedColor: brandRed,
    brightness: b,
    primary: brandRed,
    onPrimary: Colors.white,
    surface: dark ? const Color(0xFF141414) : const Color(0xFFF7F7F7),
    onSurface: dark ? Colors.white : const Color(0xFF141414),
    surfaceContainerLowest: dark ? const Color(0xFF0B0B0B) : Colors.white,
    surfaceContainerLow: dark ? const Color(0xFF181818) : const Color(0xFFF2F2F2),
    surfaceContainer: dark ? const Color(0xFF1F1F1F) : const Color(0xFFEDEDED),
    surfaceContainerHigh: dark ? const Color(0xFF262626) : const Color(0xFFE6E6E6),
    surfaceContainerHighest: dark ? const Color(0xFF2F2F2F) : const Color(0xFFDDDDDD),
    secondaryContainer: dark ? const Color(0xFF3A1214) : const Color(0xFFFFDAD6),
    onSecondaryContainer: dark ? Colors.white : const Color(0xFF410002),
  );
  return ThemeData(
    colorScheme: scheme,
    useMaterial3: true,
    scaffoldBackgroundColor: scheme.surface,
    visualDensity: VisualDensity.adaptivePlatformDensity,
    appBarTheme: AppBarTheme(
      backgroundColor: scheme.surface,
      foregroundColor: scheme.onSurface,
      surfaceTintColor: Colors.transparent,
      elevation: 0,
      titleTextStyle: TextStyle(fontSize: 20, fontWeight: FontWeight.w700, color: scheme.onSurface),
    ),
    drawerTheme: DrawerThemeData(backgroundColor: dark ? const Color(0xFF0F0F0F) : scheme.surface),
    navigationBarTheme: NavigationBarThemeData(
      backgroundColor: dark ? const Color(0xFF0F0F0F) : scheme.surface,
      indicatorColor: brandRed.withValues(alpha: 0.25),
    ),
    cardTheme: CardThemeData(color: scheme.surfaceContainer, surfaceTintColor: Colors.transparent),
    dialogTheme: DialogThemeData(backgroundColor: scheme.surfaceContainerLow),
    filledButtonTheme: FilledButtonThemeData(
      style: FilledButton.styleFrom(shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(4))),
    ),
    outlinedButtonTheme: OutlinedButtonThemeData(
      style: OutlinedButton.styleFrom(shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(4))),
    ),
  );
}

/// 앱 안 "오픈소스 라이선스" 화면에 Dart 패키지 말고 함께 들어간 네이티브 구성요소도 보이게
void _registerNativeLicenses() {
  LicenseRegistry.addLicense(() async* {
    yield const LicenseEntryWithLineBreaks(['mpv (libmpv)'],
        'mpv — GNU LGPL v2.1+ or GPL v2+ depending on build configuration.\nhttps://mpv.io  /  source: https://github.com/mpv-player/mpv\nBinary from https://github.com/media-kit/libmpv-win32-video-build');
    yield const LicenseEntryWithLineBreaks(['FFmpeg'],
        'FFmpeg — GNU LGPL v2.1+ or GPL v2+ depending on build configuration.\nhttps://ffmpeg.org  /  source: https://git.ffmpeg.org/ffmpeg.git');
    yield const LicenseEntryWithLineBreaks(['PDFium'], 'PDFium — BSD 3-Clause License.\nhttps://pdfium.googlesource.com/pdfium/  /  binaries: https://github.com/bblanchon/pdfium-binaries');
    yield const LicenseEntryWithLineBreaks(['SQLite'], 'SQLite is in the Public Domain. https://sqlite.org/copyright.html');
    yield const LicenseEntryWithLineBreaks(['7-Zip'],
        '7-Zip — Copyright (C) Igor Pavlov.\nGNU LGPL + BSD 3-clause (some parts) + unRAR license restriction:\nthe unRAR code may not be used to develop a RAR (WinRAR) compatible archiver.\nFull text: tools\\7zip\\License.txt — https://www.7-zip.org');
    yield const LicenseEntryWithLineBreaks(['Microsoft Visual C++ Runtime'],
        'msvcp140.dll, vcruntime140.dll, vcruntime140_1.dll — distributed under the Microsoft Visual Studio redistributable license terms.');
  });
}
