import 'dart:async';

import 'package:antgrid_relay_client/antgrid_relay_client.dart'
    show RpcException;

import '../../launcher/host_control_client.dart';
import '../../models/memory.dart';
import '../../services/pending_reply.dart';

String memoryErrorCode(Object error) => switch (error) {
  MemoryException error => error.code,
  RpcException error => error.code,
  HostControlException error => error.code,
  _ => '',
};

String memoryErrorCopy(Object error, {bool mutation = false}) {
  final (code, message) = switch (error) {
    MemoryException error => (error.code, error.message),
    RpcException error => (error.code, error.message),
    HostControlException error => (error.code, error.message),
    _ => ('', '$error'),
  };
  if (code == 'UNKNOWN_OUTCOME' ||
      (mutation &&
          (error is TimeoutException ||
              error is SessionDownException ||
              code == 'TIMEOUT' ||
              code == 'TRANSPORT' ||
              code == 'TRANSPORT_ERROR'))) {
    return 'Outcome unknown. The operation may have committed. Reconnect and inspect the record before retrying.';
  }
  if (code.contains('CONFLICT')) {
    return 'Correction conflict. Inspect the latest record before saving again. $message';
  }
  if (code == 'CLEANUP_FAILED') {
    return 'Cleanup failed. Forgotten content is hidden, but cleanup has not completed. $message';
  }
  return message;
}
