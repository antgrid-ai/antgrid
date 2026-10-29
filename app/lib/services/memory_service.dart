import 'dart:convert';
import 'dart:typed_data';

import '../models/memory.dart';

const _indent = JsonEncoder.withIndent('  ');

/// The version-1 export file as UTF-8, laid out as
/// `JsonEncoder.withIndent('  ')` would lay out the whole document.
///
/// Each page is encoded as it arrives and dropped, so the record maps, the
/// full text and a second byte copy never coexist.
Future<Uint8List?> collectMemoryExport(
  Future<Map<String, dynamic>> Function(Map<String, dynamic>) request, {
  bool Function()? isActive,
  String? projectId,
}) async {
  final out = BytesBuilder(copy: false);
  var written = 0;
  final seenCursors = <String>{};
  final seenRecords = <String>{};
  MemoryExportPage? first;
  String? cursor;
  while (true) {
    if (isActive?.call() == false) return null;
    final response = await request({
      'op': 'export',
      'cursor': ?cursor,
      'project_id': ?projectId,
    });
    if (isActive?.call() == false) return null;
    final page = MemoryExportPage.fromJson(response);
    if (first == null) {
      out.add(
        utf8.encode(
          '{\n  "version": 1,\n  "owner_id": ${jsonEncode(page.ownerId)},\n'
          '  "exported_at": ${page.exportedAt},\n  "records": [',
        ),
      );
    }
    first ??= page;
    if (page.ownerId != first.ownerId || page.exportedAt != first.exportedAt) {
      throw const MemoryException(
        'EXPORT_CHANGED',
        'Memory changed during export. Start the export again.',
      );
    }
    for (final record in page.records) {
      if (!seenRecords.add(record['id'] as String)) {
        throw const MemoryException(
          'BAD_RESPONSE',
          'Memory export repeated a record. Start the export again.',
        );
      }
      out.add(
        utf8.encode(
          '${written++ == 0 ? '\n' : ',\n'}    '
          '${_indent.convert(record).replaceAll('\n', '\n    ')}',
        ),
      );
    }
    cursor = page.nextCursor;
    if (cursor == null) {
      out.add(utf8.encode(written == 0 ? ']\n}' : '\n  ]\n}'));
      return out.takeBytes();
    }
    if (!seenCursors.add(cursor)) {
      throw const MemoryException(
        'BAD_RESPONSE',
        'Memory export repeated a page. Start the export again.',
      );
    }
  }
}
