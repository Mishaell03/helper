import 'package:flutter/foundation.dart';

/// The source stays intact in SQLite/controller. Only layout is paginated.
const blockDisplayPageSize = 8192;

List<String> splitDisplayPages(String text) {
  if (text.length <= blockDisplayPageSize) return [text];
  final pages = <String>[];
  var start = 0;
  while (start < text.length) {
    var end = (start + blockDisplayPageSize).clamp(0, text.length);
    if (end < text.length) {
      final newline = text.substring(start, end).lastIndexOf('\n');
      if (newline >= blockDisplayPageSize ~/ 2) end = start + newline + 1;
      // Do not cut a UTF-16 surrogate pair or a CRLF across pages.
      final previous = text.codeUnitAt(end - 1);
      if ((previous >= 0xd800 &&
              previous <= 0xdbff &&
              text.codeUnitAt(end) >= 0xdc00 &&
              text.codeUnitAt(end) <= 0xdfff) ||
          (previous == 13 && text.codeUnitAt(end) == 10)) {
        end--;
      }
    }
    pages.add(text.substring(start, end));
    start = end;
  }
  return pages;
}

class BlockDisplay {
  const BlockDisplay(this.content, this.source);
  final List<String> content;
  final List<String> source;
}

BlockDisplay _prepare((String, String) text) =>
    BlockDisplay(splitDisplayPages(text.$1), splitDisplayPages(text.$2));

Future<BlockDisplay> prepareBlockDisplay(String content, String source) async {
  if (content.length <= blockDisplayPageSize &&
      source.length <= blockDisplayPageSize) {
    return BlockDisplay([content], [source]);
  }
  return compute(_prepare, (content, source));
}
