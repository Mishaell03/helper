import 'dart:async';

/// Proves the UI isolate can execute callbacks. A pending native call is never
/// piled up with more requests if the Windows platform thread is blocked.
class UiHeartbeat {
  UiHeartbeat(this.send, {this.interval = const Duration(seconds: 1)});
  final Future<void> Function() send;
  final Duration interval;
  Timer? _timer;
  bool _pending = false;
  bool _disposed = false;

  void start() {
    if (_timer != null || _disposed) return;
    _timer = Timer.periodic(interval, (_) => _pulse());
    unawaited(_pulse());
  }

  Future<void> _pulse() async {
    if (_disposed || _pending) return;
    _pending = true;
    try {
      await send();
    } catch (_) {
      // Native watchdog is responsible for hiding; never throw from a timer.
    } finally {
      _pending = false;
    }
  }

  void dispose() {
    _disposed = true;
    _timer?.cancel();
    _timer = null;
  }
}
