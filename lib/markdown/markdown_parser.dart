import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:path/path.dart' as path;

import 'models.dart';

/// No normalization or trim is applied to stored source/body strings.
/// Only leading metadata headings are extracted. Headings later in the body
/// and separators inside fenced code are ordinary content.
List<ParsedBlock> parseMarkdown(String text) {
  final result = <ParsedBlock>[];
  var start = 0;
  String? fence;
  var fenceLength = 0;
  final lines = RegExp(r'[^\r\n]*(?:\r\n|\n|\r|$)');
  for (final line in lines.allMatches(text)) {
    if (line.start == line.end) continue;
    final value = line.group(0)!.replaceFirst(RegExp(r'[\r\n]+$'), '');
    final marker = RegExp(r'^ {0,3}(`{3,}|~{3,})(.*)$').firstMatch(value);
    if (marker != null) {
      final marks = marker[1]!;
      if (fence == null) {
        fence = marks[0];
        fenceLength = marks.length;
      } else if (marks[0] == fence &&
          marks.length >= fenceLength &&
          marker[2]!.trim().isEmpty) {
        fence = null;
      }
    }
    if (fence == null && RegExp(r'^---[ \t]*$').hasMatch(value)) {
      _appendBlock(text.substring(start, line.start), result);
      start = line.end;
    }
  }
  _appendBlock(text.substring(start), result);
  return result;
}

void _appendBlock(String source, List<ParsedBlock> blocks) {
  if (source.trim().isEmpty) return;
  var title = '';
  var description = '';
  var bodyStart = 0;
  var hasMetadata = false;
  for (final line in RegExp(r'[^\r\n]*(?:\r\n|\n|\r|$)').allMatches(source)) {
    if (line.start == line.end) break;
    final value = line[0]!.replaceFirst(RegExp(r'[\r\n]+$'), '');
    if (value.trim().isEmpty) continue;
    final heading = RegExp(r'^(#|###)[ \t]+(.*)$').firstMatch(value);
    if (heading == null) break;
    if (heading[1] == '#' && title.isEmpty) {
      title = heading[2]!;
    } else if (heading[1] == '###' && description.isEmpty) {
      description = heading[2]!;
    } else {
      break;
    }
    hasMetadata = true;
    bodyStart = line.end;
  }
  blocks.add(
    ParsedBlock(
      title: title,
      description: description,
      content: hasMetadata ? source.substring(bodyStart) : source,
      source: source,
    ),
  );
}

/// Called in a worker isolate: disk reading, decoding and parsing never run on
/// the Flutter UI isolate. Original bytes (including BOM) are retained too.
Future<ImportedDocument> readMarkdownFile(String filename) async {
  final extension = path.extension(filename).toLowerCase();
  if (extension != '.md' && extension != '.txt') {
    throw const FormatException('Можно импортировать только файлы .md и .txt.');
  }
  final file = File(filename);
  const maximumBytes = 32 * 1024 * 1024;
  if (await file.length() > maximumBytes) {
    throw const FormatException(
      'Файл слишком большой. Максимальный размер — 32 МБ.',
    );
  }
  final bytes = await file.readAsBytes();
  if (bytes.length > maximumBytes) {
    throw const FormatException(
      'Файл слишком большой. Максимальный размер — 32 МБ.',
    );
  }
  final text = decodeMarkdown(bytes);
  // Keep BOM in original text, but do not treat it as part of a heading.
  final parsed = parseMarkdown(
    text.startsWith('\uFEFF') ? text.substring(1) : text,
  );
  if (parsed.isEmpty) {
    throw const FormatException('В файле нет текстовых блоков.');
  }
  return ImportedDocument(
    filename: path.basename(filename),
    bytes: bytes,
    text: text,
    blocks: parsed,
  );
}

String decodeMarkdown(Uint8List bytes) {
  if (bytes.length >= 4 &&
      ((bytes[0] == 0xff &&
              bytes[1] == 0xfe &&
              bytes[2] == 0 &&
              bytes[3] == 0) ||
          (bytes[0] == 0 &&
              bytes[1] == 0 &&
              bytes[2] == 0xfe &&
              bytes[3] == 0xff))) {
    throw const FormatException(
      'Сохраните файл в UTF-8 или UTF-16 с BOM вместо UTF-32.',
    );
  }
  if (bytes.length >= 2 &&
      ((bytes[0] == 0xff && bytes[1] == 0xfe) ||
          (bytes[0] == 0xfe && bytes[1] == 0xff))) {
    if (bytes.length.isOdd) {
      throw const FormatException('Повреждённый текст UTF-16.');
    }
    final endian = bytes[0] == 0xff ? Endian.little : Endian.big;
    final data = ByteData.sublistView(bytes);
    final units = <int>[0xfeff];
    for (var offset = 2; offset < bytes.length; offset += 2) {
      units.add(data.getUint16(offset, endian));
    }
    for (var i = 1; i < units.length; i++) {
      final unit = units[i];
      if (unit >= 0xd800 && unit <= 0xdbff) {
        if (i + 1 == units.length ||
            units[i + 1] < 0xdc00 ||
            units[i + 1] > 0xdfff) {
          throw const FormatException('Повреждённый текст UTF-16.');
        }
        i++;
      } else if (unit >= 0xdc00 && unit <= 0xdfff) {
        throw const FormatException('Повреждённый текст UTF-16.');
      }
    }
    return String.fromCharCodes(units);
  }
  try {
    // Utf8Decoder removes a BOM, so restore it in the archival text column.
    final text = utf8.decode(bytes, allowMalformed: false);
    final bom =
        bytes.length >= 3 &&
        bytes[0] == 0xef &&
        bytes[1] == 0xbb &&
        bytes[2] == 0xbf;
    return bom ? '\uFEFF$text' : text;
  } on FormatException {
    throw const FormatException(
      'Не удалось прочитать кодировку. Сохраните файл в UTF-8 или UTF-16 с BOM.',
    );
  }
}
