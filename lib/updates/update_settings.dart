import 'package:flutter/material.dart';

import 'app_updater.dart';

class UpdateSettings extends StatefulWidget {
  const UpdateSettings({
    super.key,
    required this.enabled,
    required this.install,
    this.updater,
  });
  final bool enabled;
  final Future<void> Function(Future<void> Function() launch) install;
  final AppUpdater? updater;

  @override
  State<UpdateSettings> createState() => _UpdateSettingsState();
}

class _UpdateSettingsState extends State<UpdateSettings> {
  late final _updater = widget.updater ?? AppUpdater();
  bool _busy = false;
  String _status = 'Проверка GitHub выполняется только по нажатию кнопки.';

  Future<void> _check() async {
    setState(() {
      _busy = true;
      _status = 'Проверка GitHub…';
    });
    try {
      final current = await _updater.currentVersion();
      final release = await _updater.check(current);
      if (!mounted) return;
      if (release == null) {
        setState(() => _status = 'Установлена последняя версия: $current.');
        return;
      }
      final confirmed = await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          scrollable: true,
          title: Text('Доступна версия ${release.tag}'),
          content: Text(
            'Сейчас: $current. Скачать ${(release.size / 1024 / 1024).toStringAsFixed(1)} МБ с GitHub и обновить?\n\nПриложение закроется и запустится снова. Импорты и настройки сохранятся. Переустановка не требуется.',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('Позже'),
            ),
            TextButton(
              onPressed: () => Navigator.pop(context, true),
              child: const Text('Обновить'),
            ),
          ],
        ),
      );
      if (confirmed != true || !mounted) {
        if (mounted) {
          setState(
            () =>
                _status = 'Доступна версия ${release.tag}. Установка отменена.',
          );
        }
        return;
      }
      await _updater.prepare(release, (progress) {
        if (mounted) {
          setState(
            () => _status = progress < 1
                ? 'Скачивание: ${(progress * 100).round()}%'
                : 'Проверка архива и подготовка обновления…',
          );
        }
      });
      if (!mounted) {
        await _updater.cleanup();
        return;
      }
      // Recheck after download: automation could have started in the meantime.
      if (!widget.enabled) {
        await _updater.cleanup();
        setState(
          () => _status =
              'Сначала остановите ввод и завершите операции с файлами.',
        );
        return;
      }
      setState(() => _status = 'Перезапуск для установки обновления…');
      await widget.install(_updater.launchInstaller);
    } catch (error) {
      await _updater.cleanup();
      if (mounted) setState(() => _status = updateError(error));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      const Divider(),
      TextButton.icon(
        onPressed: widget.enabled && !_busy ? _check : null,
        icon: const Icon(Icons.system_update_alt, size: 16),
        label: Text(_busy ? 'Обновление…' : 'Проверить обновления'),
      ),
      Text(
        _status,
        style: const TextStyle(color: Colors.white60, fontSize: 11),
      ),
      if (!widget.enabled)
        const Text(
          'Для обновления остановите ввод и завершите операции с файлами.',
          style: TextStyle(fontSize: 11),
        ),
      const SizedBox(height: 8),
    ],
  );
}
