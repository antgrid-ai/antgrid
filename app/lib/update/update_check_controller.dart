import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../providers/update_available.dart';
import 'update_check_result.dart';
import 'update_install_controller.dart';
import 'update_strategy.dart';

class UpdateCheckState {
  const UpdateCheckState({this.checking = false, this.result});
  final bool checking;
  final UpdateCheckResult? result;
}

final updateCheckClockProvider = Provider<DateTime Function()>(
  (_) => DateTime.now,
);
final updateCheckTimeoutProvider = Provider<Duration>(
  (_) => const Duration(seconds: 20),
);

/// Outlives menus and dialogs: dismissal cannot cancel detection, reset the
/// automatic throttle, or release an outstanding native call for a second check.
class UpdateCheckController extends Notifier<UpdateCheckState> {
  Future<UpdateCheckResult>? _inFlight;
  Timer? _checkTimer;
  Completer<UpdateCheckResult>? _boundedCheck;
  bool _prepared = false;
  bool _manualJoined = false;
  bool _dialogOpen = false;
  DateTime? _lastAutomaticCheck;

  bool get dialogOpen => _dialogOpen;
  bool get automaticResultSuppressed => _manualJoined || _dialogOpen;

  @override
  UpdateCheckState build() {
    final strategy = ref.read(updateStrategyProvider);
    final retraction = strategy?.updateRetracted?.listen((_) {
      if (!ref.mounted) return;
      ref.read(updateAvailableProvider.notifier).set(false);
      final result = state.result;
      state = UpdateCheckState(
        result: UpdateCheckResult(
          UpdateCheckStatus.unsupported,
          candidateId: result?.candidateId,
          message:
              'The platform updater cannot install this update on this device.',
        ),
      );
    });
    final changes = strategy?.statusChanges?.listen((result) {
      if (ref.mounted) _publish(result);
    });
    ref.onDispose(() {
      _checkTimer?.cancel();
      final pending = _boundedCheck;
      if (pending != null && !pending.isCompleted) {
        pending.complete(UpdateCheckResult.failed);
      }
      unawaited(retraction?.cancel());
      unawaited(changes?.cancel());
    });
    return const UpdateCheckState();
  }

  bool claimDialog() {
    if (_dialogOpen) return false;
    _dialogOpen = true;
    _manualJoined = true;
    return true;
  }

  void releaseDialog() => _dialogOpen = false;

  Future<UpdateCheckResult> checkManually() {
    _manualJoined = true;
    return _check(manual: true);
  }

  Future<UpdateCheckOutcome> checkAutomatically() async {
    final strategy = ref.read(updateStrategyProvider);
    if (strategy == null ||
        !strategy.active ||
        strategy.skipAutomaticChecks ||
        _dialogOpen) {
      return UpdateCheckOutcome.none;
    }
    final now = ref.read(updateCheckClockProvider)();
    final last = _lastAutomaticCheck;
    if (last != null && now.difference(last) < const Duration(minutes: 30)) {
      return UpdateCheckOutcome.none;
    }
    _lastAutomaticCheck = now;
    if (_inFlight == null) _manualJoined = false;
    if (ref.read(updateAvailableProvider) &&
        strategy.skipAutomaticWhenPending) {
      return UpdateCheckOutcome.none;
    }
    final result = await _check(manual: false);
    if (!ref.mounted ||
        _manualJoined ||
        _dialogOpen ||
        !ref.read(updateInstallControllerProvider).canStart) {
      return UpdateCheckOutcome.none;
    }
    return strategy.automaticOutcome(result);
  }

  Future<UpdateCheckResult> _check({required bool manual}) {
    final pending = _inFlight;
    if (pending != null) return pending;
    final strategy = ref.read(updateStrategyProvider);
    if (strategy == null || !strategy.active) {
      _publish(UpdateCheckResult.unsupported);
      return Future.value(UpdateCheckResult.unsupported);
    }
    if (!ref.read(updateInstallControllerProvider).canStart) {
      final result = UpdateCheckResult(
        UpdateCheckStatus.downloading,
        version: strategy.pendingVersion,
        candidateId: state.result?.candidateId,
      );
      state = UpdateCheckState(result: state.result);
      return Future.value(result);
    }
    state = UpdateCheckState(checking: true, result: state.result);
    final completion = Completer<UpdateCheckResult>();
    _boundedCheck = completion;
    final timer = Timer(ref.read(updateCheckTimeoutProvider), () {
      completion.complete(UpdateCheckResult.failed);
    });
    _checkTimer = timer;
    _inFlight = completion.future.then((result) {
      if (ref.mounted) _publish(result, manual: manual || _manualJoined);
      return result;
    });
    unawaited(
      _detect(strategy).then((result) {
        timer.cancel();
        if (!completion.isCompleted) completion.complete(result);
        if (ref.mounted) {
          _inFlight = null;
          _checkTimer = null;
          _boundedCheck = null;
        }
      }),
    );
    // Keep the lease until the underlying call ends, even after a UI timeout.
    // Cancel the UI deadline on disposal; the native operation cannot be cancelled.
    return _inFlight!;
  }

  Future<UpdateCheckResult> _detect(UpdateStrategy strategy) async {
    try {
      if (!_prepared) {
        await strategy.prepare();
        _prepared = true;
      }
      return await strategy.detect();
    } catch (_) {
      return UpdateCheckResult.failed;
    }
  }

  void _publish(UpdateCheckResult result, {bool manual = false}) {
    state = UpdateCheckState(result: result);
    if (result.status == UpdateCheckStatus.restartReady ||
        result.status == UpdateCheckStatus.available &&
            (manual ||
                ref.read(updateStrategyProvider) is! PlayUpdateStrategy)) {
      ref.read(updateAvailableProvider.notifier).set(true);
    }
  }
}

final updateCheckControllerProvider =
    NotifierProvider<UpdateCheckController, UpdateCheckState>(
      UpdateCheckController.new,
    );
