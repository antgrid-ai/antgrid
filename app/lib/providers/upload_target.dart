import 'dart:async';

import 'package:antgrid_relay_client/antgrid_relay_client.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../project/project_session.dart';
import '../project/project_session_registry.dart';
import '../services/upload_service.dart';
import '../utils/platform_utils.dart';

/// Captured before opening an external picker: focus and services can both
/// change while Android owns the screen, but the upload destination cannot.
class UploadTarget {
  const UploadTarget(this.container, this.projectId, this.checkoutId);

  final ProviderContainer container;
  final String projectId;
  final String checkoutId;
  static int _nextWait = 0;

  Future<UploadService> ready({
    Duration timeout = const Duration(seconds: 30),
  }) async {
    final done = Completer<UploadService>();
    StreamSubscription<TransportState>? transportSub;
    ProjectSession? current;
    final hydrateKey = 'upload-ready-${_nextWait++}';
    void check() {
      if (done.isCompleted) return;
      final state = WidgetsBinding.instance.lifecycleState;
      // Only mobile resume fences the lease; desktop focus loss leaves it valid.
      if (isMobilePlatform &&
          (state == AppLifecycleState.paused ||
              state == AppLifecycleState.hidden ||
              state == AppLifecycleState.inactive)) {
        return;
      }
      final session = current;
      if (session != null && session.transport.isEstablished) {
        done.complete(session.servicesForCheckout(checkoutId).uploadService);
      }
    }

    final lifecycle = AppLifecycleListener(
      // Let AppShell fence the old lease before inspecting a picker result.
      onResume: () => scheduleMicrotask(check),
    );
    final sub = container.listen(projectSessionProvider(projectId), (_, next) {
      unawaited(transportSub?.cancel());
      transportSub = null;
      current?.transport.unhydrate(hydrateKey);
      current = next.isLoading ? null : next.value;
      if (next.hasError && !next.isLoading) {
        if (!done.isCompleted) done.completeError(next.error!);
        return;
      }
      transportSub = current?.transport.stateChanges.listen((_) => check());
      final transport = current?.transport;
      if (transport != null) {
        unawaited(
          transport
              .hydrate(hydrateKey, () {
                check();
                return Future<void>.value();
              })
              .catchError((Object error, StackTrace stack) {
                if (!done.isCompleted) done.completeError(error, stack);
              }),
        );
      }
      scheduleMicrotask(check);
    }, fireImmediately: true);
    try {
      return await done.future.timeout(timeout);
    } on TimeoutException {
      throw const UploadException(
        'OFFLINE',
        'Timed out waiting for connection',
      );
    } finally {
      lifecycle.dispose();
      sub.close();
      current?.transport.unhydrate(hydrateKey);
      await transportSub?.cancel();
    }
  }
}
