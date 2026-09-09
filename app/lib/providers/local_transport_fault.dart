import 'package:flutter_riverpod/flutter_riverpod.dart';

/// A local project's [LocalTransport] tore down its socket after the
/// handshake had already completed — see `LocalTransport.lastCloseCode` and
/// its `onDone` teardown. Unlike a pre-ready refusal
/// (`LocalTransportHandshakeException`), which the transport family's own
/// `AsyncError` already carries, this fires from a live, working session and
/// has nowhere else to surface: `stateChanges` has no other subscriber, so
/// without this the workspace just sits on a dead transport until every
/// in-flight reply times out.
///
/// [toString] is what the blocking error screen renders verbatim
/// (`_LocalLaunchErrorScreen` interpolates the error object into a
/// `SelectableText`), so it must read as a sentence on its own.
class LocalTransportFault {
  const LocalTransportFault({required this.closeCode, required this.message});

  final int? closeCode;
  final String message;

  @override
  String toString() => message;
}

class LocalTransportFaultController extends Notifier<LocalTransportFault?> {
  // The family arg (projectId) is what keys this instance; the controller
  // itself has no need to read it back.
  LocalTransportFaultController(String projectId);

  @override
  LocalTransportFault? build() => null;

  void set(LocalTransportFault fault) => state = fault;

  /// Called by Retry before it invalidates the transport/session providers —
  /// otherwise the rebuilt workspace would still read this stale fault and
  /// stay on the blocking error screen even after a fresh transport connects.
  void clear() => state = null;
}

final localTransportFaultProvider =
    NotifierProvider.family<
      LocalTransportFaultController,
      LocalTransportFault?,
      String
    >(LocalTransportFaultController.new);
