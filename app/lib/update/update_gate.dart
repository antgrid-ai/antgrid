import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../config/build_info.dart';
import '../design/ab_icons.dart';
import '../design/widgets/ab_toast.dart';
import '../providers/update_available.dart';
import '../util/detached.dart';
import 'update_install_controller.dart';
import 'update_strategy.dart';
import 'update_check_controller.dart';
import 'update_check_result.dart';

/// The version this launch replaced, or null when nothing was replaced.
///
/// Overridden from `main()` out of [UpdateHandoffStore], so an ordinary launch
/// — and every test — sees null and the app says nothing. Deliberately NOT
/// derived from the `--after-update` command line `RegisterApplicationRestart`
/// registers in app/windows/runner/main.cpp: Windows hands that argument back
/// after a crash and a hang too, and macOS's Sparkle relaunch passes no
/// argument at all.
final afterUpdateLaunchProvider = Provider<String?>((ref) => null);

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
/// check. Mounted as the MaterialApp's home rather than above it so it sits
/// under the app's [AbToastHost]: [showAbToastOverlay] is a no-op outside one.
class UpdateGate extends ConsumerStatefulWidget {
  const UpdateGate({super.key, required this.child});

  final Widget child;

  @override
  ConsumerState<UpdateGate> createState() => _UpdateGateState();
}

class _UpdateGateState extends ConsumerState<UpdateGate>
    with WidgetsBindingObserver {
  UpdateStrategy? _strategy;

  @override
  void initState() {
    super.initState();
    // Ahead of the strategy gate below: Windows relaunches a build whose
    // update checks are inactive just the same.
    final replaced = ref.read(afterUpdateLaunchProvider);
    if (replaced != null) {
      WidgetsBinding.instance.addPostFrameCallback(
        (_) => _announceUpdated(replaced),
      );
    }
    final strategy = ref.read(updateStrategyProvider);
    if (strategy == null || !strategy.active) return;
    _strategy = strategy;
    WidgetsBinding.instance.addObserver(this);
    WidgetsBinding.instance.addPostFrameCallback((_) => _requestCheck());
  }

  @override
  void dispose() {
    if (_strategy != null) WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) _requestCheck();
  }

  void _requestCheck() =>
      detached('UpdateGate', 'automatic check', _maybeCheck);

  Future<void> _maybeCheck() async {
    if (!mounted || _strategy == null) return;
    final rowAlreadyLit = ref.read(updateAvailableProvider);
    final outcome = await ref
        .read(updateCheckControllerProvider.notifier)
        .checkAutomatically();
    if (!mounted) return;
    if (ref
        .read(updateCheckControllerProvider.notifier)
        .automaticResultSuppressed) {
      return;
    }
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
        // Quiet means "don't ask", not "don't drain": the strategy already
        // decided this one installs itself, so run it through the same
        // sequence as a tap, minus the dialog. Anything else would hand a
        // live bridge to an MSIX replacement.
        _startInstall(confirm: false);
      case UpdateCheckOutcome.startDownloadQuiet:
        final container = ref.container;
        await container
            .read(updateInstallControllerProvider.notifier)
            .start(context, confirm: false);
        if (!mounted) return;
        final checker = container.read(updateCheckControllerProvider.notifier);
        if (!checker.automaticResultSuppressed &&
            !rowAlreadyLit &&
            container.read(updateCheckControllerProvider).result?.status ==
                UpdateCheckStatus.restartReady) {
          _showRestartPrompt();
        }
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
        onAction: () => _startInstall(),
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
        onAction: () => _startInstall(),
      ),
    );
  }

  /// Both toast actions and the drawer row run the one install sequence, so a
  /// toast tapped while the row's attempt is still on screen is refused rather
  /// than starting a second one.
  ///
  /// This state's context outlives both toasts (and the drawer), which matters
  /// on Windows: the sequence drains the bridge host before handing over, and
  /// a context that dies in that window abandons an install the user already
  /// confirmed.
  void _startInstall({bool confirm = true}) {
    detached('UpdateGate', 'install sequence', () async {
      if (!mounted) return;
      await ref
          .read(updateInstallControllerProvider.notifier)
          .start(context, confirm: confirm);
    });
  }

  /// One-shot: the mark behind [replaced] is consumed in `main()`, so it
  /// cannot survive into the next launch.
  void _announceUpdated(String replaced) {
    if (!mounted) return;
    final version = BuildInfo.version;
    // The note is the strategy's because the cost is per-platform: Windows and
    // macOS quit to install, Linux only opened a download page. Read off the
    // provider rather than `_strategy`, which is null in a build whose checks
    // are inactive — the announcement still fires there.
    final note = ref.read(updateStrategyProvider)?.updatedNote;
    showAbToastOverlay(
      context,
      duration: const Duration(seconds: 8),
      toast: AbToast(
        icon: AbIcons.check,
        // Not "and reopened your sessions": nothing restores what the bridge
        // host was running.
        title: version == 'dev' ? 'Update installed' : 'Updated to $version',
        description: note == null
            ? 'Replaced $replaced.'
            : 'Replaced $replaced. $note',
      ),
    );
  }

  @override
  Widget build(BuildContext context) => widget.child;
}
