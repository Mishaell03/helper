import 'package:flutter_test/flutter_test.dart';

Future<void> doubleTap(WidgetTester tester, Finder target) async {
  await tester.tap(target);
  await tester.pump(const Duration(milliseconds: 100));
  await tester.tap(target);
}
