import 'package:flutter/material.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:helper/text_input_activation.dart';

void main() {
  testWidgets('Editor activates on focus and releases on mouse exit', (
    tester,
  ) async {
    final calls = <bool>[];
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Align(
            alignment: Alignment.topLeft,
            child: SizedBox(
              width: 240,
              height: 80,
              child: TextInputActivation(
                setActive: (active) async => calls.add(active),
                child: const TextField(),
              ),
            ),
          ),
        ),
      ),
    );
    final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
    await mouse.addPointer(location: const Offset(10, 10));
    await tester.tap(find.byType(TextField));
    await tester.pump();
    expect(calls, [true]);
    await tester.enterText(find.byType(TextField), 'SQL 😀');
    expect(find.text('SQL 😀'), findsOneWidget);
    await mouse.moveTo(const Offset(600, 400));
    await tester.pump();
    expect(calls, [true, false]);
    final editable = tester.widget<EditableText>(find.byType(EditableText));
    expect(editable.focusNode.hasFocus, isFalse);
    await mouse.removePointer();
  });

  testWidgets('Removing an editor releases native activation', (tester) async {
    final calls = <bool>[];
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: TextInputActivation(
            setActive: (active) async => calls.add(active),
            child: const TextField(),
          ),
        ),
      ),
    );
    await tester.tap(find.byType(TextField));
    await tester.pump();
    await tester.pumpWidget(const SizedBox());
    expect(calls, [true, false]);
  });
}
