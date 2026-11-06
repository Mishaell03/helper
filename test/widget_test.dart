// This is a basic Flutter widget test.
//
// To perform an interaction with a widget in your test, use the WidgetTester
// utility in the flutter_test package. For example, you can send tap and scroll
// gestures. You can also use WidgetTester to find child widgets in the widget
// tree, read text, and verify that the values of widget properties are correct.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:helper/main.dart';

void main() {
  testWidgets('Counter increments smoke test', (WidgetTester tester) async {
    // Build our app and trigger a frame.
    await tester.pumpWidget(const MyApp());

    // Verify that our counter starts at 0.
    expect(find.text('0'), findsOneWidget);
    expect(find.text('1'), findsNothing);

    // Tap the '+' icon and trigger a frame.
    await tester.tap(find.byIcon(Icons.add));
    await tester.pump();

    // Verify that our counter has incremented.
    expect(find.text('0'), findsNothing);
    expect(find.text('1'), findsOneWidget);
  });

  testWidgets('Transparent background and rounded 50% panels', (tester) async {
    await tester.pumpWidget(const MyApp());

    final scaffold = tester.widget<Scaffold>(find.byType(Scaffold));
    final context = tester.element(find.byType(Scaffold));
    expect(
      scaffold.backgroundColor ?? Theme.of(context).scaffoldBackgroundColor,
      Colors.transparent,
    );

    expect(find.byType(TranslucentPanel), findsNWidgets(2));
    for (final panel in find.byType(TranslucentPanel).evaluate()) {
      final material = tester.widget<Material>(
        find
            .descendant(
              of: find.byWidget(panel.widget),
              matching: find.byType(Material),
            )
            .first,
      );
      expect(material.color!.a, 0.5);
      expect(material.borderRadius, BorderRadius.circular(20));
      expect(material.clipBehavior, Clip.antiAlias);
    }
  });
}
