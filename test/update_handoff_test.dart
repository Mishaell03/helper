import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:helper/updates/update_handoff.dart';

void main() {
  late Directory work;
  setUp(() async {
    work = await Directory.systemTemp.createTemp('helper_handoff_test_');
  });
  tearDown(() async {
    await work.delete(recursive: true);
  });

  test('Ready handshake does not cancel the installer', () async {
    await awaitUpdateHelper(work, () async {
      await File('${work.path}/ready').writeAsString('ready');
    });
    expect(await File('${work.path}/cancelled').exists(), isFalse);
  });

  test(
    'Early failure is surfaced immediately and cancellation is recorded',
    () async {
      await expectLater(
        awaitUpdateHelper(work, () async {
          await File(
            '${work.path}/failed.json',
          ).writeAsString(jsonEncode({'message': 'Access denied'}));
        }),
        throwsA(
          isA<FormatException>().having(
            (e) => e.message,
            'message',
            contains('Access denied'),
          ),
        ),
      );
      expect(await File('${work.path}/cancelled').exists(), isTrue);
    },
  );

  test('Timeout prevents a late helper from applying the update', () async {
    await expectLater(
      awaitUpdateHelper(
        work,
        () async {},
        timeout: const Duration(milliseconds: 10),
        interval: const Duration(milliseconds: 2),
      ),
      throwsFormatException,
    );
    expect(await File('${work.path}/cancelled').exists(), isTrue);
  });

  test('Native launcher failures retain their original cause', () async {
    await expectLater(
      awaitUpdateHelper(work, () async {
        throw StateError('breakaway denied');
      }),
      throwsStateError,
    );
    expect(await File('${work.path}/cancelled').exists(), isTrue);
  });
}
