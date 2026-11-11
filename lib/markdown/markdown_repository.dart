import 'dart:io';
import 'dart:typed_data';

import 'package:path/path.dart' as path;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'models.dart';
import 'markdown_schema.dart';
import '../background_service.dart';
import '../automation/typing_speed.dart';

class MarkdownRepository {
  MarkdownRepository._(this._database);
  final Database _database;

  static Future<MarkdownRepository> open({String? databasePath}) async {
    sqfliteFfiInit();
    if (databasePath == null) {
      final String directory;
      if (Platform.isWindows) {
        directory = await BackgroundService.instance.storageDirectory();
      } else {
        // Useful for local development; Windows uses SHGetKnownFolderPath.
        final home = Platform.environment['HOME'];
        if (home == null) {
          throw const FormatException(
            'Не удалось определить каталог данных пользователя.',
          );
        }
        directory = Platform.isMacOS
            ? path.join(home, 'Library', 'Application Support', 'helper')
            : path.join(
                Platform.environment['XDG_DATA_HOME'] ??
                    path.join(home, '.local', 'share'),
                'helper',
              );
      }
      await Directory(directory).create(recursive: true);
      databasePath = path.join(directory, 'markdown_helper.sqlite3');
    }
    // sqflite_common_ffi dispatches SQL work to its database worker isolate.
    String? backup;
    try {
      final database = await databaseFactoryFfi.openDatabase(
        databasePath,
        options: OpenDatabaseOptions(
          version: MarkdownSchema.version,
          onConfigure: (db) async {
            await db.execute('PRAGMA foreign_keys = ON');
            await db.execute('PRAGMA busy_timeout = 5000');
            backup = await MarkdownSchema.prepare(db);
          },
          onCreate: (db, _) => MarkdownSchema.migrate(db),
          onUpgrade: (db, _, _) => MarkdownSchema.migrate(db),
          onOpen: (db) => db.transaction(MarkdownSchema.migrate),
        ),
      );
      return MarkdownRepository._(database);
    } on DatabaseException catch (error) {
      throw FormatException(
        'Не удалось открыть или обновить базу Helper. Автоматический сброс не выполнялся. '
        '${backup == null ? '' : 'Резервная копия: $backup. '}'
        'Причина SQLite: $error',
      );
    }
  }

  Future<int> importDocument(ImportedDocument document) =>
      _database.transaction((transaction) async {
        final fileId = await transaction.insert('imported_files', {
          'filename': document.filename,
          'imported_at': DateTime.now().toUtc().millisecondsSinceEpoch,
          'block_count': document.blocks.length,
          'original_content': document.text,
          'original_bytes': document.bytes,
        });
        final batch = transaction.batch();
        for (var i = 0; i < document.blocks.length; i++) {
          final block = document.blocks[i];
          batch.insert('blocks', {
            'file_id': fileId,
            'position': i,
            'title': block.title,
            'description': block.description,
            'content': block.content,
            'source': block.source,
          });
        }
        await batch.commit(noResult: true);
        return fileId;
      });

  Future<List<BlockSummary>> blocks() async => (await _database.rawQuery('''
    SELECT id, file_id, position,
      CASE WHEN length(title) > 160 THEN substr(title, 1, 159) || '…' ELSE title END AS title,
      CASE WHEN length(description) > 240 THEN substr(description, 1, 239) || '…' ELSE description END AS description,
      pinned, archived, insertion_completed,
      CASE WHEN length(content) > 240 THEN substr(content, 1, 239) || '…' ELSE content END AS preview
    FROM blocks ORDER BY file_id DESC, position ASC
  ''')).map(BlockSummary.fromRow).toList();

  Future<ContentBlock> block(int id) async {
    final rows = await _database.query(
      'blocks',
      where: 'id = ?',
      whereArgs: [id],
    );
    if (rows.isEmpty) throw const FormatException('Этот блок уже удалён.');
    return ContentBlock.fromRow(rows.single);
  }

  Future<({String text, Uint8List bytes})> originalFile(int id) async {
    final rows = await _database.query(
      'imported_files',
      columns: ['original_content', 'original_bytes'],
      where: 'id = ?',
      whereArgs: [id],
    );
    if (rows.isEmpty) throw const FormatException('Этот импорт уже удалён.');
    return (
      text: rows.single['original_content'] as String,
      bytes: rows.single['original_bytes'] as Uint8List,
    );
  }

