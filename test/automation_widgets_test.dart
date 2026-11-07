import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:helper/automation/text_automation.dart';
import 'package:helper/main.dart';
import 'package:helper/markdown/markdown_controller.dart';
import 'package:helper/markdown/markdown_repository.dart';

import 'support/automation_backend.dart';
import 'support/markdown_fixture.dart';

void main() {
  late Directory directory;
  late MarkdownRepository repository;
  late MarkdownController markdown;
  late TestAutomationBackend backend;
  late TextAutomationController automation;
  late int id;
  const body = 'Привет English 😀\r\n\r\n  Строка\t!';

  setUp(() async {
    directory = await Directory.systemTemp.createTemp('helper_automation_ui_');
    repository = await MarkdownRepository.open(
      databasePath: '${directory.path}/test.sqlite3',
    );
    await repository.importDocument(
      document('набор.md', '# Тестовый блок\n$body'),
    );
    markdown = MarkdownController(repository);
    await markdown.load();
    id = markdown.blocks.single.id;
    backend = TestAutomationBackend();
    automation = TextAutomationController(repository, backend: backend);
  });
  tearDown(() async {
    automation.dispose();
    markdown.dispose();
    await repository.close();
    await directory.delete(recursive: true);
  });

  Future<void> settle(WidgetTester tester) async {
    final deadline = DateTime.now().add(const Duration(seconds: 10));
    do {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 10)),
      );
      await tester.pump(const Duration(milliseconds: 30));
      if (automation.ready &&
          !automation.savingPreferences &&
          !automation.commandPending &&
          find.byType(CircularProgressIndicator).evaluate().isEmpty &&
          find.byType(LinearProgressIndicator).evaluate().isEmpty) {
        await tester.pumpAndSettle();
        return;
      }
    } while (DateTime.now().isBefore(deadline));
    fail('Операция не завершилась.');
  }

  Future<void> open(WidgetTester tester) async {
    await tester.pumpWidget(
      MyApp(controller: markdown, automation: automation),
    );
    await settle(tester);
    addTearDown(() => tester.pumpWidget(const SizedBox()));
  }

  testWidgets(
    'Старт, отсчёт, отмена, пауза, продолжение и стоп внутри карточки',
    (tester) async {
      await open(tester);
      await tester.tap(
        find.byTooltip('Начать ввод выбранного блока (через 5 с)'),
      );
      await settle(tester);
      expect(backend.receivedText, body);
      expect(automation.state.countdown, 5);
      expect(find.byTooltip('Остановить ввод блока'), findsOneWidget);
      await tester.tap(find.byTooltip('Отменить отсчёт'));
      await settle(tester);
      expect(automation.state.phase, AutomationPhase.stopped);
      expect(automation.state.position, 0);

      // This is the real Dart handler for a native global Start notification.
      backend.onStartRequested!();
      await settle(tester);
      expect(automation.state.countdown, 1);
      expect(
        (backend.calls.lastWhere((call) => call.$1 == 'start').$2
            as Map)['countdownSeconds'],
        1,
      );
      backend.emit(AutomationPhase.typing, position: 3);
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('Пауза ввода'));
      await settle(tester);
      expect(automation.state.position, 3);
      expect(automation.state.phase, AutomationPhase.paused);
      await tester.tap(find.byTooltip('Продолжить ввод'));
      await settle(tester);
      expect(automation.state.countdown, 5);
      expect(automation.state.position, 3);
      await tester.tap(find.byTooltip('Остановить ввод блока'));
      await settle(tester);
      expect(automation.state.phase, AutomationPhase.stopped);
      expect(automation.state.position, 3);
      await tester.tap(
        find.byTooltip('Начать ввод выбранного блока (через 5 с)'),
      );
      await settle(tester);
      expect(automation.state.position, 0);
    },
  );

  testWidgets(
    'Профили скорости и ползунок сохраняют реальные параметры SQLite',
    (tester) async {
      await open(tester);
      await tester.tap(find.text('Тестовый блок'));
      await settle(tester);
      final slider = tester.widget<Slider>(find.byType(Slider));
      final selection = find.byType(SelectionArea);
      expect(selection, findsOneWidget);
      expect(
        find.descendant(
          of: selection,
          matching: find.byKey(const Key('fullBlockContent')),
        ),
        findsOneWidget,
      );
      expect(
        find.descendant(of: selection, matching: find.text('Тестовый блок')),
        findsNothing,
      );
      expect(
        find.descendant(of: selection, matching: find.byType(Slider)),
        findsNothing,
      );
      expect(
        find.descendant(of: selection, matching: find.byType(TextButton)),
        findsNothing,
      );
      expect(slider.min, 300);
      expect(slider.max, 2000);
      expect(slider.value, 1000);
      for (final preset in [
        ('Медленно', 300),
        ('Обычно', 1000),
        ('Быстро', 2000),
      ]) {
        await tester.tap(find.text(preset.$1));
        await settle(tester);
        expect(await tester.runAsync(repository.typingSpeed), preset.$2);
        expect(automation.speed, preset.$2);
      }
      await tester.drag(find.byType(Slider), const Offset(400, 0));
      await settle(tester);
      expect(automation.speed, 2000);
      expect(await tester.runAsync(repository.typingSpeed), 2000);
    },
  );

  testWidgets('Защита от удаления действующего блока и всегда доступный стоп', (
    tester,
  ) async {
    await open(tester);
    backend.onStartRequested!();
    await settle(tester);
    backend.emit(AutomationPhase.paused, position: 5);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Очистить'));
    await settle(tester);
    expect(find.byType(AlertDialog), findsNothing);
    expect(markdown.blocks, hasLength(1));
    expect(
      find.textContaining('Сначала остановите автоматический ввод'),
      findsOneWidget,
    );
    await tester.tap(find.byTooltip('Остановить ввод'));
    await settle(tester);
    expect(automation.state.phase, AutomationPhase.stopped);
    expect(automation.state.position, 5);
    expect(automation.protects(id), isFalse);
  });

  testWidgets(
    'При минимальном размере стоп остаётся доступным в тексте и настройках',
    (tester) async {
      tester.view.physicalSize = const Size(360, 300);
      tester.view.devicePixelRatio = 1;
      addTearDown(() {
        tester.view.resetPhysicalSize();
        tester.view.resetDevicePixelRatio();
      });
      await open(tester);
      backend.onStartRequested!();
      await settle(tester);
      backend.emit(AutomationPhase.typing, position: 4);
      await tester.pumpAndSettle();
      await tester.tap(find.text('Тестовый блок'));
      await settle(tester);
      expect(find.byTooltip('Остановить ввод'), findsOneWidget);
      await tester.tap(find.byTooltip('Назад (Esc)'));
      await settle(tester);
      await tester.tap(find.byTooltip('Настройки'));
      await settle(tester);
      expect(find.byTooltip('Остановить ввод'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.tap(find.byTooltip('Остановить ввод'));
      await settle(tester);
      expect(automation.state.phase, AutomationPhase.stopped);
    },
  );
}
