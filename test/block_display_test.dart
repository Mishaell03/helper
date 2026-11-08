import 'package:flutter_test/flutter_test.dart';
import 'package:helper/markdown/block_display.dart';

void main() {
  test('Small content stays intact, including whitespace and empty text', () {
    for (final text in ['', 'Русский English 😀\r\n\r\n  Текст\t!']) {
      expect(splitDisplayPages(text), [text]);
    }
  });

  test('Large and single-line text is bounded and reconstructs exactly', () {
    for (final text in ['a' * 200000, 'Русский 😀 English\r\n  \t!' * 12000]) {
      final pages = splitDisplayPages(text);
      expect(pages.join(), text);
      expect(
        pages.every((p) => p.isNotEmpty && p.length <= blockDisplayPageSize),
        isTrue,
      );
    }
  });

  test('Page boundaries do not split surrogate pairs or CRLF', () {
    for (final ending in ['😀', '\r\n']) {
      final text = '${'a' * (blockDisplayPageSize - 1)}${ending}tail';
      final pages = splitDisplayPages(text);
      expect(pages.join(), text);
      expect(pages.first.length, blockDisplayPageSize - 1);
      expect(pages[1].startsWith(ending), isTrue);
    }
  });

  test(
    'Worker preparation preserves both content and complete source',
    () async {
      final body = 'x' * 50000;
      final source = '# Заголовок\r\n$body';
      final display = await prepareBlockDisplay(body, source);
      expect(display.content.join(), body);
      expect(display.source.join(), source);
    },
  );
}