  Future<List<ImportedFile>> files() async => (await _database.rawQuery('''
    SELECT f.id, f.filename, f.imported_at, f.block_count,
      COUNT(b.id) AS remaining_count
    FROM imported_files f LEFT JOIN blocks b ON b.file_id = f.id
    GROUP BY f.id ORDER BY f.id DESC
  ''')).map(ImportedFile.fromRow).toList();

  Future<void> setPinned(int id, bool pinned) async {
    await _database.update(
      'blocks',
      {'pinned': pinned ? 1 : 0},
      where: 'id = ?',
      whereArgs: [id],
    );
  }

  Future<void> setArchived(int id, bool archived) async {
    await _database.update(
      'blocks',
      {'archived': archived ? 1 : 0},
      where: 'id = ?',
      whereArgs: [id],
    );
  }

  Future<void> completeInsertion(int id) async {
    await _database.update(
      'blocks',
      {'archived': 1, 'insertion_completed': 1},
      where: 'id = ?',
      whereArgs: [id],
    );
  }

  Future<void> deleteBlock(int id) =>
      _database.transaction((transaction) async {
        await transaction.delete('blocks', where: 'id = ?', whereArgs: [id]);
        await _removeEmptyImports(transaction);
      });

  // Foreign-key cascade is deliberately scoped to ONE import, including only
  // that import's pinned blocks. Identical filenames are independent imports.
  Future<void> deleteFile(int id) async {
    await _database.delete('imported_files', where: 'id = ?', whereArgs: [id]);
  }

  Future<void> clearUnpinned() => _database.transaction((transaction) async {
    await transaction.delete('blocks', where: 'pinned = 0 AND archived = 0');
    await _removeEmptyImports(transaction);
  });

  Future<void> clearEverything() => _database.transaction((transaction) async {
    await transaction.delete('imported_files');
  });

  Future<void> resetApplicationData() async {
    await _database.execute('PRAGMA secure_delete = ON');
    await _database.transaction((transaction) async {
      await transaction.delete('imported_files');
      await transaction.delete('preferences');
      await transaction.delete(
        'sqlite_sequence',
        where: 'name IN (?, ?)',
        whereArgs: ['blocks', 'imported_files'],
      );
    });
    await _database.execute('VACUUM');
    if (_database.path != inMemoryDatabasePath) {
      // Only our generated snapshots of this database, never arbitrary user
      // files or manually named backups in the same directory.
      final snapshots = RegExp(
        '^${RegExp.escape(path.basename(_database.path))}'
        r'\.backup-v[0-9]+-to-v[0-9]+-[0-9]+\.sqlite3$',
      );
      await for (final file in Directory(
        path.dirname(_database.path),
      ).list(followLinks: false)) {
        if (file is File && snapshots.hasMatch(path.basename(file.path))) {
          await file.delete();
        }
      }
    }
  }

  Future<void> _removeEmptyImports(Transaction transaction) =>
      transaction.execute('''DELETE FROM imported_files WHERE NOT EXISTS
        (SELECT 1 FROM blocks WHERE blocks.file_id = imported_files.id)''');

  Future<bool> showDescriptions() async {
    final rows = await _database.query(
      'preferences',
      where: 'key = ?',
      whereArgs: ['show_descriptions'],
    );
    return rows.isEmpty || rows.first['value'] == 'true';
  }

  Future<void> setShowDescriptions(bool enabled) async {
    await _database.insert('preferences', {
      'key': 'show_descriptions',
      'value': enabled.toString(),
    }, conflictAlgorithm: ConflictAlgorithm.replace);
  }

  Future<void> close() => _database.close();
  Future<int> typingSpeed() async {
    final rows = await _database.query(
      'preferences',
      where: 'key = ?',
      whereArgs: ['automation_cpm'],
    );
    final value = rows.isEmpty
        ? null
        : int.tryParse(rows.single['value'] as String);
    if (value == null) return TypingSpeed.normal;
    final migrated = value.clamp(TypingSpeed.min, TypingSpeed.max);
    if (migrated != value) await setTypingSpeed(migrated);
    return migrated;
  }

  Future<void> setTypingSpeed(int value) async {
    if (value < TypingSpeed.min || value > TypingSpeed.max) {
      throw const FormatException(TypingSpeed.validationMessage);
    }
    await _database.insert('preferences', {
      'key': 'automation_cpm',
      'value': '$value',
    }, conflictAlgorithm: ConflictAlgorithm.replace);
  }
}
