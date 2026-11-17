import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;

import '../background_service.dart';

/// Optional, externally supplied onedir engine. Never executes through a shell.
class MigrationController extends ChangeNotifier {
  MigrationController({
    required this.engineDirectory,
    required this.settingsFile,
    this.startProcess = startMigrationProcess,
  });

  final Directory engineDirectory;
  final File settingsFile;
  final Future<Process> Function(String, List<String>, String) startProcess;
  bool available = false;
  bool enabled = false;
  bool busy = false;
  bool _disposed = false;
  bool _cancelled = false;
  Process? _process;
  Timer? _watchTimer;
  bool _refreshing = false;
  Directory? workspace;
  File? excel;
  File? sql;
  bool sqlImported = false;
  bool excelMoved = false;
  bool get canCancel => busy && excel == null && sql == null;
  String status = '';
  String get executable => p.join(engineDirectory.path, 'generator.exe');

  static Future<MigrationController> open() async {
    final storage = await BackgroundService.instance.storageDirectory();
    final controller = MigrationController(
      engineDirectory: Directory(
        p.join(
          p.dirname(Platform.resolvedExecutable),
          'modules',
          'ExcelMigrationEngine',
        ),
      ),
      settingsFile: File(p.join(storage, 'migration-module.json')),
    );
    await controller.refresh();
    controller._watchTimer = Timer.periodic(const Duration(seconds: 5), (
      _,
    ) async {
      if (controller.busy || controller._disposed || controller._refreshing) {
        return;
      }
      controller._refreshing = true;
      try {
        await controller.refresh();
      } catch (_) {
        // An optional module must not interfere with the main application.
      } finally {
        controller._refreshing = false;
      }
    });
    return controller;
  }

  void _changed() {
    if (!_disposed) notifyListeners();
  }

  Future<void> refresh() async {
    final previous = (available, enabled);
    available =
        await File(executable).exists() &&
        await Directory(p.join(engineDirectory.path, '_internal')).exists() &&
        await File(
          p.join(engineDirectory.path, 'models', 'qwen.gguf'),
        ).exists();
    try {
      enabled =
          available &&
          (jsonDecode(await settingsFile.readAsString()) as Map)['enabled'] ==
              true;
    } on FileSystemException {
      enabled = false;
    } on FormatException {
      enabled = false;
    } on TypeError {
      enabled = false;
    }
    if (previous != (available, enabled)) _changed();
  }

  Future<void> setEnabled(bool value) async {
    if (busy) return;
    await settingsFile.parent.create(recursive: true);
    await settingsFile.writeAsString(
      jsonEncode({'enabled': value}),
      flush: true,
    );
    enabled = available && value;
    _changed();
  }

  Future<void> generate({
    required String excelDirectory,
    String ddl = '',
    String? sqlFile,
    required bool useGpu,
  }) async {
    if (busy || !enabled) return;
    busy = true;
    _cancelled = false;
    excel = null;
    sql = null;
    sqlImported = false;
    excelMoved = false;
    status = 'Подготовка…';
    _changed();
    try {
      await refresh();
      if (!enabled) {
        throw const FormatException('Внешний модуль недоступен или отключён.');
      }
      final input = Directory(unquotePath(excelDirectory));
      if (!await input.exists()) {
        throw const FormatException('Папка Excel не найдена.');
      }
      final source = sqlFile == null ? null : File(unquotePath(sqlFile));
      if (source != null &&
          (p.extension(source.path).toLowerCase() != '.sql' ||
              !await source.exists())) {
        throw const FormatException(
          'Укажите существующий локальный файл .sql.',
        );
      }
      if (source == null && ddl.trim().isEmpty) {
        throw const FormatException('Вставьте SQL создания таблиц.');
      }
      await cleanup();
      workspace = await Directory.systemTemp.createTemp('helper-migration-');
      final schema = File(p.join(workspace!.path, 'schema.sql'));
      if (source != null) {
        // Preserve BOM/UTF-16 supported by the engine, never rewrite the source.
        await source.copy(schema.path);
      } else {
        await schema.writeAsString(ddl, encoding: utf8, flush: true);
      }
      final generated = <String, File>{};
      for (final format in ['excel-normalized', 'sql-simple']) {
        if (_cancelled) throw const FormatException('Генерация отменена.');
        final output = Directory(p.join(workspace!.path, format));
        await output.create();
        generated[format] = await _generateFormat(
          format,
          input.absolute.path,
          schema.path,
          output,
          useGpu,
        );
      }
      // Publish only after BOTH processes have confirmed completion.
      excel = generated['excel-normalized'];
      sql = generated['sql-simple'];
      status = 'Excel и SQL готовы. Пока они только во временной папке.';
    } catch (error) {
      status = _cancelled ? 'Генерация отменена.' : 'Ошибка: $error';
      if (workspace != null) {
        status += '\nДиагностика: ${workspace!.path}';
      }
    } finally {
      _process = null;
      busy = false;
      if (_disposed) await cleanup();
      _changed();
    }
  }

