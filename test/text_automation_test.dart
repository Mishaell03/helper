import 'dart:io';
import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:helper/automation/text_automation.dart';
import 'package:helper/markdown/markdown_repository.dart';

import 'support/markdown_fixture.dart';
import 'support/automation_backend.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory directory;
  late MarkdownRepository repository;
  late TestAutomationBackend backend;
  late TextAutomationController controller;

  setUp(() async {
    directory = await Directory.systemTemp.createTemp('helper_typing_');
    repository = await MarkdownRepository.open(
      databasePath: '${directory.path}/test.sqlite3',
    );
    backend = TestAutomationBackend();
    controller = TextAutomationController(repository, backend: backend);
  });
  tearDown(() async {
    controller.dispose();
    await repository.close();
    await directory.delete(recursive: true);
  });

  Future<int> source(String body) async {
    await repository.importDocument(document('ввод.md', '# Текст\n$body'));
    return (await repository.blocks()).first.id;
  }

  test(
    'Скорость 180 по умолчанию; диапазон и сохранение после повторного открытия SQLite',
    () async {
      await controller.initialize();
      expect(controller.speed, 180);
      await controller.setSpeed(30);
      expect(await repository.typingSpeed(), 30);
      await controller.setSpeed(500);
      expect(await repository.typingSpeed(), 500);
      expect(() => controller.setSpeed(29), throwsFormatException);
      expect(() => controller.setSpeed(501), throwsFormatException);
      await repository.close();
      repository = await MarkdownRepository.open(
        databasePath: '${directory.path}/test.sqlite3',
      );
      expect(await repository.typingSpeed(), 500);
    },
  );

  test('Ошибка изменения скорости не сохраняет фиктивное значение', () async {
    await controller.initialize();
    backend.speedFailure = true;
    await controller.setSpeed(400);
    expect(controller.speed, 180);
    expect(await repository.typingSpeed(), 180);
    expect(controller.failure, 'Скорость не применена.');
  });

  test('Быстрые изменения профиля сохраняются последовательно без потери последнего значения', () async {
    await controller.initialize();
    await Future.wait([controller.setSpeed(80), controller.setSpeed(180), controller.setSpeed(400)]);
    expect(await repository.typingSpeed(), 400);
    expect(controller.speed, 400);
    expect(controller.state.speed, 400);
    expect(controller.savingPreferences, isFalse);
  });

  test(
    'В Win32 передаётся полный Unicode-текст без обрезки и нормализации',
    () async {
      final text = 'Русский English 😀 — «текст»\r\n\r\n  Пробелы\t!\n' * 100;
      final id = await source(text);
      await controller.initialize();
      await controller.start(id);
      expect(backend.receivedText, text);
      expect(controller.state.phase, AutomationPhase.countdown);
      expect(controller.state.countdown, 5);
      expect(controller.protects(id), isTrue);
      expect(controller.canStart, isFalse);
      final calls = backend.calls.where((call) => call.$1 == 'start').length;
      await controller.start(id);
      expect(backend.calls.where((call) => call.$1 == 'start').length, calls);
    },
  );

  test(
    'Пауза и продолжение сохраняют позицию; остановка разрешает запуск с начала',
    () async {
      final id = await source('Строка 1\n\nСтрока 2');
      await controller.initialize();
      await controller.start(id);
      backend.emit(AutomationPhase.typing, position: 4);
      await controller.pause();
      expect(controller.state.phase, AutomationPhase.paused);
      expect(controller.state.position, 4);
      await controller.resume();
      expect(controller.state.phase, AutomationPhase.countdown);
      expect(controller.state.countdown, 5);
      expect(controller.state.position, 4);
      await controller.cancelCountdown();
      expect(controller.state.phase, AutomationPhase.paused);
      expect(controller.state.position, 4);
      await controller.stop();
      expect(controller.state.position, 4);
      expect(controller.canStart, isTrue);
      await controller.start(id);
      expect(controller.state.position, 0);
    },
  );

  test('Отмена начального отсчёта не запускает ввод', () async {
    final id = await source('Текст');
    await controller.initialize();
    await controller.start(id);
    await controller.cancelCountdown();
    expect(controller.state.phase, AutomationPhase.stopped);
    expect(controller.state.position, 0);
    expect(controller.canStart, isTrue);
  });

  test(
    'Аварийная остановка отменяет ещё не завершившееся чтение блока',
    () async {
      final id = await source('Не вводить');
      await controller.initialize();
      final starting = controller.start(id);
      await controller.stop();
      await starting;
      expect(backend.calls.where((call) => call.$1 == 'start'), isEmpty);
      expect(controller.state.phase, AutomationPhase.stopped);
      expect(controller.preparingBlock, isNull);
      expect(controller.protects(id), isFalse);
    },
  );

  test('Устаревшие события состояния не откатывают позицию', () async {
    await controller.initialize();
    backend.emit(AutomationPhase.paused, position: 12, revision: 10);
    backend.emit(AutomationPhase.typing, position: 11, revision: 9);
    expect(controller.state.phase, AutomationPhase.paused);
    expect(controller.state.position, 12);
  });

  test(
    'Stop-токен запрещает отложенному запросу старта заново запустить ввод',
    () async {
      final id = await source('Не вводить после стопа');
      await controller.initialize();
      final gate = backend.startGate = Completer<void>();
      final entered = backend.startEntered = Completer<void>();
      final starting = controller.start(id);
      await entered.future;
      await controller.stop();
      gate.complete();
      await starting;
      expect(controller.state.phase, AutomationPhase.stopped);
      expect(backend.receivedText, isNull);
      expect(controller.failure, isNull);
    },
  );

  test(
    'Без доступной глобальной остановки запуск отклоняется и исходник остаётся',
    () async {
      final id = await source('Сохранённый текст');
      await controller.initialize();
      backend.emergencyAvailable = false;
      await controller.start(id);
      expect(controller.failure, 'Не зарегистрирована клавиша остановки.');
      expect(controller.state.phase, AutomationPhase.idle);
      expect((await repository.block(id)).content, 'Сохранённый текст');
    },
  );

  test(
    'Подключение к уже идущему вводу не меняет его скорость на сохранённую',
    () async {
      backend.data['phase'] = 'typing';
      backend.data['speed'] = 400;
      await controller.initialize();
      expect(controller.speed, 400);
      expect(backend.calls.where((call) => call.$1 == 'setSpeed'), isEmpty);
      expect(controller.canStart, isFalse);
    },
  );

  test(
    'Освобождение контроллера отправляет Stop до отключения обработчика',
    () async {
      final otherBackend = TestAutomationBackend();
      final other = TextAutomationController(repository, backend: otherBackend);
      await other.initialize();
      other.dispose();
      expect(otherBackend.calls.last.$1, 'stop');
      expect(otherBackend.disposed, isTrue);
    },
  );
}
