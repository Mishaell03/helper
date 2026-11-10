import 'dart:async';

import 'package:flutter/widgets.dart';

/// Hides feedback without clearing the error or operation state behind it.
class TransientMessage extends StatefulWidget {
  const TransientMessage({
    super.key,
    required this.identity,
    required this.child,
    this.persistent = false,
    this.onExpired,
  });

  static const duration = Duration(seconds: 5);
  final Object? identity;
  final Widget child;
  final bool persistent;
  final VoidCallback? onExpired;

  @override
  State<TransientMessage> createState() => _TransientMessageState();
}

class _TransientMessageState extends State<TransientMessage> {
  Timer? _timer;
  bool _visible = true;

  @override
  void initState() {
    super.initState();
    _restart();
  }

  @override
  void didUpdateWidget(TransientMessage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.identity != oldWidget.identity ||
        widget.persistent != oldWidget.persistent) {
      _restart();
    }
  }

  void _restart() {
    _timer?.cancel();
    _visible = true;
    if (!widget.persistent) {
      _timer = Timer(TransientMessage.duration, () {
        if (mounted) widget.onExpired?.call();
        if (mounted) setState(() => _visible = false);
      });
    }
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) =>
      _visible ? widget.child : const SizedBox.shrink();
}
