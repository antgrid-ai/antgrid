import 'dart:async';

import 'package:uuid/uuid.dart';

import '../models/ab_message.dart';
import '../models/memory.dart';
import '../project/project_session.dart';

Future<MemoryExport?> collectMemoryExport(
  Future<Map<String, dynamic>> Function(Map<String, dynamic>) request, {
  bool Function()? isActive,
}) async {
  final records = <Map<String, dynamic>>[];
  final seenCursors = <String>{};
  final seenRecords = <String>{};
  MemoryExportPage? first;
  String? cursor;
  while (true) {
    if (isActive?.call() == false) return null;
    final response = await request({
      'op': 'export',
      'cursor': ?cursor,
    });
    if (isActive?.call() == false) return null;
    final page = MemoryExportPage.fromJson(response);
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
      records.add(record);
    }
    cursor = page.nextCursor;
    if (cursor == null) {
      return MemoryExport(
        ownerId: first.ownerId,
        exportedAt: first.exportedAt,
        records: List.unmodifiable(records),
      );
    }
    if (!seenCursors.add(cursor)) {
      throw const MemoryException(
        'BAD_RESPONSE',
        'Memory export repeated a page. Start the export again.',
      );
    }
  }
}

/// Each request belongs to the admitted project stream, independent of the
/// focused checkout. The bridge derives access from that stream's project.
Future<Map<String, dynamic>> requestProjectMemory(
  ProjectSession session,
  Map<String, dynamic> request, {
  Duration timeout = const Duration(seconds: 15),
}) async {
  final requestId = const Uuid().v4();
  final pending = session.newPending<Map<String, dynamic>>(timeout: timeout);
  final subscription = session.statusStream.listen((frame) {
    if (frame.json['type'] != 'memory:result' ||
        frame.json['requestId'] != requestId) {
      return;
    }
    final response = MemoryResponse.fromJson(frame.json);
    if (response == null) {
      pending.fail(
        const MemoryException('BAD_RESPONSE', 'Malformed memory response.'),
      );
    } else if (response.ok) {
      pending.complete(response.result!);
    } else {
      pending.fail(response.error!);
    }
  });
  // Attach the reply's error handler before sending: a connection can fail
  // synchronously while the send itself is still completing.
  final result = pending.future;
  unawaited(
    session
        .send(
          createAbMessage('memory:request', {
            'requestId': requestId,
            'request': request,
          }),
        )
        .catchError((Object error) => pending.fail(error)),
  );
  try {
    return await result;
  } finally {
    await subscription.cancel();
  }
}
