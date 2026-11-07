import 'dart:ui' show PointerDeviceKind;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:helper/window_resize_border.dart';
import 'package:window_manager/window_manager.dart';

void main() {
  testWidgets(
    'Все границы используют стрелку и передают правильное направление изменения размера',
    (tester) async {
      final calls = <ResizeEdge>[];
      await tester.pumpWidget(
        MaterialApp(
          home: WindowResizeBorder(
            onResize: (edge) async => calls.add(edge),
            child: const SizedBox.expand(),
          ),
        ),
      );
      for (final edge in ResizeEdge.values) {
        final finder = find.byKey(ValueKey(edge));
        expect(
          tester.widget<MouseRegion>(finder).cursor,
          SystemMouseCursors.basic,
        );
        final device = edge.index + 1;
        final mouse = TestGesture(
          dispatcher: tester.sendEventToBinding,
          kind: PointerDeviceKind.mouse,
          device: device,
        );
        await mouse.addPointer(location: tester.getCenter(finder));
        await tester.pump();
        expect(
          WidgetsBinding.instance.mouseTracker.debugDeviceActiveCursor(device),
          SystemMouseCursors.basic,
        );
        await mouse.down(tester.getCenter(finder));
        await mouse.moveBy(const Offset(30, 30));
        await tester.pump();
        await mouse.up();
        await mouse.removePointer();
        expect(calls.last, edge);
      }
      expect(calls, ResizeEdge.values);
    },
  );

  testWidgets(
    'Двойной щелчок по верхнему краю сохраняет действие вертикального разворачивания',
    (tester) async {
      var maximized = 0;
      await tester.pumpWidget(
        MaterialApp(
          home: WindowResizeBorder(
            onResize: (_) async {},
            onVerticalMaximize: () => maximized++,
            child: const SizedBox.expand(),
          ),
        ),
      );
      final top = find.byKey(const ValueKey(ResizeEdge.top));
      await tester.tap(top);
      await tester.pump(const Duration(milliseconds: 100));
      await tester.tap(top);
      await tester.pump(const Duration(milliseconds: 100));
      expect(maximized, 1);
    },
  );
}
