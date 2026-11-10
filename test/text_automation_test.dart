import 'dart:io';
import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:helper/automation/text_automation.dart';
import 'package:helper/markdown/markdown_repository.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

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
    await controller.flushArchive();
    controller.dispose();
    await repository.close();
    await directory.delete(recursive: true);
  });

  Future<int> source(String body) async {
    await repository.importDocument(document('ввод.md', '# Текст\n$body'));
    return (await repository.blocks()).first.id;
  }

  test(
    'Только подтверждённое завершение архивирует ID операции, без повторов',
    () async {
      final id = await source('Полный текст 😀');
      await controller.initialize();
      await controller.start(id);
      final otherId = await source('Другой выбранный блок');
      var refreshes = 0;
      controller.onArchived = () async {
        refreshes++;
      };
      backend.emit(AutomationPhase.typing, position: 2);
      backend.emit(
        AutomationPhase.completed,
        position: backend.data['total'] as int,
      );
      await controller.flushArchive();
      expect((await repository.block(id)).archived, isTrue);
      expect((await repository.block(otherId)).archived, isFalse);
      expect((await repository.block(id)).content, 'Полный текст 😀');
      expect(refreshes, 1);
      await repository.setArchived(id, false);
      backend.emit(AutomationPhase.completed);
      await controller.setSpeed(
        400,
      ); // Repeated completed snapshots are not new operations.
      await controller.flushArchive();
      expect((await repository.block(id)).archived, isFalse);
      expect(refreshes, 1);
      await controller.start(id);
      backend.emit(
        AutomationPhase.completed,
        position: backend.data['total'] as int,
      );
      await controller.flushArchive();
      expect((await repository.block(id)).archived, isTrue);
      expect(refreshes, 2);
    },
  );

  for (final phase in [
    AutomationPhase.countdown,
    AutomationPhase.typing,
    AutomationPhase.paused,
    AutomationPhase.stopped,
    AutomationPhase.error,
  ]) {
    test(
      'Состояние ${phase.name} не архивирует даже при position == total',
      () async {
        final id = await source('Текст');
        await controller.initialize();
        await controller.start(id);
        backend.emit(phase, position: backend.data['total'] as int);
        await controller.flushArchive();
        expect((await repository.block(id)).archived, isFalse);
      },
    );
  }

  test(
    'Неполное завершение, отмена и стоп не архивируют; старый stopToken отклоняется',
    () async {
      final id = await source('Неоконченный текст');
      await controller.initialize();
      await controller.start(id);
      backend.emit(AutomationPhase.completed, position: 2);
      await controller.flushArchive();
      expect((await repository.block(id)).archived, isFalse);
      await controller.start(id);
      await controller.cancelCountdown();
      await controller.flushArchive();
      expect((await repository.block(id)).archived, isFalse);
      await controller.start(id);
      final oldToken = controller.state.stopToken;
      await controller.stop();
      backend.emit(
        AutomationPhase.completed,
        position: backend.data['total'] as int,
        stopToken: oldToken,
      );
      await controller.flushArchive();
      expect(controller.state.phase, AutomationPhase.stopped);
      expect((await repository.block(id)).archived, isFalse);
      backend.emit(
        AutomationPhase.stopped,
        stopToken: oldToken + 2,
      ); // Native emergency stop.
      await controller.flushArchive();
      expect((await repository.block(id)).archived, isFalse);
    },
  );

  test(
    'Ошибка записи архива не меняет завершённый ввод и не теряет текст',
    () async {
      final id = await source('Сохранить исходник');
      final connection = await databaseFactoryFfi.openDatabase(
        '${directory.path}/test.sqlite3',
        options: OpenDatabaseOptions(singleInstance: false),
      );
      try {
        await connection.execute(
          '''CREATE TRIGGER reject_archive BEFORE UPDATE OF archived ON blocks
        BEGIN SELECT RAISE(ABORT, 'archive test failure'); END''',
        );
        final errors = <String>[];
        controller.onArchiveError = errors.add;
        await controller.initialize();
        await controller.start(id);
        backend.emit(
          AutomationPhase.completed,
          position: backend.data['total'] as int,
        );
        await controller.flushArchive();
        expect(controller.state.phase, AutomationPhase.completed);
        expect(controller.failure, isNull);
        expect(errors, hasLength(1));
        expect((await repository.block(id)).archived, isFalse);
        expect((await repository.block(id)).content, 'Сохранить исходник');
        await connection.execute('DROP TRIGGER reject_archive');
        await repository.setArchived(id, true);
        expect((await repository.block(id)).archived, isTrue);
      } finally {
        await connection.close();
      }
    },
  );

  test(
    'Подтверждённая архивация завершается после dispose контроллера',
    () async {
      final id = await source('Готовый текст');
      final otherBackend = TestAutomationBackend();
      final other = TextAutomationController(repository, backend: otherBackend);
      await other.initialize();
      await other.start(id);
      otherBackend.emit(
        AutomationPhase.completed,
        position: otherBackend.data['total'] as int,
      );
      other.dispose();
      await other.flushArchive();
      expect((await repository.block(id)).archived, isTrue);
    },
  );

  test(
    'Скорость 1000 по умолчанию; диапазон и сохранение после повторного открытия SQLite',
    () async {
      await controller.initialize();
      expect(controller.speed, 1000);
      await controller.setSpeed(300);
      expect(await repository.typingSpeed(), 300);
      await controller.setSpeed(2000);
      expect(await repository.typingSpeed(), 2000);
      expect(() => controller.setSpeed(299), throwsFormatException);
      expect(() => controller.setSpeed(2001), throwsFormatException);
      await repository.close();
      repository = await MarkdownRepository.open(
        databasePath: '${directory.path}/test.sqlite3',
      );
      expect(await repository.typingSpeed(), 2000);
    },
  );

  test('Ошибка изменения скорости не сохраняет фиктивное значение', () async {
    await controller.initialize();
    backend.speedFailure = true;
    await controller.setSpeed(400);
    expect(controller.speed, 1000);
    expect(await repository.typingSpeed(), 1000);
    expect(controller.failure, 'Скорость не применена.');
  });

  test(
    'Старая скорость приводится к диапазону и сохраняется без потери текста',
    () async {
      final id = await source('Сохранить текст');
      final db = await databaseFactoryFfi.openDatabase(
        '${directory.path}/test.sqlite3',
      );
      for (final entry in [(180, 300), (400, 400), (2500, 2000)]) {
        await db.insert('preferences', {
          'key': 'automation_cpm',
          'value': '${entry.$1}',
        }, conflictAlgorithm: ConflictAlgorithm.replace);
        expect(await repository.typingSpeed(), entry.$2);
        final rows = await db.query(
          'preferences',
          where: 'key = ?',
          whereArgs: ['automation_cpm'],
        );
        expect(rows.single['value'], '${entry.$2}');
      }
      expect((await repository.block(id)).content, 'Сохранить текст');
      await db.close();
    },
  );

  test(
    'Быстрые изменения профиля сохраняются последовательно без потери последнего значения',
    () async {
      await controller.initialize();
      await Future.wait([
        controller.setSpeed(300),
        controller.setSpeed(1000),
        controller.setSpeed(400),
      ]);
      expect(await repository.typingSpeed(), 400);
      expect(controller.speed, 400);
      expect(controller.state.speed, 400);
      expect(controller.savingPreferences, isFalse);
    },
  );

  test(
    'В Win32 передаётся полный Unicode-текст без обрезки и нормализации',
    () async {
      final text = 'Русский English 😀 — «текст»\r\n\r\n  Пробелы\t!\n' * 100;
      final id = await source(text);
      await controller.initialize();
      await controller.start(id);
      expect(backend.receivedText, text);
      expect((await repository.block(id)).archived, isFalse);
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
      expect((await repository.block(id)).archived, isFalse);
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
      expect((await repository.block(id)).archived, isFalse);
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
