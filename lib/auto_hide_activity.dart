import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/services.dart';

import 'background_service.dart';

void _send(Future<void> operation) {
  unawaited(
    operation.catchError((Object error) {
      BackgroundService.instance.onWarning?.call(backgroundError(error));
    }),
  );
}

// Popup routes include confirmations, menus, dropdowns and hotkey recording.
// Track routes, not builds, and handle nested/replaced/removed popups as well.
class AutoHideModalObserver extends NavigatorObserver {
  final _popups = <Route<dynamic>>{};

  void _update(Route<dynamic>? add, Route<dynamic>? remove) {
    final wasOpen = _popups.isNotEmpty;
    _popups.remove(remove);
    if (add is PopupRoute) _popups.add(add);
    if (wasOpen != _popups.isNotEmpty) {
      _send(
        BackgroundService.instance.setAutoHideModalOpen(_popups.isNotEmpty),
      );
    }
  }

  @override
  void didPush(Route<dynamic> route, Route<dynamic>? previousRoute) =>
      _update(route, null);
  @override
  void didPop(Route<dynamic> route, Route<dynamic>? previousRoute) =>
      _update(null, route);
  @override
  void didRemove(Route<dynamic> route, Route<dynamic>? previousRoute) =>
      _update(null, route);
  @override
  void didReplace({Route<dynamic>? newRoute, Route<dynamic>? oldRoute}) =>
      _update(newRoute, oldRoute);

  void dispose() {
    _popups.clear();
    _send(BackgroundService.instance.setAutoHideModalOpen(false));
  }
}

class AutoHideActivity extends StatefulWidget {
  const AutoHideActivity({super.key, required this.child});
  final Widget child;

  @override
  State<AutoHideActivity> createState() => _AutoHideActivityState();
}

class _AutoHideActivityState extends State<AutoHideActivity> {
  final _pointers = <int>{};

  @override
  void initState() {
    super.initState();
    HardwareKeyboard.instance.addHandler(_key);
  }

  bool _key(KeyEvent event) {
    if (event is KeyDownEvent || event is KeyRepeatEvent) _activity();
    return false; // Observe only Helper's Flutter events; never consume keys.
  }

  void _activity() => _send(BackgroundService.instance.helperActivity());

  void _release(int pointer) {
    _pointers.remove(pointer);
    if (_pointers.isEmpty) {
      _send(BackgroundService.instance.setAutoHidePointerHeld(false));
      _activity();
    }
  }

  @override
  void dispose() {
    HardwareKeyboard.instance.removeHandler(_key);
    _send(BackgroundService.instance.setAutoHidePointerHeld(false));
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Listener(
    onPointerDown: (event) {
      // A native move/file-dialog loop can own the preceding mouse release.
      // A new mouse press is a new sequence, unlike concurrent touch pointers.
      if (event.kind == PointerDeviceKind.mouse) _pointers.clear();
      _pointers.add(event.pointer);
      _send(BackgroundService.instance.setAutoHidePointerHeld(true));
      _activity();
    },
    onPointerUp: (event) => _release(event.pointer),
    onPointerCancel: (event) => _release(event.pointer),
    onPointerSignal: (_) => _activity(),
    onPointerPanZoomStart: (_) => _activity(),
    onPointerPanZoomUpdate: (_) => _activity(),
    child: widget.child,
  );
}
