import 'dart:ui' show PointerDeviceKind;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:helper/ordinary_cursor.dart';

void main() {
  testWidgets(
    'Arrow overrides all cursors without blocking controls or dialogs',
    (tester) async {
      var clicks = 0;
      var sliderValue = 0.5;
      final scroll = ScrollController();
      addTearDown(scroll.dispose);
      await tester.pumpWidget(
        MaterialApp(
          builder: (_, child) => OrdinaryCursor(child: child!),
          home: Scaffold(
            body: StatefulBuilder(
              builder: (context, setState) => Column(
                children: [
                  TextButton(
                    onPressed: () => clicks++,
                    child: const Text('Button'),
                  ),
                  const TextButton(onPressed: null, child: Text('Disabled')),
                  const SelectableText('Selectable text'),
                  const TextField(),
                  Slider(
                    value: sliderValue,
                    onChanged: (v) => setState(() => sliderValue = v),
                  ),
                  TextButton(
                    onPressed: () => showDialog<void>(
                      context: context,
                      builder: (context) => AlertDialog(
                        actions: [
                          TextButton(
                            onPressed: () => Navigator.pop(context),
                            child: const Text('Close'),
                          ),
                        ],
                      ),
                    ),
                    child: const Text('Dialog'),
                  ),
                  Expanded(
                    child: Scrollbar(
                      controller: scroll,
                      thumbVisibility: true,
                      child: ListView.builder(
                        controller: scroll,
                        itemCount: 100,
                        itemBuilder: (_, i) =>
                            SizedBox(height: 40, child: Text('Row $i')),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      );
      final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
      await mouse.addPointer(location: Offset.zero);
      addTearDown(mouse.removePointer);
      Future<void> arrowAt(Offset point) async {
        await mouse.moveTo(point);
        await tester.pump();
        expect(
          RendererBinding.instance.mouseTracker.debugDeviceActiveCursor(
            1, // TestPointer's default mouse device identifier.
          ),
          SystemMouseCursors.basic,
        );
      }

      for (final finder in [
        find.text('Button'),
        find.text('Disabled'),
        find.byType(SelectableText),
        find.byType(TextField),
        find.byType(Slider),
        find.text('Row 0'),
      ]) {
        await arrowAt(tester.getCenter(finder));
      }
      await tester.tap(find.text('Button'));
      expect(clicks, 1);
      await tester.tap(find.byType(TextField));
      await tester.enterText(find.byType(TextField), 'Text');
      expect(find.text('Text'), findsOneWidget);
      await tester.drag(find.byType(Slider), const Offset(100, 0));
      expect(sliderValue, greaterThan(0.5));
      final rect = tester.getRect(find.byType(Scrollbar));
      await arrowAt(Offset(rect.right - 3, rect.top + 10));
      await tester.drag(find.byType(ListView), const Offset(0, -100));
      expect(scroll.offset, greaterThan(0));
      await tester.tap(find.text('Dialog'));
      await tester.pumpAndSettle();
      await arrowAt(tester.getCenter(find.text('Close')));
      await tester.tap(find.text('Close'));
      await tester.pumpAndSettle();
      expect(find.byType(AlertDialog), findsNothing);
    },
  );
}
