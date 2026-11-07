import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:helper/markdown/markdown_parser.dart';

void main() {
  test('Разделители, метаданные и точные переводы строк CRLF', () {
    const text =
        '---\r\n# Заказ\r\n### Описание\r\n\r\nШаг 1.  \r\n\r\nШаг 2.\r\n\r\n---\r\n# Второй\r\n\r\nТекст\r\n';
    final blocks = parseMarkdown(text);
    expect(blocks, hasLength(2));
    expect(blocks[0].title, 'Заказ');
    expect(blocks[0].description, 'Описание');
    expect(blocks[0].content, '\r\nШаг 1.  \r\n\r\nШаг 2.\r\n\r\n');
    expect(
      blocks[0].source,
      '# Заказ\r\n### Описание\r\n\r\nШаг 1.  \r\n\r\nШаг 2.\r\n\r\n',
    );
    expect(blocks[1].content, '\r\nТекст\r\n');
  });

  test(
    'Код, обычные заголовки внутри тела и вложенный Markdown не изменяются',
    () {
      const text =
          '# Заголовок\n\nНачало\n### Это уже текст\n```md\n---\n# Код\n```\n- **жирный**\n---\nКонец';
      final blocks = parseMarkdown(text);
      expect(blocks, hasLength(2));
      expect(blocks.first.description, isEmpty);
      expect(
        blocks.first.content,
        '\nНачало\n### Это уже текст\n```md\n---\n# Код\n```\n- **жирный**\n',
      );
      expect(blocks.last.content, 'Конец');
    },
  );

  test(
    'Пустые блоки пропускаются, текст без метаданных сохраняется целиком',
    () {
      expect(parseMarkdown('---\n\n---\n  \r\n'), isEmpty);
      const body = '\n  Текст\r\n\r\n без заголовка  ';
      final block = parseMarkdown(body).single;
      expect(block.title, isEmpty);
      expect(block.content, body);
      expect(block.source, body);
    },
  );

  test('Длинные заголовки и описания не обрезаются при разборе', () {
    final title = 'Заголовок ' * 100;
    final description = 'Описание ' * 100;
    final block = parseMarkdown('# $title\n### $description\n\nТело').single;
    expect(block.title, title);
    expect(block.description, description);
  });

  test('UTF-8 BOM и UTF-16 LE/BE читаются без потерь', () {
    const text = '# Привет\r\n\r\nТекст 😀';
    final utf8Bytes = Uint8List.fromList([
      0xef,
      0xbb,
      0xbf,
      ...utf8.encode(text),
    ]);
    expect(decodeMarkdown(utf8Bytes), '\uFEFF$text');
    for (final endian in [Endian.little, Endian.big]) {
      final bytes = ByteData(2 + text.codeUnits.length * 2);
      bytes.setUint16(0, 0xfeff, endian);
      for (var i = 0; i < text.codeUnits.length; i++) {
        bytes.setUint16(2 + i * 2, text.codeUnits[i], endian);
      }
      expect(decodeMarkdown(bytes.buffer.asUint8List()), '\uFEFF$text');
    }
    expect(
      () => decodeMarkdown(Uint8List.fromList([0xff, 0xfe, 0])),
      throwsFormatException,
    );
    expect(
      () => decodeMarkdown(Uint8List.fromList([0xff, 0xff])),
      throwsFormatException,
    );
  });

  test('Настоящий файл импортируется с исходными байтами и именем', () async {
    final directory = await Directory.systemTemp.createTemp('helper_parser_');
    try {
      final file = File('${directory.path}/Пример.MD');
      final bytes = [
        0xef,
        0xbb,
        0xbf,
        ...utf8.encode('# Название\n\n**Текст**\n'),
      ];
      await file.writeAsBytes(bytes);
      final document = await readMarkdownFile(file.path);
      expect(document.filename, 'Пример.MD');
      expect(document.bytes, bytes);
      expect(document.text, '\uFEFF# Название\n\n**Текст**\n');
      expect(document.blocks.single.title, 'Название');
      expect(document.blocks.single.content, '\n**Текст**\n');
      final invalid = File('${directory.path}/неверный.csv');
      await invalid.writeAsString('Текст');
      await expectLater(readMarkdownFile(invalid.path), throwsFormatException);
    } finally {
      await directory.delete(recursive: true);
    }
  });
}
