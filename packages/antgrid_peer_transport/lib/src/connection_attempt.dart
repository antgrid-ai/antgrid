import 'dart:async';

import 'package:antgrid_relay_client/antgrid_relay_client.dart';

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

enum PeerConnectionStage { authorization, initialization, connect }

class PeerConnectionFailure implements Exception {
  const PeerConnectionFailure(
    this.code, {
    required this.terminal,
    this.stage = PeerConnectionStage.connect,
  });
  final String code;
  final PeerConnectionStage stage;
  bool get cancelled => code == 'SUPERSEDED';
  bool get retryable => !terminal && !cancelled;
  final bool terminal;

  @override
  String toString() => 'PeerConnectionFailure($code, terminal: $terminal)';
}

/// One native connection attempt; retries belong to ConnectionSupervisor.
class PeerConnectionAttempt {
  int _generation = 0;
  bool _inFlight = false;
  Completer<PeerLink>? _cancelled;
  int get generation => _generation;
  void checkCurrent(int generation) {
    if (generation != _generation) {
      throw const PeerConnectionFailure('SUPERSEDED', terminal: false);
    }
  }
  void cancel() {
    _generation++;
    final pending = _cancelled;
    if (pending != null && !pending.isCompleted) {
      pending.completeError(
        const PeerConnectionFailure('SUPERSEDED', terminal: false),
      );
    }
  }

  Future<PeerLink> connect({
    required Future<PeerLink> Function() iroh,
    Duration budget = const Duration(seconds: 15),
    PeerLinkDiagnostic? diagnostic,
  }) async {
    if (_inFlight) {
      throw const PeerConnectionFailure(
        'NATIVE_CONNECT_PENDING',
        terminal: false,
      );
    }
    cancel();
    _inFlight = true;
    final generation = _generation;
    final cancelled = _cancelled = Completer<PeerLink>();
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
        throw const PeerConnectionFailure('SUPERSEDED', terminal: false);
      }
      return link;
    }

    emit('peer:connection-start', 'iroh');
    var expired = false;
    final native = fenced(iroh)
        .then((link) async {
          if (expired) {
            await link.close();
            throw const PeerConnectionFailure(
              'CONNECTION_TIMEOUT',
              terminal: false,
            );
          }
          return link;
        })
        .whenComplete(() => _inFlight = false);
    try {
      final link = await Future.any([native, cancelled.future]).timeout(
        budget,
        onTimeout: () {
          expired = true;
          emit('peer:connection-timeout', 'iroh', reason: 'CONNECTION_TIMEOUT');
          throw const PeerConnectionFailure(
            'CONNECTION_TIMEOUT',
            terminal: false,
          );
        },
      );
      emit('peer:connection-ready', 'iroh');
      return link;
    } catch (error) {
      emit(
        'peer:connection-failed',
        'iroh',
        reason: generation != _generation ? 'SUPERSEDED' : 'NATIVE_FAILURE',
      );
      rethrow;
    } finally {
      if (identical(_cancelled, cancelled)) _cancelled = null;
    }
  }
}
