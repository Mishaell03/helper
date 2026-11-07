import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'background_service.dart';

class HotkeySettings extends StatefulWidget {
  const HotkeySettings({
    super.key,
    this.embedded = false,
    this.preferencesOnly = false,
  });

  final bool embedded;
  final bool preferencesOnly;

  @override
  State<HotkeySettings> createState() => _HotkeySettingsState();
}

class _HotkeySettingsState extends State<HotkeySettings> {
  final _service = BackgroundService.instance;
  Hotkey _toggle = Hotkey.defaultToggle;
  Hotkey _exit = Hotkey.defaultExit;
  bool _busy = true;
  bool _autostart = false;
  String? _message;

  @override
  void initState() {
    super.initState();
    _load();
  }

  String _error(Object error) => backgroundError(error);

  Future<void> _load() async {
    try {
      final settings = await _service.getSettings();
      if (!mounted) return;
      setState(() {
        _toggle = settings.toggle;
        _exit = settings.exit;
        _autostart = settings.autostart;
        _message = settings.warning.isEmpty ? null : settings.warning;
      });
    } catch (error) {
      if (mounted) setState(() => _message = _error(error));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _save({bool defaults = false}) async {
    setState(() => _busy = true);
    try {
      final settings = await _service.save(
        defaults ? Hotkey.defaultToggle : _toggle,
        defaults ? Hotkey.defaultExit : _exit,
      );
      if (!mounted) return;
      setState(() {
        _toggle = settings.toggle;
        _exit = settings.exit;
        _message = 'Сохранено. Глобальные горячие клавиши действуют.';
      });
    } catch (error) {
      if (mounted) setState(() => _message = _error(error));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _record(bool toggle) async {
    setState(() => _busy = true);
    try {
      // Existing registered shortcuts are recorded through WM_HOTKEY instead
      // of performing their action. Other combinations use Flutter key events.
      await _service.setRecording(true);
      if (!mounted) return;
      final hotkey = await showDialog<Hotkey>(
        context: context,
        barrierDismissible: false,
        builder: (_) => const _Recorder(),
      );
      if (mounted && hotkey != null) {
        setState(() {
          if (toggle) {
            _toggle = hotkey;
          } else {
            _exit = hotkey;
          }
          _message = 'Есть несохранённые изменения. Нажмите «Сохранить».';
        });
      }
    } catch (error) {
      if (mounted) setState(() => _message = _error(error));
    } finally {
      try {
        await _service.setRecording(false);
      } catch (error) {
        if (mounted) setState(() => _message = _error(error));
      }
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _setAutostart(bool enabled) async {
    setState(() => _busy = true);
    try {
      final settings = await _service.setAutostart(enabled);
      if (mounted) {
        setState(() {
          _autostart = settings.autostart;
          _message = enabled
              ? 'Автозапуск включён. При входе в Windows окно будет скрыто.'
              : 'Автозапуск отключён.';
        });
      }
    } catch (error) {
      if (mounted) setState(() => _message = _error(error));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final content = SingleChildScrollView(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (!widget.preferencesOnly) ...[
            Text(
              'Горячие клавиши',
              style: Theme.of(context).textTheme.titleMedium,
            ),
            const SizedBox(height: 12),
            const Text('Показать / скрыть приложение'),
            OutlinedButton(
              onPressed: _busy ? null : () => _record(true),
              child: Text(_toggle.label),
            ),
            const SizedBox(height: 16),
            const Text('Полностью выйти из приложения'),
            OutlinedButton(
              onPressed: _busy ? null : () => _record(false),
              child: Text(_exit.label),
            ),
            const SizedBox(height: 16),
            const Text(
              'Нажмите на сочетание, чтобы записать новое: Ctrl, Alt, Shift '
              'или Win и другая клавиша. Доступность проверяется при сохранении. '
              'Некоторые сочетания зарезервированы Windows. '
              'Кнопка закрытия главного окна только скрывает приложение.',
            ),
            const SizedBox(height: 12),
            TextButton(
              onPressed: _busy ? null : () => _save(defaults: true),
              child: const Text('Восстановить настройки по умолчанию'),
            ),
          ],
          if (!widget.embedded || widget.preferencesOnly) ...[
            if (!widget.preferencesOnly) const Divider(),
            Text('Автозапуск', style: Theme.of(context).textTheme.titleMedium),
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              title: const Text('Запускать вместе с Windows'),
              subtitle: const Text(
                'Запуск в фоне, без показа окна. Изменение сохраняется сразу.',
              ),
              value: _autostart,
              onChanged: _busy ? null : _setAutostart,
            ),
          ],
          if (_message != null) ...[
            const SizedBox(height: 12),
            Text(_message!, key: const Key('hotkeyMessage')),
          ],
        ],
      ),
    );
    final save = FilledButton(
      onPressed: _busy ? null : () => _save(),
      child: const Text('Сохранить'),
    );
    if (widget.embedded) {
      return Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12),
        child: Column(
          children: [
            Expanded(child: content),
            if (!widget.preferencesOnly)
              Align(alignment: Alignment.centerRight, child: save),
          ],
        ),
      );
    }
    return PopScope(
      canPop: !_busy,
      child: AlertDialog(
        title: const Text('Настройки приложения'),
        insetPadding: const EdgeInsets.all(16),
        content: SizedBox(width: 440, child: content),
        actions: [
          TextButton(
            onPressed: _busy ? null : () => Navigator.pop(context),
            child: const Text('Закрыть'),
          ),
          save,
        ],
      ),
    );
  }
}

class _Recorder extends StatefulWidget {
  const _Recorder();

  @override
  State<_Recorder> createState() => _RecorderState();
}

class _RecorderState extends State<_Recorder> {
  final _focus = FocusNode();
  Hotkey? _hotkey;
  String? _error;

  @override
  void initState() {
    super.initState();
    BackgroundService.instance.onRecorded = _accept;
  }

  void _accept(Hotkey key) {
    if (!mounted) return;
    setState(() {
      _hotkey = key.modifiers == 0 ? null : key;
      _error = key.modifiers == 0 ? 'Добавьте Ctrl, Alt, Shift или Win.' : null;
    });
  }

  @override
  void dispose() {
    BackgroundService.instance.onRecorded = null;
    _focus.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Focus(
    focusNode: _focus,
    autofocus: true,
    onKeyEvent: (_, event) {
      if (event.logicalKey == LogicalKeyboardKey.escape) {
        if (event is KeyDownEvent) Navigator.pop(context);
        return KeyEventResult.handled;
      }
      final key = Hotkey.fromEvent(event);
      if (key != null) _accept(key);
      // Prevent Tab/Space/Enter from activating dialog controls while recording.
      return KeyEventResult.handled;
    },
    child: AlertDialog(
      title: const Text('Нажмите сочетание клавиш'),
      content: Text(
        _error ?? _hotkey?.label ?? 'Ожидание нажатия… Esc — отмена',
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Отмена'),
        ),
        FilledButton(
          onPressed: _hotkey == null
              ? null
              : () => Navigator.pop(context, _hotkey),
          child: const Text('Использовать'),
        ),
      ],
    ),
  );
}
