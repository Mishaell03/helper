import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as path;

/// File handshake only. The real native launcher is injected by AppUpdater.
Future<void> awaitUpdateHelper(
  Directory work,
  Future<void> Function() launch, {
  Duration timeout = const Duration(seconds: 20),
  Duration interval = const Duration(milliseconds: 100),
}) async {
  try {
    await launch();
    final deadline = DateTime.now().add(timeout);
    final ready = File(path.join(work.path, 'ready'));
    final failed = File(path.join(work.path, 'failed.json'));
    while (true) {
      if (await failed.exists()) {
        final data =
            jsonDecode(await failed.readAsString()) as Map<String, dynamic>;
        throw FormatException(
          'Процесс обновления завершился с ошибкой: ${data['message']}',
        );
      }
      if (await ready.exists()) return;
      if (DateTime.now().isAfter(deadline)) {
        throw const FormatException(
          'Процесс обновления не подтвердил готовность. Приложение не будет закрыто.',
        );
      }
      await Future<void>.delayed(interval);
    }
  } catch (_) {
    try {
      await File(path.join(work.path, 'cancelled')).writeAsString('cancelled');
    } catch (_) {
      /* AppUpdater also cancels the native process by its handle. */
    }
    rethrow;
  }
}
