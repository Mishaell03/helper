import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter/services.dart';
import 'package:path/path.dart' as path;
import 'update_handoff.dart';

class UpdateFailure implements Exception {
  UpdateFailure(this.stage, this.message, this.logPath);
  final String stage, message;
  final String? logPath;
  @override
  String toString() =>
      '$stage: $message${logPath == null ? '' : '\nЖурнал: $logPath'}';
}

class ReleaseVersion implements Comparable<ReleaseVersion> {
  ReleaseVersion(this.major, this.minor, this.patch);

  factory ReleaseVersion.parse(String value) {
    final match = RegExp(
      r'^v?(\d+)\.(\d+)\.(\d+)(?:\+\d+)?$',
    ).firstMatch(value);
    if (match == null) {
      throw const FormatException('Некорректная версия релиза.');
    }
    return ReleaseVersion(
      int.parse(match[1]!),
      int.parse(match[2]!),
      int.parse(match[3]!),
    );
  }

  final int major, minor, patch;
  @override
  int compareTo(ReleaseVersion other) {
    for (final pair in [
      (major, other.major),
      (minor, other.minor),
      (patch, other.patch),
    ]) {
      final result = pair.$1.compareTo(pair.$2);
      if (result != 0) return result;
    }
    return 0; // SemVer build metadata does not change version precedence.
  }
}

class AppRelease {
  AppRelease(this.tag, this.url, this.size, this.digest);
  static const assetName = 'helper-windows-x64.zip';
  final String tag;
  final Uri url;
  final int size;
  final String digest;

  static AppRelease? newer(Map<String, dynamic> json, String current) {
    if (json['draft'] == true || json['prerelease'] == true) return null;
    final tag = json['tag_name'] as String;
    if (ReleaseVersion.parse(tag).compareTo(ReleaseVersion.parse(current)) <=
        0) {
      return null;
    }
    final assets = (json['assets'] as List).cast<Map<String, dynamic>>();
    final asset = assets.where((a) => a['name'] == assetName).firstOrNull;
    if (asset == null) {
      throw const FormatException('В релизе нет helper-windows-x64.zip.');
    }
    final digest = asset['digest'] as String? ?? '';
    if (!RegExp(r'^sha256:[a-fA-F0-9]{64}$').hasMatch(digest)) {
      throw const FormatException(
        'GitHub не предоставил SHA-256 архива. Обновление отменено.',
      );
    }
    final url = Uri.parse(asset['browser_download_url'] as String);
    if (url.scheme != 'https' ||
        url.host != 'github.com' ||
        !url.path.startsWith('/Mishaell03/helper/releases/download/') ||
        !url.path.endsWith('/$assetName')) {
      throw const FormatException('Недопустимый адрес обновления.');
    }
    final size = asset['size'] as int;
    if (size <= 0 || size > AppUpdater.maxArchiveBytes) {
      throw const FormatException('Недопустимый размер обновления.');
    }
    return AppRelease(tag, url, size, digest.substring(7).toLowerCase());
  }
}

/// No constructor, startup task or timer makes network requests.
class AppUpdater {
  AppUpdater({HttpClient Function()? clientFactory})
    : _clientFactory = clientFactory ?? HttpClient.new;
  final HttpClient Function() _clientFactory;
  static const maxArchiveBytes = 512 * 1024 * 1024;
  static final latestUri = Uri.https(
    'api.github.com',
    '/repos/Mishaell03/helper/releases/latest',
  );
  static const _channel = MethodChannel('helper/background');
  Directory? _work;
  File? _log;
  bool _preserveWork = false;
  bool _helperLaunched = false;

  Future<void> _writeLog(String message) async {
    try {
      await _log?.writeAsString(
        '${DateTime.now().toIso8601String()} $message\n',
        mode: FileMode.append,
        flush: true,
      );
    } catch (_) {
      /* Logging must not mask the real error. */
    }
  }

  Future<String> currentVersion() async =>
      (await _channel.invokeMethod<String>('getAppVersion'))!;

