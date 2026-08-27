import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../design/ab_colors.dart';
import '../design/ab_icons.dart';
import '../design/widgets/ab_confirm_dialog.dart';
import '../design/widgets/ab_toast.dart';
import '../project/project_session_registry.dart';
import '../providers/control_plane.dart' show hostControllerProvider;
import '../util/ab_log.dart';
import 'update_strategy.dart';

/// Where the install sequence has got to. Carries value equality so a
/// re-derived state doesn't rebuild the affordance that shows it.
sealed class UpdateInstallState {
  const UpdateInstallState();
}

final class UpdateInstallIdle extends UpdateInstallState {
  const UpdateInstallIdle();

  @override
  bool operator ==(Object other) => other is UpdateInstallIdle;

  @override
  int get hashCode => (UpdateInstallIdle).hashCode;

  @override
  String toString() => 'UpdateInstallIdle()';
}

/// The confirm dialog is on screen.
final class UpdateInstallConfirming extends UpdateInstallState {
  const UpdateInstallConfirming();

  @override
  bool operator ==(Object other) => other is UpdateInstallConfirming;

  @override
  int get hashCode => (UpdateInstallConfirming).hashCode;

  @override
  String toString() => 'UpdateInstallConfirming()';
}

/// Confirmed and under way: draining, then whatever the platform does.
///
/// [percent] is whole-percent download progress where the platform reports it.
/// It sits at 0 for as long as nothing has ticked — the Store's pre-install
/// re-scan and both of its consent dialogs come before the first byte — and
/// the platform emits no terminal 100, so it is a hint, not a completion
/// signal.
final class UpdateInstallWorking extends UpdateInstallState {
  const UpdateInstallWorking(this.percent);

  final int percent;

  @override
  bool operator ==(Object other) =>
      other is UpdateInstallWorking && other.percent == percent;

  @override
  int get hashCode => Object.hash(UpdateInstallWorking, percent);

  @override
  String toString() => 'UpdateInstallWorking($percent)';
}

/// The platform took the update. On Windows the process is already going away.
final class UpdateInstallDone extends UpdateInstallState {
  const UpdateInstallDone();

  @override
  bool operator ==(Object other) => other is UpdateInstallDone;

  @override
  int get hashCode => (UpdateInstallDone).hashCode;

  @override
  String toString() => 'UpdateInstallDone()';
}

/// Nothing was installed. The update is still pending and the affordance is
/// live again — [reason] is for logs and diagnostics, not for the user, who
/// was told in a toast.
final class UpdateInstallFailed extends UpdateInstallState {
  const UpdateInstallFailed(this.reason);

  final UpdateInstallResult reason;

  @override
  bool operator ==(Object other) =>
      other is UpdateInstallFailed && other.reason == reason;

  @override
  int get hashCode => Object.hash(UpdateInstallFailed, reason);

  @override
  String toString() => 'UpdateInstallFailed(${reason.name})';
}

/// Drives the whole "install this update" sequence for every entry point that
/// offers one — the drawer row and both update toasts — so the confirmation,
/// the drain and the outcome cannot drift apart between them.
///
/// The sequence exists because of what a Windows Store install costs: the
/// Store replaces an MSIX only over a dead process, so accepting ends the app
/// and takes every running agent with it. Two things follow. The confirm
/// dialog states that before the Store's own consent dialogs appear, when it
/// is still the user's decision. And the drain is ours to do: the engine's
/// `didRequestAppExit` never fires on Windows (the process carries a second
/// top-level window, so WM_CLOSE is never the last one), leaving
/// `HostTeardownObserver` unreachable and the bridge to be killed by the job
/// object rather than shut down.
///
/// Platform-agnostic: [UpdateStrategy.installEndsSession] is what asks for the
/// confirm and the drain, so a platform whose install merely opens a page or a
/// dialog still goes straight through, exactly as before.
class UpdateInstallController extends Notifier<UpdateInstallState> {
  StreamSubscription<int>? _progress;
  bool _disposed = false;

  @override
  UpdateInstallState build() {
    ref.onDispose(() {
      _disposed = true;
      _cancelProgress();
    });
    return const UpdateInstallIdle();
  }