  Future<File> _generateFormat(
    String format,
    String input,
    String schema,
    Directory output,
    bool gpu,
  ) async {
    final process = await startProcess(executable, [
      'generate-migration',
      '--excel-input',
      input,
      '--sql-input',
      schema,
      '--output-dir',
      output.path,
      '--output-format',
      format,
      '--model-path',
      p.join(engineDirectory.path, 'models', 'qwen.gguf'),
      // CPU is the engine default. Omit the flag for older CPU-only builds.
      if (gpu) ...['--gpu-layers', '-1'],
      '--json-events',
    ], workspace!.path);
    _process = process;
    if (_cancelled) process.kill();
    final diagnostics = File(
      p.join(workspace!.path, '$format.stderr.log'),
    ).openWrite();
    final stderrDone = process.stderr.pipe(diagnostics);
    File? completed;
    String? engineError;
    final stdoutDone = process.stdout
        .transform(utf8.decoder)
        .transform(const LineSplitter())
        .forEach((line) {
          try {
            final event = jsonDecode(line) as Map<String, dynamic>;
            if (event['event'] == 'completed' && event['success'] == true) {
              final file = event['output_file'];
              if (file is String) completed = File(file);
            } else if (event['event'] == 'error') {
              engineError =
                  '${event['message'] ?? event['code'] ?? 'Ошибка движка'}';
            } else if (event['event'] == 'progress') {
              final message =
                  '${event['message'] ?? event['stage'] ?? 'Обработка…'}';
              status =
                  '$format: ${message.length > 500 ? message.substring(0, 500) : message}';
              _changed();
            }
          } on FormatException {
            engineError = 'Неверный JSON от движка.';
          } on TypeError {
            engineError = 'Неверное событие движка.';
          }
        });
    final code = await process.exitCode;
    await Future.wait([stderrDone, stdoutDone]);
    _process = null;
    if (_cancelled) throw const FormatException('Генерация отменена.');
    final file = completed;
    if (code != 0 || engineError != null || file == null) {
      throw FormatException(
        engineError ?? '$format: код $code, нет подтверждения completed.',
      );
    }
    final expectedExtension = format == 'sql-simple' ? '.sql' : '.xlsx';
    if (!p.isWithin(output.absolute.path, file.absolute.path) ||
        p.extension(file.path).toLowerCase() != expectedExtension ||
        !await file.exists()) {
      throw const FormatException('Движок вернул неверный путь результата.');
    }
    return file;
  }

  void cancel() {
    _cancelled = true;
    _process?.kill();
  }

