import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../design/ab_icons.dart';
import '../design/widgets/ab_toast.dart';
import '../providers/update_available.dart';
import 'update_strategy.dart';

/// Root wrapper that drives in-app updates via the running platform's
/// [UpdateStrategy] — the single per-platform table in update_strategy.dart.
///
/// Checks for an update once after the first frame and again whenever the
/// app resumes, throttled so rapid background/foreground cycling doesn't
/// hammer the update source. Platforms without an active strategy get an
/// inert pass-through — no observer, no checks. An update-available outcome
/// lights [updateAvailableProvider], which the drawer's `UpdateRow` renders
/// as a persistent affordance, and is announced with a one-time toast — on
/// phones the drawer is a slide-in, so the row alone is invisible until the
/// user happens to open it. A restart-ready outcome (Android) surfaces as a
/// toast AND lights the row: the toast times out, and a missed one must not
/// leave the downloaded update affordance-less until the next throttled
/// check. Toasts mount below the MaterialApp `Overlay` for
/// [showAbToastOverlay].
class UpdateGate extends ConsumerStatefulWidget {
  const UpdateGate({super.key, required this.child});

  final Widget child;

  @override
  ConsumerState<UpdateGate> createState() => _UpdateGateState();
}

class _UpdateGateState extends ConsumerState<UpdateGate>
    with WidgetsBindingObserver {
  static const _throttle = Duration(minutes: 30);

  /// The platform's strategy when this build actively checks, null for both
  /// disabled states (no strategy for the platform, or an inactive dev
  /// build) — `active` is immutable per-process, so collapsing them here
  /// leaves one question everywhere below. Resolved once in initState: the
  /// provider is a root singleton, and a field keeps dispose() off `ref`,
  /// which throws once the state is disposed.
  UpdateStrategy? _strategy;

  DateTime? _lastCheck;

  @override
  void initState() {
    super.initState();
    final strategy = ref.read(updateStrategyProvider);
    if (strategy == null || !strategy.active) return;
    _strategy = strategy;
    unawaited(strategy.prepare());
    WidgetsBinding.instance.addObserver(this);
    WidgetsBinding.instance.addPostFrameCallback((_) => _maybeCheck());
  }

  @override
  void dispose() {
    if (_strategy != null) WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) _maybeCheck();
  }

  Future<void> _maybeCheck() async {
    // The post-frame callback from initState can fire after a same-frame
    // dispose; `ref` throws on a disposed ConsumerState.
    if (!mounted) return;
    final strategy = _strategy;
    if (strategy == null) return;
    final now = DateTime.now();
    final last = _lastCheck;
    if (last != null && now.difference(last) < _throttle) return;
    _lastCheck = now;

    final rowAlreadyLit = ref.read(updateAvailableProvider);
    final outcome = await strategy.check(rowAlreadyLit: rowAlreadyLit);
    if (!mounted) return;
    switch (outcome) {
      case UpdateCheckOutcome.none:
        break;
      case UpdateCheckOutcome.updateAvailable:
        ref.read(updateAvailableProvider.notifier).set(true);
        // Announce only the false→true transition (Windows' optional tier
        // keeps returning updateAvailable while lit); after that the latched
        // row is the durable affordance.
        if (!rowAlreadyLit) _showUpdateAvailablePrompt();
      case UpdateCheckOutcome.updateAvailableQuiet:
        ref.read(updateAvailableProvider.notifier).set(true);
      case UpdateCheckOutcome.restartReady:
        ref.read(updateAvailableProvider.notifier).set(true);
        // Same false→true rule as above: Play keeps reporting a downloaded
        // flexible update until the user actually restarts, so an unguarded
        // prompt re-appears on every throttled resume for the rest of the
        // process. The latched row carries the same 'Restart' action.
        if (!rowAlreadyLit) _showRestartPrompt();
    }
  }

  void _showUpdateAvailablePrompt() {
    showAbToastOverlay(
      context,
      duration: const Duration(seconds: 10),
      toast: AbToast(
        icon: AbIcons.arrowDown,
        title: 'Update available',
        description: 'A new version is available to install.',
        actionLabel: 'Update',
        onAction: () => _strategy?.install(context),
      ),
    );
  }

  void _showRestartPrompt() {
    showAbToastOverlay(
      context,
      duration: const Duration(seconds: 30),
      toast: AbToast(
        icon: AbIcons.arrowDown,
        title: 'Update ready',
        description: 'A new version has been downloaded.',
        actionLabel: 'Restart',
        // install == "user accepted the update" on every platform; for the
        // Play strategy that is completeFlexibleUpdate.
        onAction: () => _strategy?.install(context),
      ),
    );
  }

  @override
  Widget build(BuildContext context) => widget.child;
}
