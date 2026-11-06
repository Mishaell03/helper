import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_acrylic/flutter_acrylic.dart' as acrylic;
import 'package:window_manager/window_manager.dart';

bool get isWindows =>
    !kIsWeb && defaultTargetPlatform == TargetPlatform.windows;

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  if (isWindows) {
    await windowManager.ensureInitialized();
    await acrylic.Window.initialize();
    await windowManager.waitUntilReadyToShow(
      const WindowOptions(
        size: Size(480, 360),
        minimumSize: Size(360, 300),
        center: true,
        backgroundColor: Colors.transparent,
        title: 'Helper',
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
  }

  runApp(const MyApp());

  if (isWindows) {
    await WidgetsBinding.instance.waitUntilFirstFrameRasterized;
    await windowManager.show();
    await windowManager.focus();
  }
}

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Helper',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(
          seedColor: Colors.lightBlue,
          brightness: Brightness.dark,
        ),
        scaffoldBackgroundColor: Colors.transparent,
      ),
      home: const MyHomePage(),
    );
  }
}

/// Only the panel background is translucent; text and controls stay opaque.
class TranslucentPanel extends StatelessWidget {
  const TranslucentPanel({super.key, required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: const Color(0xFF18202E).withValues(alpha: 0.5),
      borderRadius: BorderRadius.circular(20),
      clipBehavior: Clip.antiAlias,
      child: child,
    );
  }
}

class MyHomePage extends StatefulWidget {
  const MyHomePage({super.key});

  @override
  State<MyHomePage> createState() => _MyHomePageState();
}

class _MyHomePageState extends State<MyHomePage> {
  int _counter = 0;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          children: [
            TranslucentPanel(
              child: Row(
                children: [
                  Expanded(
                    child: GestureDetector(
                      behavior: HitTestBehavior.opaque,
                      onPanStart: isWindows
                          ? (_) => windowManager.startDragging()
                          : null,
                      child: const Padding(
                        padding: EdgeInsets.all(16),
                        child: Text('Helper'),
                      ),
                    ),
                  ),
                  if (isWindows) ...[
                    IconButton(
                      tooltip: 'Свернуть',
                      onPressed: () => windowManager.minimize(),
                      icon: const Icon(Icons.remove),
                    ),
                    IconButton(
                      tooltip: 'Закрыть',
                      onPressed: () => windowManager.close(),
                      icon: const Icon(Icons.close),
                    ),
                    const SizedBox(width: 8),
                  ],
                ],
              ),
            ),
            const SizedBox(height: 12),
            Expanded(
              child: TranslucentPanel(
                child: SizedBox.expand(
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      const Text('Счётчик нажатий'),
                      Text(
                        '$_counter',
                        style: Theme.of(context).textTheme.headlineMedium,
                      ),
                      const SizedBox(height: 16),
                      IconButton(
                        onPressed: () => setState(() => _counter++),
                        tooltip: 'Increment',
                        icon: const Icon(Icons.add),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
