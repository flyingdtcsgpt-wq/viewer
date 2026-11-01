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