  /// Runs confirm → drain → install. Never throws, and surfaces its own UI.
  ///
  /// A second call while a sequence is on screen or under way is dropped: the
  /// Store's pre-install re-scan alone is several seconds during which the
  /// only honest thing to do is nothing, and that is long enough for an
  /// impatient second tap to start a second install.
  Future<void> start(BuildContext context) async {
    if (state is UpdateInstallConfirming || state is UpdateInstallWorking) {
      return;
    }
    final strategy = ref.read(updateStrategyProvider);
    if (strategy == null) return;

    final endsSession = strategy.installEndsSession;
    if (endsSession) {
      _set(const UpdateInstallConfirming());
      final confirmed = await AbConfirmDialog.show(
        context: context,
        title: 'Install update and restart?',
        body: _confirmBody(strategy.pendingVersion),
        confirmLabel: 'Install & restart',
      );
      if (!confirmed) {
        _set(const UpdateInstallIdle());
        return;
      }
    }

    // Flip to working BEFORE anything slow. Everything below is silent — the
    // Store re-scans its pending set for seconds with no UI of its own — and
    // that gap is what made the tap look like it had been ignored.
    _set(const UpdateInstallWorking(0));
    _listenProgress(strategy);

    // Checked BEFORE the drain, never after: the drain stops the user's agent
    // sessions, so bailing out once it has run would cost them everything and
    // install nothing. Past this line the sequence always reaches `install`,
    // whose Windows implementation ignores the context anyway.
    if (!context.mounted) {
      _cancelProgress();
      _set(const UpdateInstallIdle());
      return;
    }
    if (endsSession) await _drainOwnedHost();

    UpdateInstallResult result;
    try {
      // The drain above is the only async gap this context crosses, and it runs
      // solely for `installEndsSession` strategies — whose install ignores the
      // context entirely (it just calls the Store). Re-checking here and
      // bailing is the one outcome worse than proceeding: the sessions are
      // already gone. Every context use AFTER this point is guarded.
      // ignore: use_build_context_synchronously
      result = await strategy.install(context);
    } catch (e) {
      // Strategies document that they never throw; a future one that does must
      // not leave the affordance stuck reporting an install forever.
      AbLog.error(
        'UpdateInstall',
        'strategy install threw',
        fields: {'error': '$e'},
      );
      result = UpdateInstallResult.unavailable;
    }
    _cancelProgress();
    _set(switch (result) {
      // Done is a terminal state the row refuses to leave, which is only
      // truthful where the process is dying around it. Everywhere else the
      // hand-off was to a browser, Sparkle or the App Store — the user can
      // back out of all three, so the affordance has to stay clickable.
      UpdateInstallResult.handedOff =>
        endsSession ? const UpdateInstallDone() : const UpdateInstallIdle(),
      UpdateInstallResult.nothingPending => const UpdateInstallIdle(),
      UpdateInstallResult.notInstalled ||
      UpdateInstallResult.unavailable => UpdateInstallFailed(result),
    });
    if (context.mounted) _toastFor(context, result);
  }

  void _toastFor(BuildContext context, UpdateInstallResult result) {
    switch (result) {
      case UpdateInstallResult.handedOff:
        break;
      case UpdateInstallResult.nothingPending:
        _toast(
          context,
          icon: AbIcons.check,
          title: 'Already up to date',
          description: 'There was nothing left to install.',
        );
      case UpdateInstallResult.notInstalled:
        _toast(
          context,
          icon: AbIcons.warning,
          title: 'Update not installed',
          description: 'It is still pending — you can start it again.',
        );
      case UpdateInstallResult.unavailable:
        _toast(
          context,
          icon: AbIcons.error,
          title: "Couldn't start the update",
          description: 'Try again later.',
        );
    }
  }

  /// Shuts the app-spawned bridge host down while we still can.
  ///
  /// Best-effort on purpose: the user has already decided, so a wedged host
  /// must not be able to veto the update. Failing here costs what happens
  /// today — the job object sweeps the tree as the process dies. The outer
  /// timeout only backstops `shutdownOwnedHost`'s own ~5s ceiling; both fit
  /// well inside Windows' 30s shutdown budget.
  Future<void> _drainOwnedHost() async {
    try {
      await ref
          .read(hostControllerProvider)
          .shutdownOwnedHost()
          .timeout(const Duration(seconds: 8));
    } catch (e) {
      AbLog.warn(
        'UpdateInstall',
        'host drain before update failed (ignored)',
        fields: {'error': '$e'},
      );
    }
  }

  String _confirmBody(String? version) {
    final lead = version == null
        ? 'This update installs over a closed app'
        : 'Version $version installs over a closed app';
    // Open PROJECTS, not running agents — a true agent count needs a bridge
    // round-trip this dialog does not justify, so the copy says what the
    // number actually is. Suppressed at zero rather than printed as "0".
    final open = ref.read(projectSessionRegistryProvider).length;
    final sessions = switch (open) {
      0 => '',
      1 => ' 1 open project session will stop.',
      _ => ' $open open project sessions will stop.',
    };
    return '$lead: Antgrid quits and the local agent bridge shuts down with '
        'it.$sessions Antgrid should reopen itself once the install finishes; '
        'if it does not, start it again yourself.';
  }

  void _listenProgress(UpdateStrategy strategy) {
    _cancelProgress();
    final progress = strategy.installProgress;
    if (progress == null) return;
    _progress = progress.listen((percent) {
      // A tick racing the install's own answer (or the notifier's disposal)
      // must not drag a settled state back into working.
      if (_disposed || state is! UpdateInstallWorking) return;
      _set(UpdateInstallWorking(percent));
    });
  }

  void _cancelProgress() {
    final sub = _progress;
    _progress = null;
    if (sub != null) unawaited(sub.cancel());
  }

  void _set(UpdateInstallState next) {
    if (_disposed) return;
    state = next;
  }

  void _toast(
    BuildContext context, {
    required String icon,
    required String title,
    required String description,
  }) {
    if (!context.mounted) return;
    showAbToastOverlay(
      context,
      duration: const Duration(seconds: 8),
      toast: AbToast(
        icon: icon,
        iconColor: context.antgrid.textMuted,
        title: title,
        description: description,
      ),
    );
  }
}

/// The one install sequence, shared by the drawer row and the update toasts.
/// Never autoDispose: the sequence outlives the widget that started it (the
/// drawer can close, a toast times out) and a second tap must still find the
/// same in-flight state to refuse.
final updateInstallControllerProvider =
    NotifierProvider<UpdateInstallController, UpdateInstallState>(
      UpdateInstallController.new,
    );
