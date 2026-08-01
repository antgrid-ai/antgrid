import 'dart:developer' as developer;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../analytics/events.dart';
import '../design/widgets/ab_snack_bar.dart';
import '../dialogs/remote_upgrade_dialog.dart';
import '../models/qr_payload.dart';
import '../providers/analytics.dart';
import '../providers/auth.dart';
import '../providers/providers.dart';
import '../screens/scanner_screen.dart';
import '../screens/upgrade_screen.dart';
import '../services/app_settings_service.dart';

/// Shared remote scan + connect-by-URI flow, consumed by [ConnectDialog].
///
/// The remote-access panel deliberately has no scan entry: QR pairing is hidden
/// for the initial release, and an account device admits itself on first
/// connect without one.
///
/// This is the single source of truth for the coordinate-import handoff so
/// consumers cannot drift: ScannerScreen push → [QrPayload.parse] with the
/// default relay URL → `pairedAgentProvider.notifier.importCoordinates`.
/// On success the current route is popped; failures surface as a snackbar.
///
/// Mix into a [ConsumerState]. UI (copy, layout, which widgets host the scan
/// button / URI field) stays with each consumer — only the flow is shared.
mixin RemoteConnectActions<T extends ConsumerStatefulWidget>
    on ConsumerState<T> {
  /// Imports [qr]'s coordinates; pops the current route on success, shows a
  /// snackbar on failure.
  Future<void> runConnect(QrPayload qr) async {
    try {
      final user = await ref.read(currentUserProvider.future);
      if (requiresProForRemote(user?.tier)) {
        if (!mounted) return;
        ref.read(analyticsServiceProvider)?.track(AnalyticsEvents.upgradeDialogShown, props: {'context': 'mobile_gate'});
        final upgrade = await showRemoteUpgradeDialog(context);
        if (upgrade && mounted) {
          await openUpgrade(context, ref.container);
        }
        return;
      }
      await ref.read(pairedAgentProvider.notifier).importCoordinates(qr);
      if (!mounted) return;
      ref.read(analyticsServiceProvider)?.track(AnalyticsEvents.agentPaired, props: {'method': 'qr'});
      Navigator.of(context).pop();
    } catch (e, st) {
      developer.log(
        'connect failed (relay ${qr.relayUrl})',
        name: 'antgrid.connect',
        error: e,
        stackTrace: st,
      );
      if (!mounted) return;
      showAbSnackBar(
        context,
        'Connect failed: $e',
        duration: const Duration(seconds: 8),
      );
    }
  }

  /// Opens the QR scanner; if a payload is returned, connects with it.
  Future<void> scanAndConnect() async {
    final qr = await Navigator.of(
      context,
    ).push<QrPayload>(MaterialPageRoute(builder: (_) => const ScannerScreen()));
    if (qr == null) return;
    await runConnect(qr);
  }

  /// Parses [text] as a connect URI, resolving relative payloads against the
  /// configured default relay URL. Returns `null` when [text] is not a valid
  /// Antgrid connect link.
  ///
  /// Single source of truth for the parse rule so every consumer (the
  /// connect-by-link submit below, and any in-dialog live validation) resolves
  /// the relay the same way and cannot drift.
  QrPayload? parseConnectUri(String text) {
    final defaultRelay = ref.read(appSettingsServiceProvider).defaultRelayUrl;
    return QrPayload.parse(text.trim(), defaultRelayUrl: defaultRelay);
  }

  /// Parses [controller]'s text as a connect URI and connects. Clears the
  /// field on success; shows a snackbar if the URI is invalid.
  void submitConnectUri(TextEditingController controller) {
    final parsed = parseConnectUri(controller.text);
    if (parsed == null) {
      showAbSnackBar(context, 'Invalid Antgrid connect URI');
      return;
    }
    controller.clear();
    runConnect(parsed);
  }
}
