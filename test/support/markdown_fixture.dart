import 'dart:convert';
import 'dart:typed_data';

import 'package:helper/markdown/markdown_parser.dart';
import 'package:helper/markdown/models.dart';

ImportedDocument document(String filename, String text) => ImportedDocument(
  filename: filename,
  text: text,
  bytes: Uint8List.fromList(utf8.encode(text)),
  blocks: parseMarkdown(text),
);
