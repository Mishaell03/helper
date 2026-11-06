import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'background_service.dart';

class HotkeySettings extends StatefulWidget {
  const HotkeySettings({super.key});

  @override
  State<HotkeySettings> createState() => _HotkeySettingsState();
}

class _HotkeySettingsState extends State<HotkeySettings> {
  final _service = BackgroundService.instance;
  Hotkey _toggle = Hotkey.defaultToggle;
  Hotkey _exit = Hotkey.defaultExit;
  bool _busy = true;
  String? _message;

  @override
  void initState() {
    super.initState();
    _load();
  }

  String _error(Object error) => error is PlatformException
      ? error.message ?? error.code
      : error.toString();

  Future<void> _load() async {
    try {
      final settings = await _service.getSettings();
      if (!mounted) return;
      setState(() {
        _toggle = settings.toggle;
        _exit = settings.exit;
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
        _message = 'Saved. Global hotkeys are active.';
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
          _message = 'Unsaved changes. Press Save to apply.';
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

  @override
  Widget build(BuildContext context) => PopScope(
    canPop: !_busy,
    child: AlertDialog(
      title: const Text('Hotkey Settings'),
      content: SizedBox(
        width: 440,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text('Toggle visibility'),
              OutlinedButton(
                onPressed: _busy ? null : () => _record(true),
                child: Text(_toggle.label),
              ),
              const SizedBox(height: 16),
              const Text('Fully exit application'),
              OutlinedButton(
                onPressed: _busy ? null : () => _record(false),
                child: Text(_exit.label),
              ),
              const SizedBox(height: 16),
              const Text(
                'Ctrl, Alt, Shift or Win + a key. Windows reserves some '
                'combinations. Conflicts are checked when saving. '
                'Closing the main window only hides it.',
              ),
              if (_message != null) ...[
                const SizedBox(height: 12),
                Text(_message!, key: const Key('hotkeyMessage')),
              ],
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: _busy ? null : () => _save(defaults: true),
          child: const Text('Restore Defaults'),
        ),
        TextButton(
          onPressed: _busy ? null : () => Navigator.pop(context),
          child: const Text('Close'),
        ),
        FilledButton(
          onPressed: _busy ? null : () => _save(),
          child: const Text('Save'),
        ),
      ],
    ),
  );
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
      _error = key.modifiers == 0 ? 'Add Ctrl, Alt, Shift or Win.' : null;
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
      title: const Text('Press a key combination'),
      content: Text(_error ?? _hotkey?.label ?? 'Waiting… (Escape to cancel)'),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: _hotkey == null
              ? null
              : () => Navigator.pop(context, _hotkey),
          child: const Text('Use shortcut'),
        ),
      ],
    ),
  );
}
