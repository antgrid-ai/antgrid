import 'dart:async';

import 'package:uuid/uuid.dart';

import '../models/ab_message.dart';
import '../models/memory.dart';
import '../project/project_session.dart';

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
