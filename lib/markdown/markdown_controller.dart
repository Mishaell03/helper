import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as path;

import 'markdown_parser.dart';
import 'markdown_repository.dart';
import 'models.dart';

class MarkdownController extends ChangeNotifier {
  MarkdownController(this.repository);
  final MarkdownRepository repository;
  List<BlockSummary> blocks = [];
  List<ImportedFile> files = [];
  bool showDescriptions = true;
  bool busy = false;
  bool _disposed = false;
  int _loadGeneration = 0;

  Future<void> load() async {
    final generation = ++_loadGeneration;
    final newBlocks = await repository.blocks();
    final newFiles = await repository.files();
    final descriptions = await repository.showDescriptions();
    if (_disposed || generation != _loadGeneration) return;
    blocks = newBlocks;
    files = newFiles;
    showDescriptions = descriptions;
    notifyListeners();
  }

  Future<void> _change(Future<void> Function() operation) async {
    // All controls share this guard, including keyboard-triggered operations.
    if (busy) {
      throw const FormatException('Дождитесь завершения текущей операции.');
    }
    busy = true;
    notifyListeners();
    try {
      await operation();
    } finally {
      try {
        await load();
      } finally {
        busy = false;
        if (!_disposed) notifyListeners();
      }
    }
  }

  Future<({int blocks, List<String> errors})> importPaths(
    List<String> paths,
  ) async {
    var count = 0;
    final errors = <String>[];
    await _change(() async {
      for (final path in paths) {
        try {
          final document = await compute(readMarkdownFile, path);
          await repository.importDocument(document);
          count += document.blocks.length;
        } catch (error) {
          errors.add('${_filename(path)}: ${markdownError(error)}');
        }
      }
    });
    return (blocks: count, errors: errors);
  }

  Future<void> pin(BlockSummary block) =>
      _change(() => repository.setPinned(block.id, !block.pinned));
  Future<void> setArchived(int id, bool archived) =>
      _change(() => repository.setArchived(id, archived));
  Future<void> deleteBlock(int id) => _change(() => repository.deleteBlock(id));
  Future<void> deleteFile(int id) => _change(() => repository.deleteFile(id));
  Future<void> clearUnpinned() => _change(repository.clearUnpinned);
  Future<void> clearEverything() => _change(repository.clearEverything);
  Future<void> resetApplicationData() =>
      _change(repository.resetApplicationData);
  Future<void> setShowDescriptions(bool enabled) =>
      _change(() => repository.setShowDescriptions(enabled));

  @override
  void dispose() {
    _disposed = true;
    super.dispose();
  }
}

String _filename(String filename) => path.basename(filename);

String markdownError(Object error) {
  if (error is FormatException) return error.message;
  if (error is FileSystemException) {
    return 'Не удалось прочитать файл. Проверьте его наличие и права доступа.';
  }
  return 'Не удалось сохранить или загрузить данные. Проверьте доступ к локальной базе и свободное место на диске.';
}
