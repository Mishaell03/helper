import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_acrylic/flutter_acrylic.dart' as acrylic;
import 'package:window_manager/window_manager.dart';

import 'background_service.dart';
import 'markdown/markdown_controller.dart';
import 'markdown/markdown_panel.dart';
import 'platform.dart';
import 'panel_theme.dart';

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
    theme: buildPanelTheme(),
    home: MarkdownPanel(controller: controller, pickFiles: pickFiles),
  );
}
