import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:helper/transient_message.dart';

void main() {
  testWidgets(
    'Feedback expires at five seconds and a new message restarts it',
    (tester) async {
      Future<void> show(int revision, {bool persistent = false}) =>
          tester.pumpWidget(
            MaterialApp(
              home: TransientMessage(
                identity: revision,
                persistent: persistent,
                child: const Text('Сообщение'),
              ),
            ),
          );
      await show(1);
      await tester.pump(const Duration(seconds: 4));
      expect(find.text('Сообщение'), findsOneWidget);
      await show(2);
      await tester.pump(const Duration(seconds: 4));
      expect(find.text('Сообщение'), findsOneWidget);
      await tester.pump(const Duration(seconds: 1));
      expect(find.text('Сообщение'), findsNothing);
      await show(2);
      expect(find.text('Сообщение'), findsNothing);
      await show(3, persistent: true);
      await tester.pump(const Duration(seconds: 10));
      expect(find.text('Сообщение'), findsOneWidget);
      await show(3);
      await tester.pump(const Duration(seconds: 5));
      expect(find.text('Сообщение'), findsNothing);
      await show(4);
      await tester.pumpWidget(const SizedBox());
      await tester.pump(const Duration(seconds: 6));
      expect(tester.takeException(), isNull);
    },
  );
}
