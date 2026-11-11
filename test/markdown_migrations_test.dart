import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:helper/markdown/markdown_repository.dart';
import 'package:helper/markdown/markdown_schema.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'support/markdown_fixture.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory directory;
  late String databasePath;
  final original = document(
    'старый 😀.md',
    '# Старый\r\n\r\nТочный текст 😀  \r\n',
  );

  setUp(() async {
    sqfliteFfiInit();
    final root = await Directory(
      'build/migration-tests',
    ).create(recursive: true);
    directory = await root.createTemp('schema_');
    databasePath = '${directory.absolute.path}/helper.sqlite3';
  });
  tearDown(() => directory.delete(recursive: true));

  Future<Database> inspect([String? file]) => databaseFactoryFfi.openDatabase(
    file == null ? databasePath : File(file).absolute.path,
    options: OpenDatabaseOptions(singleInstance: false),
  );

  Future<List<File>> backups() async => (await directory.list().toList())
      .whereType<File>()
      .where((file) => file.path.contains('.backup-'))
      .toList();

  Future<void> fixture({
    required int version,
    bool archived = false,
    bool completed = false,
    bool preferences = true,
    bool indexConflict = false,
  }) async {
    final db = await inspect();
    try {
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
        pinned INTEGER NOT NULL DEFAULT 0 CHECK(pinned IN (0, 1)),
        custom_metadata TEXT NOT NULL DEFAULT 'keep', UNIQUE(file_id, position))''',
      );
      if (archived) {
        await db.execute(
          'ALTER TABLE blocks ADD COLUMN archived INTEGER NOT NULL DEFAULT 0',
        );
      }
      if (completed) {
        await db.execute(
          'ALTER TABLE blocks ADD COLUMN insertion_completed INTEGER NOT NULL DEFAULT 0',
        );
      }
      await db.insert('imported_files', {
        'id': 7,
        'filename': original.filename,
        'imported_at': 123456,
        'block_count': 1,
        'original_content': original.text,
        'original_bytes': original.bytes,
      });
      await db.insert('blocks', {
        'id': 42,
        'file_id': 7,
        'position': 0,
        'title': 'Старый',
        'description': 'Описание',
        'content': 'Точный текст 😀  \r\n',
        'source': original.text,
        'pinned': 1,
        'custom_metadata': 'do not lose',
        if (archived) 'archived': 1,
        if (completed) 'insertion_completed': 1,
      });
      if (preferences) {
        await db.execute(
          'CREATE TABLE preferences (key TEXT PRIMARY KEY, value TEXT NOT NULL)',
        );
        await db.insert('preferences', {
          'key': 'show_descriptions',
          'value': 'false',
        });
        await db.insert('preferences', {
          'key': 'automation_cpm',
          'value': '450',
        });
        await db.insert('preferences', {
          'key': 'custom_setting',
          'value': 'keep',
        });
      }
      await db.execute('CREATE TABLE extension_notes (value TEXT)');
      await db.insert('extension_notes', {'value': 'keep extra table'});
      if (indexConflict) {
        // Force a real SQLite DDL failure AFTER adding the two flag columns.
        await db.execute('CREATE TABLE blocks_file (value TEXT)');
      }
      await db.setVersion(version);
    } finally {
      await db.close();
    }
  }

  test('Новая база создаётся сразу в текущей схеме без лишней копии', () async {
    final repository = await MarkdownRepository.open(
      databasePath: databasePath,
    );
    try {
      expect(await repository.blocks(), isEmpty);
      expect(await repository.files(), isEmpty);
      expect(await repository.showDescriptions(), isTrue);
      expect(await backups(), isEmpty);
      final db = await inspect();
      try {
        expect(await db.getVersion(), MarkdownSchema.version);
      } finally {
        await db.close();
      }
    } finally {
      await repository.close();
    }
  });

  final cases = [
    for (final version in [0, 1, 2, 3, MarkdownSchema.version])
      for (final archived in [false, true])
        for (final completed in [false, true]) (version, archived, completed),
  ];
  for (final (version, archived, completed) in cases) {
    test(
      'Миграция v$version, archived=$archived, completed=$completed сохраняет данные и повторяется безопасно',
      () async {
        await fixture(
          version: version,
          archived: archived,
          completed: completed,
        );
        final needsBackup =
            version < MarkdownSchema.version || !archived || !completed;
        var repository = await MarkdownRepository.open(
          databasePath: databasePath,
        );
        try {
          final block = (await repository.blocks()).single;
          expect(block.id, 42);
          expect(block.fileId, 7);
          expect(block.title, 'Старый');
          expect(block.description, 'Описание');
          expect(block.pinned, isTrue);
          expect(block.archived, archived);
          expect(block.insertionCompleted, completed);
          expect((await repository.block(42)).content, 'Точный текст 😀  \r\n');
          expect((await repository.block(42)).source, original.text);
          expect((await repository.originalFile(7)).bytes, original.bytes);
          expect(await repository.showDescriptions(), isFalse);
          expect(await repository.typingSpeed(), 450);
          expect(
            (await repository.files()).single.importedAt.millisecondsSinceEpoch,
            123456,
          );
          final db = await inspect();
          try {
            expect(await db.getVersion(), MarkdownSchema.version);
            expect(await db.rawQuery('PRAGMA foreign_key_check'), isEmpty);
            expect(
              (await db.rawQuery(
                'PRAGMA integrity_check',
              )).single.values.single,
              'ok',
            );
            expect(
              (await db.query('blocks')).single['custom_metadata'],
              'do not lose',
            );
            expect(
              (await db.query('extension_notes')).single['value'],
              'keep extra table',
            );
            expect(
              (await db.query(
                'preferences',
                where: 'key = ?',
                whereArgs: ['custom_setting'],
              )).single['value'],
              'keep',
            );
          } finally {
            await db.close();
          }
          final snapshots = await backups();
          expect(snapshots, hasLength(needsBackup ? 1 : 0));
          if (needsBackup) {
            final snapshot = await inspect(snapshots.single.path);
            try {
              expect(await snapshot.getVersion(), version);
              expect((await snapshot.query('blocks')).single['id'], 42);
              expect(
                (await snapshot.query(
                  'imported_files',
                )).single['original_bytes'],
                original.bytes,
              );
              final columns = (await snapshot.rawQuery(
                'PRAGMA table_info(blocks)',
              )).map((row) => row['name']);
              expect(columns.contains('archived'), archived);
              expect(columns.contains('insertion_completed'), completed);
            } finally {
              await snapshot.close();
            }
          }
          await repository.close();
          repository = await MarkdownRepository.open(
            databasePath: databasePath,
          );
          expect((await repository.blocks()).single.id, 42);
          expect(await backups(), hasLength(needsBackup ? 1 : 0));
          await repository.importDocument(
            document('новый.md', '# Новый\n\nТекст'),
          );
          final ids = (await repository.blocks()).map((block) => block.id);
          expect(ids, contains(42));
          expect(ids.any((id) => id > 42), isTrue);
        } finally {
          await repository.close();
        }
      },
    );
  }

  test('Отсутствующая таблица настроек создаётся без потери текстов', () async {
    await fixture(
      version: 3,
      archived: true,
      completed: true,
      preferences: false,
    );
    final repository = await MarkdownRepository.open(
      databasePath: databasePath,
    );
    try {
      expect((await repository.blocks()).single.id, 42);
      expect(await repository.showDescriptions(), isTrue);
      expect(await backups(), hasLength(1));
    } finally {
      await repository.close();
    }
  });

  for (final version in [1, MarkdownSchema.version]) {
    test(
      'Ошибка миграции v$version откатывает колонки и версию, сохраняет резервную копию',
      () async {
        await fixture(version: version, indexConflict: true);
        await expectLater(
          MarkdownRepository.open(databasePath: databasePath),
          throwsA(
            isA<FormatException>().having(
              (error) => error.message,
              'message',
              contains('Резервная копия:'),
            ),
          ),
        );
        final db = await inspect();
        try {
          expect(await db.getVersion(), version);
          final columns = (await db.rawQuery(
            'PRAGMA table_info(blocks)',
          )).map((row) => row['name']);
          expect(columns, isNot(contains('archived')));
          expect(columns, isNot(contains('insertion_completed')));
          expect(
            (await db.query('blocks')).single['content'],
            'Точный текст 😀  \r\n',
          );
          expect(
            (await db.query('imported_files')).single['original_bytes'],
            original.bytes,
          );
          expect(await backups(), hasLength(1));
          await db.execute(
            'DROP TABLE blocks_file',
          ); // Only the deliberate test obstruction.
        } finally {
          await db.close();
        }
        final repository = await MarkdownRepository.open(
          databasePath: databasePath,
        );
        try {
          expect((await repository.blocks()).single.id, 42);
          expect(await backups(), hasLength(2));
        } finally {
          await repository.close();
        }
      },
    );
  }

  test('Более новая схема не понижается и не очищается', () async {
    await fixture(
      version: MarkdownSchema.version + 1,
      archived: true,
      completed: true,
    );
    await expectLater(
      MarkdownRepository.open(databasePath: databasePath),
      throwsA(
        isA<FormatException>().having(
          (error) => error.message,
          'message',
          contains('более новой'),
        ),
      ),
    );
    final db = await inspect();
    try {
      expect(await db.getVersion(), MarkdownSchema.version + 1);
      expect((await db.query('blocks')).single['id'], 42);
      expect(
        (await db.query('imported_files')).single['original_bytes'],
        original.bytes,
      );
      expect(await backups(), isEmpty);
    } finally {
      await db.close();
    }
  });

  test(
    'Неизвестная основная схема не пересоздаётся с потерей данных',
    () async {
      await fixture(version: 3, archived: true, completed: true);
      var db = await inspect();
      await db.execute(
        'ALTER TABLE blocks RENAME COLUMN content TO legacy_content',
      );
      await db.close();
      await expectLater(
        MarkdownRepository.open(databasePath: databasePath),
        throwsA(
          isA<FormatException>().having(
            (error) => error.message,
            'message',
            contains('Автоматический сброс запрещён'),
          ),
        ),
      );
      db = await inspect();
      try {
        expect(await db.getVersion(), 3);
        expect(
          (await db.query('blocks')).single['legacy_content'],
          'Точный текст 😀  \r\n',
        );
        expect((await db.query('blocks')).single['archived'], 1);
      } finally {
        await db.close();
      }
    },
  );

  test('Резервная копия включает подтверждённые записи из WAL', () async {
    await fixture(version: 3, archived: true, completed: true);
    final writer = await inspect();
    await writer.rawQuery('PRAGMA journal_mode = WAL');
    await writer.execute('PRAGMA wal_autocheckpoint = 0');
    await writer.update('blocks', {
      'content': 'Новые данные в WAL 😀',
    }, where: 'id = 42');
    expect(await File('$databasePath-wal').length(), greaterThan(0));
    final repository = await MarkdownRepository.open(
      databasePath: databasePath,
    );
    try {
      expect((await repository.block(42)).content, 'Новые данные в WAL 😀');
      final snapshot = await inspect((await backups()).single.path);
      try {
        expect(
          (await snapshot.query('blocks')).single['content'],
          'Новые данные в WAL 😀',
        );
      } finally {
        await snapshot.close();
      }
    } finally {
      await repository.close();
      await writer.close();
    }
  });

  test(
    'Полный сброс удаляет служебные копии, но не ручные копии пользователя',
    () async {
      await fixture(version: 3, archived: true, completed: true);
      final repository = await MarkdownRepository.open(
        databasePath: databasePath,
      );
      final manual = File('$databasePath.backup-manual.sqlite3');
      await manual.writeAsString('user backup');
      try {
        expect(await backups(), hasLength(2));
        await repository.resetApplicationData();
        expect(await repository.blocks(), isEmpty);
        expect(await repository.files(), isEmpty);
        expect(await backups(), hasLength(1));
        expect(await manual.readAsString(), 'user backup');
      } finally {
        await repository.close();
      }
    },
  );
}
