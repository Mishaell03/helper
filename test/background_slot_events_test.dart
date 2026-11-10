import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:helper/background_service.dart';

void main() {
  final binding = TestWidgetsFlutterBinding.ensureInitialized();

  test(
    'Native slot events decode only valid directions and allow detaching',
    () async {
      final service = BackgroundService.instance;
      final directions = <int>[];
      service.onNavigateSlot = directions.add;
      addTearDown(() => service.onNavigateSlot = null);

      Future<void> send(Object? direction) async {
        final reply = Completer<void>();
        binding.channelBuffers.push(
          'helper/background',
          const StandardMethodCodec().encodeMethodCall(
            MethodCall('navigateSlot', direction),
          ),
          (_) => reply.complete(),
        );
        await reply.future;
      }

      for (final direction in [-1, 1, 0, 42, 1.0, '1', null]) {
        await send(direction);
      }
      expect(directions, [-1, 1]);
      service.onNavigateSlot = null;
      await send(1);
      expect(directions, [-1, 1]);
    },
  );
}
