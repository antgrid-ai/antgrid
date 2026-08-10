import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../services/devices_api.dart';
import '../storage/first_run_store.dart';
import 'account_agents.dart';
import 'agent_transport.dart';
import 'auth.dart';
import 'device_provisioning.dart';
import 'now_ticker.dart';
import 'projects.dart';
import 'recent_sessions.dart';

/// Throws unless overridden in main() — mirrors recentAgentsStoreProvider
/// (recent_agents.dart).
final firstRunStoreProvider = Provider<FirstRunStore>(
  (_) => throw StateError('firstRunStoreProvider must be overridden in main()'),
);

/// Stable persisted step ids. Latched into [FirstRunState.completedSteps], so
/// renaming one silently un-checks it for every mid-checklist user.
abstract final class FirstRunStepIds {
  // Desktop.
  static const signIn = 'signIn';
  static const openProject = 'openProject';
  static const startSession = 'startSession';
  static const connectPhone = 'connectPhone';
  static const armHandler = 'armHandler';
  // Mobile.
  static const machineLinked = 'machineLinked';
  static const remoteOn = 'remoteOn';
  static const openedProject = 'openedProject';
}

class FirstRunController extends Notifier<FirstRunState> {
  late FirstRunStore _store;

  @override
  FirstRunState build() {
    _store = ref.watch(firstRunStoreProvider);
    return _store.read();
  }

  // All mutations: update state synchronously, persist fire-and-forget — the
  // same pattern as CollapsedDrawerIdsNotifier._persist (collapsed_drawer.dart).
  void _commit(FirstRunState next) {
    state = next;
    unawaited(_store.write(next));
  }

  void dismissChecklist() {
    if (state.checklistDismissed) return;
    _commit(state.copyWith(checklistDismissed: true));
  }

  /// Union [ids] into the persisted latch; a no-op (all already latched)
  /// writes nothing.
  void latchSteps(Set<String> ids) {
    if (ids.every(state.completedSteps.contains)) return;
    _commit(
      state.copyWith(completedSteps: {...state.completedSteps, ...ids}),
    );
  }

  void markChecklistCompleted() {
    if (state.checklistCompleted) return;
    _commit(state.copyWith(checklistCompleted: true));
  }

  // Remote-access nudge (consumed by the nudge package; defined here so the
  // persistence surface has a single owner).
  void dismissNudgeSoft() {
    if (state.nudgeSoftDismissed) return;
    _commit(state.copyWith(nudgeSoftDismissed: true));
  }

  void dismissNudgeDevice() {
    if (state.nudgeDeviceDismissed) return;
    _commit(state.copyWith(nudgeDeviceDismissed: true));
  }

  /// Called on EVERY successful arm (idempotent): the flag retires the first-arm
  /// explainer, the labeled shield, and the away-moment hint in one write.
  void markHandlerArmed() {
    if (state.handlerArmedOnce) return;
    _commit(state.copyWith(handlerArmedOnce: true));
  }

  void dismissHandlerAwayHint() {
    if (state.handlerAwayHintDismissed) return;
    _commit(state.copyWith(handlerAwayHintDismissed: true));
  }
}

final firstRunProvider =
    NotifierProvider<FirstRunController, FirstRunState>(FirstRunController.new);

/// Both the checklist and the remote-access nudge read this: checklist
/// surfaces show iff true; the nudge suppresses itself while true so the two
/// never stack.
final firstRunChecklistVisibleProvider = Provider<bool>((ref) {
  final s = ref.watch(firstRunProvider);
  return !s.checklistDismissed && !s.checklistCompleted;
});

/// One checklist line. Displayed check = live signal OR persisted latch, so a
/// regressing signal (revoked phone, offline inventory) never un-checks a step.
typedef FirstRunStep = ({String id, String label, bool done});

/// Phones/tablets on the account. kind == 'app' filters out machine
/// (kind:"agent") records; the platform filter {'ios','android'} is what
/// excludes DESKTOP controller records — desktop remote-control provisions a
/// separate kind:"app" record named after the host plus a "(controller)" suffix
/// (connection_identity.dart; the device_provisioning service's
/// detectPlatform() writes exactly 'ios'/'android' for mobile) — so no fragile
/// displayName suffix matching.
///
/// autoDispose + nowMinuteProvider: re-fetches once a minute ONLY while a
/// checklist card / nudge banner is mounted; hidden surfaces stop the poll.
/// Deliberately the ACCOUNT inventory (`GET /account/devices`), not the
/// bridge-side roster (remote_access.dart's remoteDevicesProvider) — that only
/// lists devices that already connected to this machine, whereas these
/// surfaces fire on "signed in to the account".
final otherAccountMobileDevicesProvider =
    FutureProvider.autoDispose<List<DeviceSummary>>((ref) async {
      ref.watch(nowMinuteProvider);
      if (ref.watch(signedInProvider) != true) return const [];
      try {
        final devices = await ref.watch(devicesApiProvider).list();
        return devices
            .where(
              (d) =>
                  d.kind == 'app' &&
                  const {'ios', 'android'}.contains(d.platform.toLowerCase()),
            )
            .toList(growable: false);
      } catch (_) {
        // A network exception must not poison the checklist.
        return const [];
      }
    });

