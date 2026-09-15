import 'dart:async';

import 'package:antgrid_relay_client/antgrid_relay_client.dart';

enum PeerTransportMode { websocket, irohPreferred, irohOnly }

void emitPeerLifecycle(
  PeerLinkDiagnostic? diagnostic,
  String stage, {
  required String transport,
  required int elapsedMs,
  int? generation,
  String? reason,
}) {
  try {
    diagnostic?.call({
      'op': 'lifecycle',
      'dir': 'event',
      'kind': 'lifecycle',
      'transport': transport,
      'msgType': stage,
      'detail': {
        'elapsedMs': elapsedMs,
        if (generation != null) 'generation': generation,
        if (reason != null) 'reason': reason,
      },
    });
  } catch (_) {
    // Observability cannot change transport selection or admission.
  }
}

class PeerSelectionFailure implements Exception {
  const PeerSelectionFailure(this.code, {required this.terminal});
  final String code;
  final bool terminal;

  @override
  String toString() => 'PeerSelectionFailure($code, terminal: $terminal)';
}

/// One selection attempt; retries belong to ConnectionSupervisor.
class PeerLinkSelector {
  int _generation = 0;
  void cancel() {
    _generation++;
  }

  Future<PeerLink> select({
    required PeerTransportMode mode,
    required Future<PeerLink> Function() websocket,
    required Future<PeerLink> Function() iroh,
    Duration budget = const Duration(seconds: 5),
    PeerLinkDiagnostic? diagnostic,
  }) async {
    final generation = ++_generation;
    final timer = Stopwatch()..start();
    void emit(String stage, String transport, {String? reason}) =>
        emitPeerLifecycle(
          diagnostic,
          stage,
          transport: transport,
          elapsedMs: timer.elapsedMilliseconds,
          generation: generation,
          reason: reason,
        );
    Future<PeerLink> fenced(Future<PeerLink> Function() factory) async {
      final link = await factory();
      if (generation != _generation) {
        await link.close();
        throw const PeerSelectionFailure('SUPERSEDED', terminal: true);
      }
      return link;
    }

    emit(
      'peer:selection-start',
      mode == PeerTransportMode.websocket ? 'relay' : 'iroh',
    );
    if (mode == PeerTransportMode.websocket) {
      final link = await fenced(websocket);
      emit('peer:transport-selected', 'relay');
      return link;
    }
    var expired = false;
    final native = fenced(iroh).then((link) async {
      if (expired) {
        await link.close();
        throw const PeerSelectionFailure('SELECTION_TIMEOUT', terminal: false);
      }
      return link;
    });
    try {
      final link = await native.timeout(
        budget,
        onTimeout: () {
          expired = true;
          emit('peer:selection-timeout', 'iroh', reason: 'SELECTION_TIMEOUT');
          throw const PeerSelectionFailure(
            'SELECTION_TIMEOUT',
            terminal: false,
          );
        },
      );
      emit('peer:transport-selected', 'iroh');
      return link;
    } catch (error) {
      if (generation != _generation ||
          mode == PeerTransportMode.irohOnly ||
          error is! PeerSelectionFailure ||
          error.terminal) {
        emit(
          'peer:selection-rejected',
          'iroh',
          reason: generation != _generation
              ? 'SUPERSEDED'
              : 'TERMINAL_OR_UNCLASSIFIED',
        );
        rethrow;
      }
      final reason = switch (error.code) {
        'LEGACY_PEER' => 'LEGACY_PEER',
        'SELECTION_TIMEOUT' => 'SELECTION_TIMEOUT',
        _ => 'TRANSIENT_NATIVE_FAILURE',
      };
      emit('peer:fallback', 'relay', reason: reason);
      final link = await fenced(websocket);
      emit('peer:transport-selected', 'relay');
      return link;
    }
  }
}
