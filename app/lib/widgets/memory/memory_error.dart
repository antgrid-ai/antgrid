import 'dart:async';

import 'package:antgrid_relay_client/antgrid_relay_client.dart'
    show RpcException;

import '../../launcher/host_control_client.dart';
import '../../models/memory.dart';
import '../../services/pending_reply.dart';
import '../ab_status_helpers.dart';

String memoryErrorCode(Object error) => switch (error) {
  MemoryException error => error.code,
  RpcException error => error.code,
  HostControlException error => error.code,
  _ => '',
};

/// Never shows a [MemoryException] message: the backend words it with
/// "record", "revision" and "operation key", none of which the app uses. Every
/// code maps to app copy instead.
String memoryErrorCopy(Object error, {bool mutation = false}) {
  final code = memoryErrorCode(error);
  if (code == 'UNKNOWN_OUTCOME' ||
      (mutation &&
          (error is TimeoutException ||
              error is SessionDownException ||
              code == 'TIMEOUT' ||
              code == 'TRANSPORT' ||
              code == 'TRANSPORT_ERROR'))) {
    return 'Outcome unknown. The change may have been saved. Reconnect and check the memory before trying again.';
  }
  if (code.contains('CONFLICT')) {
    return 'Someone edited this memory first. Open its latest version before editing again.';
  }
  switch (code) {
    case 'CLEANUP_FAILED':
      return "Cleanup failed. Forgotten memories are hidden, but cleanup didn't finish.";
    case 'EXPORT_CHANGED':
      return 'Memory changed during export. Start the export again to save a consistent copy.';
    case 'SEARCH_UNAVAILABLE':
      return "Search is off until it's rebuilt.";
    case 'FORGOTTEN':
      return 'This memory was forgotten.';
    case 'NOT_FOUND':
      return 'This memory no longer exists.';
    case 'INVALID_ARGUMENT':
      return mutation
          ? 'This memory is too long to save. Shorten it or remove a source, then try again.'
          : "This machine's Antgrid didn't understand the request. Update Antgrid on both devices and try again.";
    case 'BUSY':
      return 'Memory is busy. Try again in a moment.';
    case 'UNAVAILABLE':
      return "Memory storage couldn't be opened. Saved memories stay on disk.";
    case 'NOT_CONNECTED':
      return "This machine isn't connected. Connect it to see its memories.";
    case 'NO_MACHINE':
      return 'Open Memory from a connected machine.';
    case 'DEMO':
      return 'Memory is unavailable in the sample project.';
    case 'DISABLED':
      return 'Memory is off on this machine.';
    case 'FORBIDDEN':
      return "This device isn't allowed to do that on this machine.";
  }
  if (error is MemoryException) {
    return 'Something went wrong with Memory. Try again.';
  }
  return caughtErrorCopy(error, 'Memory request failed. Try again.');
}
