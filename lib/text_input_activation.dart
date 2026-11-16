import 'dart:async';

import 'package:flutter/material.dart';

import 'background_service.dart';
import 'platform.dart';

/// Temporarily allows keyboard input without changing the panel's idle policy.
/// Leaving the editable region also releases Flutter focus and restores the
/// previous external foreground window through the native runner.
class TextInputActivation extends StatefulWidget {
  const TextInputActivation({super.key, required this.child, this.setActive});

  final Widget child;
  final Future<void> Function(bool)? setActive;

  @override
  State<TextInputActivation> createState() => _TextInputActivationState();
}

class _TextInputActivationState extends State<TextInputActivation>
    with WidgetsBindingObserver {
  static final _owners = <Object>{};
  final _focus = FocusNode(debugLabel: 'Редактор');
  bool _active = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  void _release() {
    _focus.unfocus();
    _activate(false);
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state != AppLifecycleState.resumed) _release();
  }

  void _activate(bool active) {
    if (_active == active) return;
    _active = active;
    if (!isWindows && widget.setActive == null) return;
    final previous = _owners.isNotEmpty;
    if (widget.setActive == null) {
      if (active) {
        _owners.add(this);
      } else {
        _owners.remove(this);
      }
      if (previous == _owners.isNotEmpty) return;
      active = _owners.isNotEmpty;
    }
    unawaited(
      (widget.setActive ?? BackgroundService.instance.setTextInputActive)(
        active,
      ).catchError((Object error) {
        if (mounted) {
          BackgroundService.instance.onWarning?.call(backgroundError(error));
        }
      }),
    );
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _activate(false);
    _focus.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => MouseRegion(
    onExit: (_) => _release(),
    child: Focus(
      focusNode: _focus,
      onFocusChange: _activate,
      child: widget.child,
    ),
  );
}
