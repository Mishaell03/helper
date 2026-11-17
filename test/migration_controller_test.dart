import 'dart:async';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:helper/migration/migration_controller.dart';
import 'package:path/path.dart' as p;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory root;
  late MigrationController controller;
  late Directory input;
  final calls = <List<String>>[];
  var mode = 'success';
  Completer<void>? processStarted;

  setUp(() async {
    root = await Directory.systemTemp.createTemp('helper-module-test-');
    input = await Directory(p.join(root.path, 'Excel с пробелами')).create();
    final engine = Directory(p.join(root.path, 'engine'));
    await Directory(p.join(engine.path, '_internal')).create(recursive: true);
    await File(p.join(engine.path, 'generator.exe')).writeAsString('fake');
    final model = File(p.join(engine.path, 'models', 'qwen.gguf'));
    await model.parent.create();
    await model.writeAsString('fake');
    mode = 'success';
    processStarted = null;
    calls.clear();
    // flutter_tester lives in <sdk>/bin/cache/artifacts/engine/<platform>.
    final dart = p.normalize(
      p.join(
        p.dirname(Platform.resolvedExecutable),
        '..',
        '..',
        '..',
        'dart-sdk',
        'bin',
        Platform.isWindows ? 'dart.exe' : 'dart',
      ),
    );
    controller = MigrationController(
      engineDirectory: engine,
      settingsFile: File(p.join(root.path, 'settings.json')),
      startProcess: (executable, arguments, workingDirectory) async {
        calls.add(arguments);
        final process = await Process.start(dart, [
          p.absolute('test/fixtures/migration_engine.dart'),
          mode,
          ...arguments,
        ], workingDirectory: workingDirectory);
        processStarted?.complete();
        return process;
      },
    );
    await controller.refresh();
    await controller.setEnabled(true);
  });

  tearDown(() async {
    await controller.cleanup();
    controller.dispose();
    await root.delete(recursive: true);
  });

  Future<void> generate() => controller.generate(
    excelDirectory: '"${input.path}"',
    ddl: 'CREATE TABLE Item (Id INT PRIMARY KEY);',
    useGpu: true,
  );

  test('module is gated by files and persistent opt-in', () async {
    expect(controller.available, isTrue);
    await controller.setEnabled(false);
    await controller.refresh();
    expect(controller.enabled, isFalse);
    await generate();
    expect(calls, isEmpty);
    await controller.setEnabled(true);
    await controller.refresh();
    expect(controller.enabled, isTrue);
    await File(
      p.join(controller.engineDirectory.path, 'models', 'qwen.gguf'),
    ).delete();
    await controller.refresh();
    expect(controller.available, isFalse);
    expect(controller.enabled, isFalse);
  });

  test('both formats, pipes, Unicode inputs and temp-only results', () async {
    await generate();
    expect(controller.status, contains('готовы'));
    expect(controller.excel, isNotNull);
    expect(controller.sql, isNotNull);
    expect(calls, hasLength(2));
    expect(
      calls.first,
      containsAll(['excel-normalized', '--gpu-layers', '-1']),
    );
    expect(calls.last, contains('sql-simple'));
    expect(calls.expand((call) => call), isNot(contains('--column-decisions')));
    expect(calls.first[calls.first.indexOf('--excel-input') + 1], input.path);
    expect(
      await File(
        p.join(controller.workspace!.path, 'schema.sql'),
      ).readAsString(),
      contains('CREATE TABLE'),
    );
    expect(
      p.isWithin(Directory.systemTemp.path, controller.excel!.path),
      isTrue,
    );
    expect(await input.list().isEmpty, isTrue);
  });

  test(
    'missing completed is never success even with output and code zero',
    () async {
      mode = 'no-completed';
      await generate();
      expect(controller.excel, isNull);
      expect(controller.sql, isNull);
      expect(controller.status, contains('completed'));
    },
  );

  test(
    'second-format error does not expose a partially completed pair',
    () async {
      mode = 'fail-sql';
      await generate();
      expect(calls, hasLength(2));
      expect(controller.excel, isNull);
      expect(controller.sql, isNull);
      expect(controller.status, contains('Invalid mapping'));
    },
  );

  test('rejects result path outside output directory', () async {
    mode = 'outside';
    await generate();
    expect(controller.excel, isNull);
    expect(controller.status, contains('неверный путь'));
  });

  test('saves only selected files without changing temp originals', () async {
    await generate();
    final target = p.join(root.path, 'saved');
    final first = await controller.save(
      saveExcel: false,
      saveSql: true,
      destination: target,
    );
    expect(await Directory(first).list().length, 1);
    expect(await File(p.join(first, 'migration.sql')).exists(), isTrue);
    expect(await controller.excel!.exists(), isTrue);
    final second = await controller.save(
      saveExcel: true,
      saveSql: false,
      destination: target,
    );
    expect(first, isNot(second));
    expect(await File(p.join(first, 'migration.sql')).exists(), isTrue);
  });

  test('empty destination uses Windows known desktop folder', () async {
    const channel = MethodChannel('helper/background');
    // Use the same channel name as BackgroundService.
    final desktop = p.join(root.path, 'OneDrive Desktop');
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(channel, (call) async {
      expect(call.method, 'getDesktopDirectory');
      return desktop;
    });
    addTearDown(() => messenger.setMockMethodCallHandler(channel, null));
    await generate();
    final saved = await controller.save(
      saveExcel: true,
      saveSql: true,
      destination: '',
    );
    expect(p.isWithin(desktop, saved), isTrue);
    expect(await Directory(saved).list().length, 2);
  });

  test('new generation removes previous temporary workspace', () async {
    await generate();
    final old = controller.workspace!;
    await generate();
    expect(await old.exists(), isFalse);
    expect(controller.excel, isNotNull);
  });

  test('invalid input is rejected before spawning a process', () async {
    await controller.generate(
      excelDirectory: input.path,
      ddl: '',
      useGpu: false,
    );
    expect(calls, isEmpty);
    expect(controller.status, contains('Вставьте SQL'));
  });

  test('CPU works with older engines without a gpu-layers option', () async {
    await controller.generate(
      excelDirectory: input.path,
      ddl: 'CREATE TABLE Item (Id INT PRIMARY KEY);',
      useGpu: false,
    );
    expect(controller.excel, isNotNull);
    expect(calls.first, isNot(contains('--gpu-layers')));
  });

  test('quoted Explorer path is normalized', () {
    expect(unquotePath('  "C:\\Excel Files"  '), 'C:\\Excel Files');
  });

  test('SQL can be added to the library once per generated pair', () async {
    await generate();
    final imported = <String>[];
    await controller.importSql((file) async => imported.add(file));
    await controller.importSql((file) async => imported.add(file));
    expect(imported, [controller.sql!.path]);
    expect(controller.sqlImported, isTrue);
    expect(await controller.sql!.exists(), isTrue);
    await generate();
    expect(controller.sqlImported, isFalse);
  });

  test('failed SQL import preserves output and allows retry', () async {
    await generate();
    await expectLater(
      controller.importSql(
        (file) async => throw const FormatException('library error'),
      ),
      throwsFormatException,
    );
    expect(controller.sqlImported, isFalse);
    expect(controller.busy, isFalse);
    expect(await controller.sql!.exists(), isTrue);
    await controller.importSql((file) async {});
    expect(controller.sqlImported, isTrue);
  });

  test(
    'generated Excel is moved without touching inputs and survives cleanup',
    () async {
      final inputBook = File(p.join(input.path, 'original.xlsx'));
      await inputBook.writeAsString('untouched input');
      await generate();
      final temporary = controller.excel!;
      final content = await temporary.readAsBytes();
      final target = Directory(p.join(root.path, 'Результаты'));
      final moved = await controller.moveExcel('"${target.path}"');
      expect(p.isWithin(target.path, moved), isTrue);
      expect(await temporary.exists(), isFalse);
      expect(await File(moved).readAsBytes(), content);
      expect(controller.excel!.path, moved);
      expect(controller.excelMoved, isTrue);
      expect(await controller.sql!.exists(), isTrue);
      expect(await controller.moveExcel(target.path), moved);
      await controller.cleanup();
      expect(await File(moved).exists(), isTrue);
      expect(await inputBook.readAsString(), 'untouched input');
    },
  );

  test('failed Excel transfer leaves its temporary original intact', () async {
    await generate();
    final original = controller.excel!;
    final invalid = File(p.join(root.path, 'not-a-directory'));
    await invalid.writeAsString('existing file');
    await expectLater(
      controller.moveExcel(invalid.path),
      throwsA(isA<FileSystemException>()),
    );
    expect(controller.busy, isFalse);
    expect(controller.excelMoved, isFalse);
    expect(await original.exists(), isTrue);
    expect(await invalid.readAsString(), 'existing file');
  });

  test('empty Excel destination resolves the Windows desktop', () async {
    const channel = MethodChannel('helper/background');
    final desktop = p.join(root.path, 'Перенаправленный рабочий стол');
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(channel, (call) async {
      expect(call.method, 'getDesktopDirectory');
      return desktop;
    });
    addTearDown(() => messenger.setMockMethodCallHandler(channel, null));
    await generate();
    final file = await controller.moveExcel('');
    expect(p.isWithin(desktop, file), isTrue);
    expect(await File(file).exists(), isTrue);
  });

  test(
    'cannot move Excel into the workspace that cleanup will delete',
    () async {
      await generate();
      final original = controller.excel!;
      await expectLater(
        controller.moveExcel(p.join(controller.workspace!.path, 'nested')),
        throwsFormatException,
      );
      expect(await original.exists(), isTrue);
      expect(controller.excelMoved, isFalse);
    },
  );

  test('SQL file is copied to temp without altering its bytes', () async {
    final source = File(p.join(root.path, 'Схема таблиц.SQL'));
    final bytes = [255, 254, 67, 0, 82, 0, 69, 0, 65, 0, 84, 0, 69, 0];
    await source.writeAsBytes(bytes);
    await controller.generate(
      excelDirectory: input.path,
      sqlFile: '"${source.path}"',
      useGpu: false,
    );
    expect(controller.excel, isNotNull);
    final staged = File(calls.first[calls.first.indexOf('--sql-input') + 1]);
    expect(p.isWithin(controller.workspace!.path, staged.path), isTrue);
    expect(await staged.readAsBytes(), bytes);
    expect(await source.readAsBytes(), bytes);
  });

  test('missing SQL file never launches the engine', () async {
    await controller.generate(
      excelDirectory: input.path,
      sqlFile: p.join(root.path, 'missing.sql'),
      useGpu: false,
    );
    expect(calls, isEmpty);
    expect(controller.status, contains('существующий локальный файл'));
  });

  test(
    'cancellation kills the process without exposing partial outputs',
    () async {
      mode = 'wait';
      processStarted = Completer<void>();
      final running = generate();
      await processStarted!.future;
      controller.cancel();
      await running;
      expect(controller.busy, isFalse);
      expect(controller.excel, isNull);
      expect(controller.sql, isNull);
      expect(controller.status, contains('отменена'));
    },
  );
}