  Future<HttpClientResponse> _get(HttpClient client, Uri uri) async {
    for (var redirects = 0; redirects < 6; redirects++) {
      const hosts = {
        'api.github.com',
        'github.com',
        'release-assets.githubusercontent.com',
        'objects.githubusercontent.com',
        'github-releases.githubusercontent.com',
      };
      if (uri.scheme != 'https' ||
          !hosts.contains(uri.host) ||
          uri.userInfo.isNotEmpty) {
        throw const FormatException('Недопустимый адрес загрузки GitHub.');
      }
      final request = await client
          .getUrl(uri)
          .timeout(const Duration(seconds: 20));
      request.followRedirects = false;
      request.headers.set(HttpHeaders.userAgentHeader, 'Helper-Manual-Updater');
      request.headers.set(
        HttpHeaders.acceptHeader,
        'application/vnd.github+json',
      );
      final response = await request.close().timeout(
        const Duration(seconds: 30),
      );
      if (!{301, 302, 303, 307, 308}.contains(response.statusCode)) {
        return response;
      }
      final location = response.headers.value(HttpHeaders.locationHeader);
      if (location == null) {
        throw const FormatException('Некорректный ответ GitHub.');
      }
      await response.drain<void>().timeout(const Duration(seconds: 30));
      uri = uri.resolve(location);
    }
    throw const FormatException('Слишком много перенаправлений GitHub.');
  }

  Future<AppRelease?> check(String current) async {
    final client = _clientFactory()
      ..connectionTimeout = const Duration(seconds: 20);
    try {
      final response = await _get(client, latestUri);
      if (response.statusCode == 404) {
        throw const FormatException(
          'Публичных релизов пока нет или репозиторий недоступен.',
        );
      }
      if (response.statusCode != 200) {
        throw FormatException(
          'GitHub вернул HTTP ${response.statusCode}. Повторите проверку позже.',
        );
      }
      final bytes = <int>[];
      await for (final chunk in response.timeout(const Duration(seconds: 30))) {
        bytes.addAll(chunk);
        if (bytes.length > 2 * 1024 * 1024) {
          throw const FormatException('Слишком большой ответ GitHub.');
        }
      }
      return AppRelease.newer(
        jsonDecode(utf8.decode(bytes)) as Map<String, dynamic>,
        current,
      );
    } finally {
      client.close(force: true);
    }
  }

  Future<void> prepare(
    AppRelease release,
    void Function(double) progress,
  ) async {
    if (!Platform.isWindows) {
      throw const FormatException('Обновление доступно только в Windows.');
    }
    await cleanup();
    _preserveWork = false;
    _helperLaunched = false;
    final work = _work = await Directory.systemTemp.createTemp(
      'helper_update_',
    );
    final archive = File(path.join(work.path, 'update.zip'));
    final local = Platform.environment['LOCALAPPDATA'];
    _log = File(path.join(work.path, 'update.log'));
    if (local == null) _preserveWork = true;
    if (local != null) {
      try {
        final directory = await Directory(
          path.join(local, 'Helper', 'Updates'),
        ).create(recursive: true);
        _log = File(
          path.join(
            directory.path,
            'update-${DateTime.now().microsecondsSinceEpoch}.log',
          ),
        );
      } catch (_) {
        _preserveWork = true;
      }
    }
    await _writeLog(
      'release=${release.tag} work=${work.path} install=${path.dirname(Platform.resolvedExecutable)}',
    );
    var stage = 'Скачивание';
    final client = _clientFactory()
      ..connectionTimeout = const Duration(seconds: 20);
    try {
      final response = await _get(client, release.url);
      if (response.statusCode != 200) {
        throw FormatException(
          'Ошибка скачивания: HTTP ${response.statusCode}.',
        );
      }
      final sink = archive.openWrite();
      var received = 0;
      try {
        await for (final chunk in response.timeout(
          const Duration(seconds: 30),
        )) {
          received += chunk.length;
          if (received > release.size || received > maxArchiveBytes) {
            throw const FormatException(
              'Размер архива не соответствует релизу.',
            );
          }
          sink.add(chunk);
          progress(received / release.size);
        }
        await sink.flush();
      } finally {
        await sink.close();
      }
      stage = 'Проверка архива';
      if (received != release.size ||
          (await sha256.bind(archive.openRead()).first).toString() !=
              release.digest) {
        throw const FormatException(
          'Проверка SHA-256 или размера не пройдена. Обновление отменено.',
        );
      }
      stage = 'Подготовка файлов';
      _preserveWork = true;
      final script = File(path.join(work.path, 'update.ps1'));
      await script.writeAsString(
        await rootBundle.loadString('assets/update_windows.ps1'),
        encoding: utf8,
      );
      final result = await Process.run(
        _powershell,
        _arguments('Prepare'),
        stdoutEncoding: utf8,
        stderrEncoding: utf8,
      );
      await _writeLog(
        'prepare exit=${result.exitCode}\n${result.stdout}\n${result.stderr}',
      );
      if (result.exitCode != 0) {
        throw FormatException(
          'Не удалось подготовить обновление. Проверьте права записи в папку приложения.\n${result.stderr}',
        );
      }
      _preserveWork = path.isWithin(work.path, _log!.path);
    } catch (error) {
      await _writeLog('$stage failed: $error');
      throw UpdateFailure(
        stage,
        error is FormatException ? error.message : '$error',
        _log?.path,
      );
    } finally {
      client.close(force: true);
    }
  }

