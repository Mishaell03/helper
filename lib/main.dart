import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_acrylic/flutter_acrylic.dart' as acrylic;
import 'package:window_manager/window_manager.dart';

import 'background_service.dart';
import 'markdown/markdown_controller.dart';
import 'markdown/markdown_panel.dart';
import 'platform.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  BackgroundSettings? startup;

  if (isWindows) {
    await windowManager.ensureInitialized();
    await acrylic.Window.initialize();
    await windowManager.waitUntilReadyToShow(
      const WindowOptions(
        size: Size(368, 440),
        minimumSize: Size(360, 300),
        maximumSize: Size(1600, 1200),
        center: true,
        backgroundColor: Colors.transparent,
        title: 'Помощник',
        skipTaskbar: true,
        titleBarStyle: TitleBarStyle.hidden,
        windowButtonVisibility: false,
      ),
    );
    await windowManager.setAsFrameless();
    await windowManager.setHasShadow(false);
    await acrylic.Window.setEffect(
      effect: acrylic.WindowEffect.transparent,
      color: Colors.transparent,
    );
    await windowManager.setAlwaysOnTop(true);
    startup = await BackgroundService.instance.prepareWindow();
  }

  runApp(const MyApp());

  if (isWindows) {
    await WidgetsBinding.instance.waitUntilFirstFrameRasterized;
    if (!startup!.startHidden) await BackgroundService.instance.show();
  }
}

class MyApp extends StatelessWidget {
  const MyApp({super.key, this.controller, this.pickFiles});

  final MarkdownController? controller;
  final Future<List<String>> Function()? pickFiles;

  @override
  Widget build(BuildContext context) => MaterialApp(
    title: 'Помощник',
    locale: const Locale('ru'),
    supportedLocales: const [Locale('ru')],
    localizationsDelegates: GlobalMaterialLocalizations.delegates,
    debugShowCheckedModeBanner: false,
    theme: ThemeData(
      fontFamily: 'Segoe UI',
      colorScheme: ColorScheme.fromSeed(
        seedColor: const Color(0xFF8792A4),
        brightness: Brightness.dark,
      ),
      scaffoldBackgroundColor: Colors.transparent,
      splashFactory: InkRipple.splashFactory,
      dialogTheme: DialogThemeData(
        backgroundColor: const Color(0xE6242424),
        surfaceTintColor: Colors.transparent,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
      ),
      popupMenuTheme: PopupMenuThemeData(
        color: const Color(0xF02C2C2C),
        surfaceTintColor: Colors.transparent,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
      ),
      snackBarTheme: const SnackBarThemeData(
        backgroundColor: Color(0xEE303030),
        contentTextStyle: TextStyle(color: Colors.white, fontSize: 12),
      ),
    ),
    home: MarkdownPanel(controller: controller, pickFiles: pickFiles),
  );
}
