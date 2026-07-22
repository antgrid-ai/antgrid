import 'dart:developer' as developer;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../analytics/events.dart';
import '../design/widgets/ab_snack_bar.dart';
import '../dialogs/mobile_upgrade_dialog.dart';
import '../models/qr_payload.dart';
import '../providers/analytics.dart';
import '../providers/auth.dart';
import '../providers/providers.dart';
import '../screens/scanner_screen.dart';
import '../screens/upgrade_screen.dart';
import '../services/app_settings_service.dart';

/// Shared remote scan + pair / connect-by-URI flow, consumed by both
/// [PairDialog] and the Add-project sheet's Remote tab.
///
/// This is the single source of truth for the relay-pairing handoff so the
/// two entry points cannot drift: ScannerScreen push → [QrPayload.parse] with
/// the default relay URL → `pairedAgentProvider.notifier.pair`. On a
/// successful pair the current route is popped; failures surface as a
/// snackbar.
///
/// Mix into a [ConsumerState]. UI (copy, layout, which widgets host the scan
/// button / URI field) stays with each consumer — only the flow is shared.
mixin RemotePairActions<T extends ConsumerStatefulWidget> on ConsumerState<T> {
  /// Pairs with [qr]; pops the current route on success, shows a snackbar on
  /// failure.
  Future<void> runPair(QrPayload qr) async {
    try {
      final user = await ref.read(currentUserProvider.future);
      if (requiresProForMobile(user?.tier)) {
        if (!mounted) return;
        ref.read(analyticsServiceProvider)?.track(AnalyticsEvents.upgradeDialogShown, props: {'context': 'mobile_gate'});
        final upgrade = await showMobileUpgradeDialog(context);
        if (upgrade && mounted) {
          await openUpgrade(context, ref);
        }
        return;
      }
      await ref.read(pairedAgentProvider.notifier).pair(qr);
      if (!mounted) return;
      ref.read(analyticsServiceProvider)?.track(AnalyticsEvents.agentPaired, props: {'method': 'qr'});
      Navigator.of(context).pop();
    } catch (e, st) {
      developer.log(
        'pair failed (relay ${qr.relayUrl})',
        name: 'antgrid.pairing',
        error: e,
        stackTrace: st,
      );
      if (!mounted) return;
      showAbSnackBar(
        context,
        'Pairing failed: $e',
        duration: const Duration(seconds: 8),
      );
    }
  }

  /// Opens the QR scanner; if a payload is returned, pairs with it.
  Future<void> scanAndPair() async {
    final qr = await Navigator.of(
      context,
    ).push<QrPayload>(MaterialPageRoute(builder: (_) => const ScannerScreen()));
    if (qr == null) return;
    await runPair(qr);
  }

  /// Parses [text] as a pairing URI, resolving relative payloads against the
  /// configured default relay URL. Returns `null` when [text] is not a valid
  /// Antgrid pairing link.
  ///
  /// Single source of truth for the parse rule so every consumer (the
  /// connect-by-link submit below, and any in-dialog live validation) resolves
  /// the relay the same way and cannot drift.
  QrPayload? parsePairUri(String text) {
    final defaultRelay = ref.read(appSettingsServiceProvider).defaultRelayUrl;
    return QrPayload.parse(text.trim(), defaultRelayUrl: defaultRelay);
  }

  /// Parses [controller]'s text as a pairing URI and pairs. Clears the field on
  /// success; shows a snackbar if the URI is invalid.
  void submitPairUri(TextEditingController controller) {
    final parsed = parsePairUri(controller.text);
    if (parsed == null) {
      showAbSnackBar(context, 'Invalid Antgrid pairing URI');
      return;
    }
    controller.clear();
    runPair(parsed);
  }
}