  String get _powershell => path.join(
    Platform.environment['SystemRoot'] ?? r'C:\Windows',
    'System32',
    'WindowsPowerShell',
    'v1.0',
    'powershell.exe',
  );
  List<String> _arguments(String mode) => [
    '-NoProfile',
    '-NonInteractive',
    '-ExecutionPolicy',
    'Bypass',
    '-File',
    path.join(_work!.path, 'update.ps1'),
    '-Mode',
    mode,
    '-WorkDir',
    _work!.path,
    '-InstallDir',
    path.dirname(Platform.resolvedExecutable),
    '-AppProcessId',
    '$pid',
    '-LogPath',
    _log!.path,
  ];

  Future<void> launchInstaller() async {
    if (_work == null) throw StateError('Update is not prepared');
    try {
      await _writeLog('launch independent native updater');
      await awaitUpdateHelper(_work!, () async {
        _helperLaunched = true;
        await _channel.invokeMethod<void>('launchUpdate', {
          'workDir': _work!.path,
          'logPath': _log!.path,
        });
      });
      await _writeLog('updater ready; requesting normal application exit');
      // Keep the reference until process exit, so a failed exit can cancel the
      // waiting helper instead of allowing a surprise installation later.
    } catch (error) {
      await _writeLog('handoff failed: $error');
      throw UpdateFailure(
        'Запуск установки',
        error is PlatformException
            ? error.message ?? error.code
            : error is FormatException
            ? error.message
            : '$error',
        _log?.path,
      );
    }
  }

  Future<void> cleanup() async {
    final work = _work;
    _work = null;
    if (work == null) return;
    if (_helperLaunched) {
      try {
        await File(
          path.join(work.path, 'cancelled'),
        ).writeAsString('cancelled');
      } catch (error) {
        await _writeLog('cancellation marker failed: $error');
      }
      try {
        await _channel.invokeMethod<void>('cancelUpdate');
      } catch (error) {
        await _writeLog('native cancellation failed: $error');
      }
    }
    if (!_preserveWork && !_helperLaunched) {
      try {
        if (await work.exists()) await work.delete(recursive: true);
      } catch (error) {
        await _writeLog('cleanup failed: $error');
      }
    }
  }
}

String updateError(Object error) {
  if (error is UpdateFailure) return error.toString();
  if (error is FormatException) return error.message;
  if (error is PlatformException && error.code == 'update_error') {
    return error.message ?? 'Ошибка запуска установки.';
  }
  if (error is FileSystemException) {
    return 'Ошибка доступа к файлам обновления: ${error.message}';
  }
  if (error is ProcessException) {
    return 'Не удалось запустить системный процесс обновления: ${error.message}';
  }
  return 'Не удалось проверить или загрузить обновление. Проверьте подключение к интернету и доступ к GitHub.';
}
