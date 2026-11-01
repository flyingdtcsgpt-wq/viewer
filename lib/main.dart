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
    final dark = context.select<Settings, bool>((s) => s.darkMode);
    ThemeData theme(Brightness b) => ThemeData(
          colorSchemeSeed: const Color(0xFF3F6E8C),
          brightness: b,
          useMaterial3: true,
          visualDensity: VisualDensity.adaptivePlatformDensity,
        );
    return MaterialApp(
      title: 'MediaShelf',
      debugShowCheckedModeBanner: false,
      theme: theme(Brightness.light),
      darkTheme: theme(Brightness.dark),
      themeMode: dark ? ThemeMode.dark : ThemeMode.light,
      // 로그인 전에는 아무 목록도 보이지 않는다
      home: context.select<AppState, bool>((s) => s.user != null) ? const HomePage() : const LoginPage(),
    );
  }
}
