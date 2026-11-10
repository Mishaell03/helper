import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:helper/auto_hide_activity.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('helper/background');
  final calls = <MethodCall>[];
  setUp(() {
    calls.clear();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
          calls.add(call);
          return null;
        });
  });
  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
  });

  testWidgets(
    'Активность Helper: нажатия, удержание, прокрутка и клавиши, но не кадры',
    (tester) async {
      late StateSetter rebuild;
      await tester.pumpWidget(
        MaterialApp(
          builder: (_, child) => AutoHideActivity(child: child!),
          home: StatefulBuilder(
            builder: (_, setState) {
              rebuild = setState;
              return const Scaffold(body: TextField());
            },
          ),
        ),
      );
      calls.clear();
      rebuild(() {});
      await tester.pump(const Duration(seconds: 60));
      expect(calls, isEmpty);
      final gesture = await tester.startGesture(
        tester.getCenter(find.byType(TextField)),
      );
      await tester.pump();
      expect(
        calls
            .where((call) => call.method == 'setAutoHidePointerHeld')
            .last
            .arguments,
        isTrue,
      );
      await tester.pump(const Duration(seconds: 60));
      expect(
        calls.where((call) => call.method == 'setAutoHidePointerHeld'),
        hasLength(1),
      );
      await gesture.up();
      await tester.pump();
      expect(
        calls
            .where((call) => call.method == 'setAutoHidePointerHeld')
            .last
            .arguments,
        isFalse,
      );
      calls.clear();
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
      expect(calls.any((call) => call.method == 'helperActivity'), isTrue);
      calls.clear();
      await tester.sendEventToBinding(
        PointerScrollEvent(
          position: tester.getCenter(find.byType(TextField)),
          scrollDelta: const Offset(0, 20),
        ),
      );
      await tester.pump();
      expect(calls.any((call) => call.method == 'helperActivity'), isTrue);
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets(
    'Вложенные модальные окна приостанавливают автоскрытие до закрытия последнего',
    (tester) async {
      final observer = AutoHideModalObserver();
      await tester.pumpWidget(
        MaterialApp(
          navigatorObservers: [observer],
          home: Builder(
            builder: (context) => TextButton(
              onPressed: () => showDialog<void>(
                context: context,
                builder: (context) => AlertDialog(
                  actions: [
                    TextButton(
                      onPressed: () => showDialog<void>(
                        context: context,
                        builder: (inner) => AlertDialog(
                          actions: [
                            TextButton(
                              onPressed: () => Navigator.pop(inner),
                              child: const Text('Закрыть вложенное'),
                            ),
                          ],
                        ),
                      ),
                      child: const Text('Вложенное'),
                    ),
                    TextButton(
                      onPressed: () => Navigator.pop(context),
                      child: const Text('Закрыть главное'),
                    ),
                  ],
                ),
              ),
              child: const Text('Открыть'),
            ),
          ),
        ),
      );
      await tester.tap(find.text('Открыть'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Вложенное'));
      await tester.pumpAndSettle();
      await tester.pump(const Duration(seconds: 60));
      expect(
        calls
            .where((call) => call.method == 'setAutoHideModalOpen')
            .map((call) => call.arguments),
        [true],
      );
      await tester.tap(find.text('Закрыть вложенное'));
      await tester.pumpAndSettle();
      expect(
        calls
            .where((call) => call.method == 'setAutoHideModalOpen')
            .map((call) => call.arguments),
        [true],
      );
      await tester.tap(find.text('Закрыть главное'));
      await tester.pumpAndSettle();
      expect(
        calls
            .where((call) => call.method == 'setAutoHideModalOpen')
            .map((call) => call.arguments),
        [true, false],
      );
      await tester.pumpWidget(const SizedBox());
      observer.dispose();
      await tester.pump();
    },
  );
}
