import 'package:sqflite_common_ffi/sqflite_ffi.dart';

/// Version numbers select upgrades; the actual schema makes them repeatable.
/// Never drop/recreate user tables to recover an incompatible database.
class MarkdownSchema {
  static const version = 4;

  static const _requiredColumns = {
    'imported_files': {
      'id',
      'filename',
      'imported_at',
      'block_count',
      'original_content',
      'original_bytes',
    },
    'blocks': {
      'id',
      'file_id',
      'position',
      'title',
      'description',
      'content',
      'source',
      'pinned',
    },
    'preferences': {'key', 'value'},
  };

  static Future<Set<String>> _columns(
    DatabaseExecutor db,
    String table,
  ) async => (await db.rawQuery(
    'PRAGMA table_info("$table")',
  )).map((row) => (row['name'] as String).toLowerCase()).toSet();

  static Future<({bool empty, Set<String> blocks, bool preferences})> _inspect(
    DatabaseExecutor db,
  ) async {
    final tables = (await db.rawQuery(
      "SELECT name FROM sqlite_master WHERE type = 'table' AND name NOT LIKE 'sqlite_%'",
    )).map((row) => (row['name'] as String).toLowerCase()).toSet();
    if (tables.isEmpty) {
      return (empty: true, blocks: <String>{}, preferences: false);
    }
    var blocks = <String>{};
    for (final entry in _requiredColumns.entries) {
      if (entry.key == 'preferences' && !tables.contains(entry.key)) continue;
      final columns = await _columns(db, entry.key);
      final missing = entry.value.difference(columns);
      if (!tables.contains(entry.key) || missing.isNotEmpty) {
        throw FormatException(
          'Неизвестная или повреждённая структура базы: ${entry.key}, '
          'отсутствуют ${missing.join(', ')}. Автоматический сброс запрещён; '
          'данные не удалены. Сохраните базу и передайте ошибку для восстановления.',
        );
      }
      if (entry.key == 'blocks') blocks = columns;
    }
    return (
      empty: false,
      blocks: blocks,
      preferences: tables.contains('preferences'),
    );
  }

  /// Runs before sqflite's upgrade transaction. VACUUM INTO takes a consistent
  /// SQLite snapshot, including committed WAL pages; a raw File.copy would not.
  static Future<String?> prepare(Database db) async {
    final oldVersion = await db.getVersion();
    if (oldVersion > version) {
      throw FormatException(
        'База создана более новой версией Helper (схема $oldVersion, '
        'поддерживается $version). Установите новую версию приложения. '
        'Понижение версии и удаление базы не выполнялись.',
      );
    }
    final state = await _inspect(db);
    final needsRepair =
        !state.blocks.contains('archived') ||
        !state.blocks.contains('insertion_completed') ||
        !state.preferences;
    if (state.empty ||
        (oldVersion == version && !needsRepair) ||
        db.path == inMemoryDatabasePath) {
      return null;
    }
    final backup =
        '${db.path}.backup-v$oldVersion-to-v$version-'
        '${DateTime.now().microsecondsSinceEpoch}.sqlite3';
    await db.execute('VACUUM INTO ?', [backup]);
    return backup;
  }

  /// onCreate/onUpgrade are already transactional in sqflite. onOpen calls
  /// this inside an explicit transaction to repair same-version schema drift.
  static Future<void> migrate(DatabaseExecutor db) async {
    final state = await _inspect(db);
    if (state.empty) {
      await db.execute('''CREATE TABLE imported_files (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        filename TEXT NOT NULL,
        imported_at INTEGER NOT NULL,
        block_count INTEGER NOT NULL,
        original_content TEXT NOT NULL,
        original_bytes BLOB NOT NULL
      )''');
      await db.execute('''CREATE TABLE blocks (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        file_id INTEGER NOT NULL REFERENCES imported_files(id) ON DELETE CASCADE,
        position INTEGER NOT NULL,
        title TEXT NOT NULL,
        description TEXT NOT NULL,
        content TEXT NOT NULL,
        source TEXT NOT NULL,
        pinned INTEGER NOT NULL DEFAULT 0 CHECK(pinned IN (0, 1)),
        archived INTEGER NOT NULL DEFAULT 0 CHECK(archived IN (0, 1)),
        insertion_completed INTEGER NOT NULL DEFAULT 0 CHECK(insertion_completed IN (0, 1)),
        UNIQUE(file_id, position)
      )''');
    } else {
      if (!state.blocks.contains('archived')) {
        await db.execute(
          'ALTER TABLE blocks ADD COLUMN archived INTEGER '
          'NOT NULL DEFAULT 0 CHECK(archived IN (0, 1))',
        );
      }
      if (!state.blocks.contains('insertion_completed')) {
        // Never infer successful insertion from an older manual archive flag.
        await db.execute(
          'ALTER TABLE blocks ADD COLUMN insertion_completed INTEGER '
          'NOT NULL DEFAULT 0 CHECK(insertion_completed IN (0, 1))',
        );
      }
    }
    await db.execute(
      'CREATE INDEX IF NOT EXISTS blocks_file ON blocks(file_id)',
    );
    await db.execute('''CREATE TABLE IF NOT EXISTS preferences (
      key TEXT PRIMARY KEY, value TEXT NOT NULL
    )''');
  }
}
