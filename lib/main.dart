import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:window_manager/window_manager.dart';

import 'background_service.dart';
import 'markdown/markdown_controller.dart';
import 'markdown/markdown_panel.dart';
import 'platform.dart';
import 'panel_theme.dart';
import 'ordinary_cursor.dart';
import 'automation/text_automation.dart';
import 'ui_heartbeat.dart';
import 'auto_hide_activity.dart';

UiHeartbeat? _heartbeat;

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  if (isWindows) {
    await windowManager.ensureInitialized();
    await windowManager.waitUntilReadyToShow(
      const WindowOptions(
        size: Size(368, 440),
        minimumSize: Size(360, 300),
        maximumSize: Size(1600, 1200),
        center: true,
        title: 'Помощник',
        skipTaskbar: true,
        titleBarStyle: TitleBarStyle.hidden,
        windowButtonVisibility: false,
      ),
    );
    await windowManager.setAsFrameless();
    await windowManager.setHasShadow(false);
    // Native runner owns DWM alpha composition. Do not also configure an
    // Accent backdrop via window_manager/flutter_acrylic: the extra surface can
    // leave a black capture footprint when the protected window is reshown.
    await windowManager.setAlwaysOnTop(true);
    await BackgroundService.instance.prepareWindow();
  }

  runApp(const MyApp());

  if (isWindows) {
    await WidgetsBinding.instance.waitUntilFirstFrameRasterized;
    await BackgroundService.instance.finishStartup();
    _heartbeat ??= UiHeartbeat(BackgroundService.instance.heartbeat);
    _heartbeat!.start();
  }
}

class MyApp extends StatefulWidget {
  const MyApp({super.key, this.controller, this.pickFiles, this.automation});

  final MarkdownController? controller;
  final Future<List<String>> Function()? pickFiles;
  final TextAutomationController? automation;

  @override
  State<MyApp> createState() => _MyAppState();
}

class _MyAppState extends State<MyApp> {
  final _autoHideObserver = AutoHideModalObserver();

  @override
  void dispose() {
    if (isWindows) _autoHideObserver.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => MaterialApp(
    title: 'Помощник',
    locale: const Locale('ru'),
    supportedLocales: const [Locale('ru')],
    localizationsDelegates: GlobalMaterialLocalizations.delegates,
    debugShowCheckedModeBanner: false,
    theme: buildPanelTheme(),
    navigatorObservers: isWindows ? [_autoHideObserver] : [],
    builder: (context, child) => OrdinaryCursor(
      child: isWindows ? AutoHideActivity(child: child!) : child!,
    ),
    home: MarkdownPanel(
      controller: widget.controller,
      pickFiles: widget.pickFiles,
      automation: widget.automation,
    ),
  );
}
