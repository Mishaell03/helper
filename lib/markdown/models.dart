import 'dart:typed_data';

class ParsedBlock {
  const ParsedBlock({
    required this.title,
    required this.description,
    required this.content,
    required this.source,
  });

  final String title;
  final String description;
  final String content;
  final String source;
}

class ImportedDocument {
  const ImportedDocument({
    required this.filename,
    required this.bytes,
    required this.text,
    required this.blocks,
  });

  final String filename;
  final Uint8List bytes;
  final String text;
  final List<ParsedBlock> blocks;
}

class BlockSummary {
  BlockSummary.fromRow(Map<String, Object?> row)
    : id = row['id'] as int,
      fileId = row['file_id'] as int,
      position = row['position'] as int,
      pinned = row['pinned'] == 1,
      title = row['title'] as String,
      description = row['description'] as String,
      preview = row['preview'] as String? ?? '';

  final int id;
  final int fileId;
  final int position;
  final bool pinned;
  final String title;
  final String description;
  final String preview;

  String get displayTitle => title.isEmpty ? 'Без заголовка' : title;
}

class ContentBlock extends BlockSummary {
  ContentBlock.fromRow(super.row)
    : content = row['content'] as String,
      source = row['source'] as String,
      super.fromRow();

  final String content;
  final String source;
}

class ImportedFile {
  ImportedFile.fromRow(Map<String, Object?> row)
    : id = row['id'] as int,
      filename = row['filename'] as String,
      importedAt = DateTime.fromMillisecondsSinceEpoch(
        row['imported_at'] as int,
        isUtc: true,
      ),
      originalBlockCount = row['block_count'] as int,
      remainingBlockCount = row['remaining_count'] as int;

  final int id;
  final String filename;
  final DateTime importedAt;
  final int originalBlockCount;
  final int remainingBlockCount;
}