/// Desktop setup steps. autoDispose so the minute-cadence device poll behind
/// step 4 tears down with the last mounted checklist card.
final desktopFirstRunStepsProvider =
    Provider.autoDispose<List<FirstRunStep>>((ref) {
      final latched = ref.watch(
        firstRunProvider.select((s) => s.completedSteps),
      );
      bool done(String id, bool live) => live || latched.contains(id);
      // `null` (unknown / splash) counts as not-done: the checklist never
      // claims a step on an unconfirmed signal.
      final signedIn = ref.watch(signedInProvider) == true;
      final hasProject = ref.watch(projectsProvider).isNotEmpty;
      final hasSession = ref.watch(recentSessionsProvider).isNotEmpty;
      final hasPhone =
          (ref.watch(otherAccountMobileDevicesProvider).value ?? const [])
              .isNotEmpty;
      return [
        (
          id: FirstRunStepIds.signIn,
          label: 'Sign in',
          done: done(FirstRunStepIds.signIn, signedIn),
        ),
        (
          id: FirstRunStepIds.openProject,
          label: 'Open a project',
          done: done(FirstRunStepIds.openProject, hasProject),
        ),
        (
          id: FirstRunStepIds.startSession,
          label: 'Start a session',
          done: done(FirstRunStepIds.startSession, hasSession),
        ),
        (
          id: FirstRunStepIds.connectPhone,
          label: 'Connect your phone',
          done: done(FirstRunStepIds.connectPhone, hasPhone),
        ),
        // Desktop-only step: the mobile checklist's contract is "fill the
        // Recent canvas's empty slot until the steps that make the rest of the
        // UI exist are done" — arming happens inside an open session, after
        // that canvas is gone. The flag is still global, so an arm performed on
        // mobile checks this step too.
        (
          id: FirstRunStepIds.armHandler,
          label: 'Arm Handler on a session',
          done: done(
            FirstRunStepIds.armHandler,
            ref.watch(firstRunProvider.select((s) => s.handlerArmedOnce)),
          ),
        ),
      ];
    });

/// Mobile setup steps. None of these may watch controlPlaneStateProvider —
/// reading that family member DIALS the machine, and the Recent canvas's
/// contract is render-from-cache, connect only on explicit pull.
final mobileFirstRunStepsProvider =
    Provider.autoDispose<List<FirstRunStep>>((ref) {
      final latched = ref.watch(
        firstRunProvider.select((s) => s.completedSteps),
      );
      bool done(String id, bool live) => live || latched.contains(id);
      // `/account/agents` returns only machine (kind:"agent") records, so any
      // row means a computer signed in. Refreshed by the canvas's existing
      // pull-to-refresh (refreshMachineInventoryAndControlPlanes invalidates
      // it).
      final machineLinked =
          (ref.watch(accountAgentsProvider).value ?? const []).isNotEmpty;
      // Projects-visible proxy for "remote access is on": a bridge with remote
      // off advertises nothing (see machineAdvertisedProjectsProvider for the
      // seam to swap once the explicit advert flag lands).
      final remoteOn = ref
          .watch(machineAdvertisedProjectsProvider)
          .values
          .any((n) => n > 0);
      // Latch-on-event: the selection nulls on sign-out, which is exactly why
      // the persisted latch carries it. NOT recentAgentsProvider — a
      // RecentAgent row is upserted on any transport materialization
      // (including pull-to-refresh), before any project is opened.
      final openedProject = ref.watch(selectedRegistrationIdProvider) != null;
      return [
        (
          id: FirstRunStepIds.machineLinked,
          label: 'Install Antgrid on your computer and sign in there',
          done: done(FirstRunStepIds.machineLinked, machineLinked),
        ),
        (
          id: FirstRunStepIds.remoteOn,
          label: "Turn on Remote in that computer's title bar",
          done: done(FirstRunStepIds.remoteOn, remoteOn),
        ),
        (
          id: FirstRunStepIds.openedProject,
          label: 'Open a project',
          done: done(FirstRunStepIds.openedProject, openedProject),
        ),
      ];
    });
