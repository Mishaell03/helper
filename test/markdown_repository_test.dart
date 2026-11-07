import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:helper/markdown/markdown_controller.dart';
import 'package:helper/markdown/markdown_parser.dart';
import 'package:helper/markdown/markdown_repository.dart';
import 'package:helper/markdown/models.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

ImportedDocument document(String filename, String text) => ImportedDocument(
  filename: filename,
  text: text,
  bytes: Uint8List.fromList(utf8.encode(text)),
  blocks: parseMarkdown(text),
);

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
      await repository.setShowDescriptions(false);
      await repository.close();
      repository = await MarkdownRepository.open(databasePath: databasePath);
      final saved = (await repository.blocks()).single;
      expect(saved.id, block.id);
      expect(saved.fileId, fileId);
      expect(saved.pinned, isTrue);
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
