import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:helper/markdown/markdown_controller.dart';
import 'package:helper/markdown/markdown_repository.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'support/markdown_fixture.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory directory;
  late String databasePath;
  late MarkdownRepository repository;

  setUp(() async {
    directory = await Directory.systemTemp.createTemp('helper_database_');
    databasePath = '${directory.path}/test.sqlite3';
    repository = await MarkdownRepository.open(databasePath: databasePath);
  });
  tearDown(() async {
    await repository.close();
    await directory.delete(recursive: true);
  });

  test(
    'Исходники, ID, метаданные, закрепление и настройки переживают перезапуск БД',
    () async {
      const text = '\n# Заголовок\r\n### Описание\r\n\r\nТекст  \r\n\r\n';
      final original = document('файл.md', text);
      final fileId = await repository.importDocument(original);
      final block = (await repository.blocks()).single;
      await repository.setPinned(block.id, true);
      await repository.setArchived(block.id, true);
      await repository.setShowDescriptions(false);
      await repository.close();
      repository = await MarkdownRepository.open(databasePath: databasePath);
      final saved = (await repository.blocks()).single;
      expect(saved.id, block.id);
      expect(saved.fileId, fileId);
      expect(saved.pinned, isTrue);
      expect(saved.archived, isTrue);
      expect(await repository.showDescriptions(), isFalse);
      final full = await repository.block(saved.id);
      expect(full.content, '\r\nТекст  \r\n\r\n');
      expect(full.source, text);
      final archive = await repository.originalFile(fileId);
      expect(archive.text, text);
      expect(archive.bytes, original.bytes);
      final file = (await repository.files()).single;
      expect(file.filename, 'файл.md');
      expect(file.originalBlockCount, 1);
      expect(file.remainingBlockCount, 1);
      expect(file.importedAt.isUtc, isTrue);
    },
  );

  test(
    'Ручной архив и восстановление сохраняют ID, закрепление и весь текст',
    () async {
      await repository.importDocument(
        document('архив.md', '# Блок\n\nТочный текст 😀'),
      );
      final controller = MarkdownController(repository);
      addTearDown(controller.dispose);
      await controller.load();
      final block = controller.blocks.single;
      final before = await repository.block(block.id);
      await controller.pin(block);
      await controller.setArchived(block.id, true);
      expect(controller.blocks.single.archived, isTrue);
      expect(controller.blocks.single.pinned, isTrue);
      await controller.pin(controller.blocks.single);
      expect(controller.blocks.single.pinned, isFalse);
      expect(controller.blocks.single.archived, isTrue);
      await controller.pin(controller.blocks.single);
      expect((await repository.block(block.id)).content, before.content);
      expect((await repository.block(block.id)).source, before.source);
      await controller.setArchived(block.id, false);
      expect(controller.blocks.single.id, block.id);
      expect(controller.blocks.single.archived, isFalse);
      expect(controller.blocks.single.pinned, isTrue);
      expect((await repository.files()).single.remainingBlockCount, 1);
    },
  );

  test(
    'Очистка обычных блоков сохраняет архив независимо от закрепления',
    () async {
      await repository.importDocument(
        document('три.txt', '# Один\n\n1\n---\n# Два\n\n2\n---\n# Три\n\n3'),
      );
      final blocks = await repository.blocks();
      await repository.setPinned(blocks[0].id, true);
      await repository.setArchived(blocks[1].id, true);
      await repository.clearUnpinned();
      expect((await repository.blocks()).map((block) => block.id), [
        blocks[0].id,
        blocks[1].id,
      ]);
      expect((await repository.block(blocks[1].id)).archived, isTrue);
    },
  );

  test('Ошибка ручной архивации оставляет блок и снимает busy', () async {
    await repository.importDocument(document('ошибка.txt', 'Исходный текст'));
    final controller = MarkdownController(repository);
    final connection = await databaseFactoryFfi.openDatabase(
      databasePath,
      options: OpenDatabaseOptions(singleInstance: false),
    );
    try {
      await controller.load();
      final id = controller.blocks.single.id;
      await connection.execute(
        '''CREATE TRIGGER reject_manual_archive BEFORE UPDATE OF archived ON blocks
        BEGIN SELECT RAISE(ABORT, 'manual archive failure'); END''',
      );
      await expectLater(
        controller.setArchived(id, true),
        throwsA(isA<DatabaseException>()),
      );
      expect(controller.busy, isFalse);
      expect(controller.blocks.single.archived, isFalse);
      expect((await repository.block(id)).content, 'Исходный текст');
    } finally {
      controller.dispose();
      await connection.close();
    }
  });

  test(
    'База версии 1 обновляется без потери данных; старые блоки вне архива',
    () async {
      final legacyPath = '${directory.path}/legacy.sqlite3';
      final doc = document('старый.md', '# Старый\n\nСохранить');
      final legacy = await databaseFactoryFfi.openDatabase(
        legacyPath,
        options: OpenDatabaseOptions(
          version: 1,
          onCreate: (db, _) async {
            await db.execute('''CREATE TABLE imported_files (
          id INTEGER PRIMARY KEY AUTOINCREMENT, filename TEXT NOT NULL,
          imported_at INTEGER NOT NULL, block_count INTEGER NOT NULL,
          original_content TEXT NOT NULL, original_bytes BLOB NOT NULL)''');
            await db.execute(
              '''CREATE TABLE blocks (
          id INTEGER PRIMARY KEY AUTOINCREMENT,
          file_id INTEGER NOT NULL REFERENCES imported_files(id) ON DELETE CASCADE,
          position INTEGER NOT NULL, title TEXT NOT NULL, description TEXT NOT NULL,
          content TEXT NOT NULL, source TEXT NOT NULL,
          pinned INTEGER NOT NULL DEFAULT 0 CHECK(pinned IN (0, 1)), UNIQUE(file_id, position))''',
            );
            await db.execute('CREATE INDEX blocks_file ON blocks(file_id)');
            await db.execute(
              'CREATE TABLE preferences (key TEXT PRIMARY KEY, value TEXT NOT NULL)',
            );
            await db.insert('imported_files', {
              'id': 7,
              'filename': doc.filename,
              'imported_at': 0,
              'block_count': 1,
              'original_content': doc.text,
              'original_bytes': doc.bytes,
            });
            await db.insert('blocks', {
              'id': 42,
              'file_id': 7,
              'position': 0,
              'title': 'Старый',
              'description': '',
              'content': '\nСохранить',
              'source': doc.text,
              'pinned': 1,
            });
            await db.insert('preferences', {
              'key': 'show_descriptions',
              'value': 'false',
            });
          },
        ),
      );
      await legacy.close();
      var upgraded = await MarkdownRepository.open(databasePath: legacyPath);
      try {
        final block = (await upgraded.blocks()).single;
        expect(block.id, 42);
        expect(block.archived, isFalse);
        expect(block.pinned, isTrue);
        expect(await upgraded.showDescriptions(), isFalse);
        expect((await upgraded.originalFile(7)).bytes, doc.bytes);
        expect((await upgraded.block(42)).source, doc.text);
        await upgraded.setArchived(42, true);
        await upgraded.close();
        upgraded = await MarkdownRepository.open(databasePath: legacyPath);
        expect((await upgraded.block(42)).archived, isTrue);
        expect((await upgraded.block(42)).id, 42);
      } finally {
        await upgraded.close();
      }
    },
  );

  test(
    'Очистка сохраняет закреплённое; удаление файла затрагивает только его блоки',
    () async {
      final first = await repository.importDocument(
        document('одинаково.md', '# Один\n\n1\n---\n# Два\n\n2'),
      );
      final second = await repository.importDocument(
        document('одинаково.md', '# Три\n\n3\n---\n# Четыре\n\n4'),
      );
      final originalBlocks = await repository.blocks();
      final firstPinned = originalBlocks.firstWhere(
        (block) => block.fileId == first,
      );
      final secondPinned = originalBlocks.firstWhere(
        (block) => block.fileId == second,
      );
      await repository.setPinned(firstPinned.id, true);
      await repository.setPinned(secondPinned.id, true);
      await repository.clearUnpinned();
      final remaining = await repository.blocks();
      expect(remaining, hasLength(2));
      expect(remaining.every((block) => block.pinned), isTrue);
      expect(
        (await repository.files()).every(
          (file) => file.remainingBlockCount == 1,
        ),
        isTrue,
      );
      await repository.deleteFile(first);
      expect((await repository.blocks()).single.id, secondPinned.id);
      expect((await repository.files()).single.id, second);
      await expectLater(repository.originalFile(first), throwsFormatException);
      expect((await repository.originalFile(second)).text, contains('# Три'));
      await repository.clearEverything();
      expect(await repository.blocks(), isEmpty);
      expect(await repository.files(), isEmpty);
    },
  );

  test(
    'Удаление последнего блока удаляет пустой импорт; новые ID не переиспользуются',
    () async {
      await repository.importDocument(document('a.txt', 'Первый'));
      final id = (await repository.blocks()).single.id;
      await repository.deleteBlock(id);
      expect(await repository.files(), isEmpty);
      await repository.importDocument(document('b.txt', 'Второй'));
      expect((await repository.blocks()).single.id, greaterThan(id));
      await expectLater(repository.block(id), throwsFormatException);
    },
  );

  test(
    'Импорт нескольких реальных файлов сообщает ошибки, не повреждая успешные импорты',
    () async {
      final file = File('${directory.path}/реальный.md');
      await file.writeAsString('# Первый\n\nТекст\n---\n# Второй\n\nТекст 2');
      final controller = MarkdownController(repository);
      try {
        final report = await controller.importPaths([
          file.path,
          '${directory.path}/нет.txt',
        ]);
        expect(report.blocks, 2);
        expect(report.errors, hasLength(1));
        expect(controller.blocks, hasLength(2));
        expect(controller.files.single.filename, 'реальный.md');
        expect(controller.busy, isFalse);
        expect(controller.files.single.originalBlockCount, 2);
      } finally {
        controller.dispose();
      }
    },
  );

  test(
    'Список загружает только превью, копирование может получить полный текст',
    () async {
      final body = 'Строка\r\n\r\n' * 1000;
      final title = 'Заголовок ' * 100;
      final description = 'Описание ' * 100;
      await repository.importDocument(
        document('длинный.md', '# $title\n### $description\n$body'),
      );
      final summary = (await repository.blocks()).single;
      expect(summary.preview.length, lessThanOrEqualTo(240));
      expect(summary.title, endsWith('…'));
      expect(summary.description, endsWith('…'));
      final full = await repository.block(summary.id);
      expect(full.content, body);
      expect(full.title, title);
      expect(full.description, description);
      expect(full.content.length, greaterThan(summary.preview.length));
    },
  );

  test(
    'При ошибке SQLite посередине импорта транзакция откатывает и файл, и блоки',
    () async {
      final connection = await databaseFactoryFfi.openDatabase(
        databasePath,
        options: OpenDatabaseOptions(singleInstance: false),
      );
      try {
        await connection.execute(
          '''CREATE TRIGGER reject_test_block BEFORE INSERT ON blocks
        WHEN NEW.title = 'Отказ' BEGIN SELECT RAISE(ABORT, 'test failure'); END''',
        );
        await expectLater(
          repository.importDocument(
            document(
              'атомарно.md',
              '# Первый\n\nТекст\n---\n# Отказ\n\nТекст 2',
            ),
          ),
          throwsA(isA<DatabaseException>()),
        );
        expect(await repository.files(), isEmpty);
        expect(await repository.blocks(), isEmpty);
      } finally {
        await connection.close();
      }
    },
  );
}