  /// Separate subdirectory and exclusive file creation prevent overwriting data.
  Future<String> save({
    required bool saveExcel,
    required bool saveSql,
    required String destination,
  }) async {
    if (busy || excel == null || sql == null || (!saveExcel && !saveSql)) {
      throw const FormatException('Выберите готовые файлы для сохранения.');
    }
    busy = true;
    _changed();
    try {
      final target = unquotePath(destination);
      final desktop = target.isEmpty
          ? await BackgroundService.instance.desktopDirectory()
          : target;
      final parent = Directory(desktop);
      await parent.create(recursive: true);
      final saved = await parent.createTemp('ExcelMigration-');
      for (final file in [if (saveExcel) excel!, if (saveSql) sql!]) {
        await file.copy(p.join(saved.path, p.basename(file.path)));
      }
      status = 'Сохранено: ${saved.path}';
      return saved.path;
    } finally {
      busy = false;
      if (_disposed) await cleanup();
      _changed();
    }
  }

  Future<void> cleanup() async {
    final previous = workspace;
    if (previous != null && await previous.exists()) {
      await previous.delete(recursive: true);
    }
    workspace = null;
    excel = null;
    sql = null;
    sqlImported = false;
    excelMoved = false;
  }

  Future<void> importSql(Future<void> Function(String) import) async {
    if (busy || sql == null || excel == null) {
      throw const FormatException('Сначала создайте Excel и SQL.');
    }
    if (sqlImported) return;
    busy = true;
    _changed();
    try {
      await import(sql!.path);
      sqlImported = true;
      status = 'SQL добавлен в библиотеку файлов Helper.';
    } finally {
      busy = false;
      if (_disposed) await cleanup();
      _changed();
    }
  }

  /// Only the generated workbook is moved. User input books are never touched.
  /// Copy-then-delete supports destinations on a different volume.
  Future<String> moveExcel(String destination) async {
    if (busy || excel == null || sql == null) {
      throw const FormatException('Сначала создайте Excel и SQL.');
    }
    if (excelMoved) return excel!.path;
    busy = true;
    _changed();
    try {
      final target = unquotePath(destination);
      final parent = Directory(
        target.isEmpty
            ? await BackgroundService.instance.desktopDirectory()
            : target,
      );
      await parent.create(recursive: true);
      final resolved = await parent.resolveSymbolicLinks();
      final temporary = await workspace!.resolveSymbolicLinks();
      if (p.equals(temporary, resolved) || p.isWithin(temporary, resolved)) {
        throw const FormatException(
          'Выберите каталог вне временной папки задачи.',
        );
      }
      final folder = await Directory(resolved).createTemp('ExcelMigration-');
      final original = excel!;
      final moved = await original.copy(
        p.join(folder.path, p.basename(original.path)),
      );
      if (await original.length() != await moved.length()) {
        throw FileSystemException(
          'Не удалось полностью скопировать Excel.',
          moved.path,
        );
      }
      try {
        await original.delete();
      } on FileSystemException {
        throw FileSystemException(
          'Excel скопирован, но удалить временный оригинал не удалось. Копия сохранена.',
          moved.path,
        );
      }
      excel = moved;
      excelMoved = true;
      status = 'Excel перемещён: ${moved.path}';
      return moved.path;
    } finally {
      busy = false;
      if (_disposed) await cleanup();
      _changed();
    }
  }

  @override
  void dispose() {
    _disposed = true;
    _watchTimer?.cancel();
    cancel();
    // Wait for process streams to close before removing its temporary workspace.
    if (!busy) unawaited(cleanup().catchError((Object _) {}));
    super.dispose();
  }
}

Future<Process> startMigrationProcess(
  String executable,
  List<String> arguments,
  String workingDirectory,
) => Process.start(
  executable,
  arguments,
  workingDirectory: workingDirectory,
  runInShell: false,
);

String unquotePath(String value) {
  final text = value.trim();
  return text.length >= 2 && text.startsWith('"') && text.endsWith('"')
      ? text.substring(1, text.length - 1)
      : text;
}
