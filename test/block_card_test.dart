import 'package:flutter/material.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:helper/markdown/block_card.dart';
import 'package:helper/markdown/models.dart';

import 'support/double_tap.dart';

void main() {
  testWidgets(
    'Single click selects, only a fast double click opens; buttons stay separate',
    (tester) async {
      var selections = 0;
      var openings = 0;
      var pins = 0;
      final block = BlockSummary.fromRow({
        'id': 1,
        'file_id': 1,
        'position': 0,
        'pinned': 0,
        'title': 'Слот',
        'description': '',
        'preview': 'Текст',
      });
      Future<void> show({bool enabled = true}) => tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SizedBox(
              width: 400,
              height: BlockCard.extent,
              child: BlockCard(
                block: block,
                selected: false,
                showDescriptions: true,
                enabled: enabled,
                onSelect: () => selections++,
                onOpen: () => openings++,
                onAction: (action) {
                  if (action == BlockAction.pin) pins++;
                },
              ),
            ),
          ),
        ),
      );
      await show();
      await tester.tap(
        find.text('Слот'),
        kind: PointerDeviceKind.mouse,
        buttons: kSecondaryMouseButton,
      );
      expect(selections, 0);
      expect(openings, 0);
      await tester.drag(find.text('Слот'), const Offset(0, 60));
      await tester.pumpAndSettle();
      expect(selections, 0);
      expect(openings, 0);
      await tester.tap(find.text('Слот'));
      expect(selections, 1); // No wait for the double-click interval.
      expect(openings, 0);
      await tester.pump(const Duration(milliseconds: 400));
      expect(selections, 1);
      expect(openings, 0);
      await tester.tap(find.text('Слот'));
      await tester.pump(const Duration(milliseconds: 400));
      expect(selections, 2);
      expect(openings, 0);
      await tester.tap(find.text('Слот'));
      final pinPress = await tester.startGesture(
        tester.getCenter(find.byTooltip('Закрепить')),
      );
      await tester.pump(const Duration(milliseconds: 150));
      await pinPress.up();
      await tester.pumpAndSettle();
      expect(openings, 0);
      expect(pins, 1);
      await doubleTap(tester, find.text('Слот'));
      await tester.pumpAndSettle();
      expect(openings, 1);
      await doubleTap(tester, find.byTooltip('Закрепить'));
      await tester.pumpAndSettle();
      expect(pins, 3);
      expect(openings, 1);
      await show(enabled: false);
      await doubleTap(tester, find.text('Слот'));
      await tester.pumpAndSettle();
      expect(openings, 1);
    },
  );
}
