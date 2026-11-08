import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:helper/ui_heartbeat.dart';

void main() {
  testWidgets('Heartbeat never queues calls behind a blocked native thread', (
    tester,
  ) async {
    final gate = Completer<void>();
    var calls = 0;
    final monitor = UiHeartbeat(() async {
      calls++;
      await gate.future;
    });
    monitor.start();
    monitor.start();
    expect(calls, 1);
    await tester.pump(const Duration(seconds: 10));
    expect(calls, 1);
    gate.complete();
    await tester.pump();
    await tester.pump(const Duration(seconds: 1));
    expect(calls, 2);
    monitor.dispose();
    await tester.pump(const Duration(seconds: 10));
    expect(calls, 2);
  });

  testWidgets('Transient channel errors do not kill the timer or throw', (
    tester,
  ) async {
    var calls = 0;
    final monitor = UiHeartbeat(() async {
      calls++;
      throw StateError('offline');
    });
    monitor.start();
    await tester.pump();
    await tester.pump(const Duration(seconds: 1));
    expect(calls, 2);
    monitor.dispose();
    expect(tester.takeException(), isNull);
  });
}
