import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'value_controller.dart';

/// The stages `startNewSession` walks, in the order it walks them.
///
/// Declaration order is load-bearing: [NewSessionStartProgress.isCancellable]
/// compares indices against [creating].
enum NewSessionStartPhase {
  /// Optional git checkout, before the target is touched.
  switchingBranch,

  /// Resolving + activating the target project (`project:start` when remote).
  activating,

  /// Waiting for the machine to report the project running.
  connecting,

  /// Waiting for the per-project transport + service façades to construct.
  preparing,

  /// `session:create` is on the wire.
  creating,

  /// `session:start` is on the wire.
  launching,
}

/// Why a start ended without producing a session. Every non-throwing bail-out
/// in `startNewSession` carries one, so the composer can say what happened
/// instead of the operation vanishing silently.
enum NewSessionStartAbortReason {
  /// The user pressed Stop while the start was still cancellable.
  cancelled,

  /// Target, branch or isolation changed mid-flight, so the session that would
  /// have been created is no longer the one the form describes.
  intentChanged,

  /// `session:create` came back without a session.
  createRefused,

  /// `session:start` came back without a session and without a coded refusal
  /// (a coded one is raised to the composer instead).
  startRefused,

  /// Isolated was requested but the target's catalog does not advertise
  /// worktree sessions — an old bridge would silently make a shared session.
  isolationUnavailable,

  /// The active project changed between `session:create` and `session:start`,
  /// so the session exists on the bridge but was never launched. Distinct from
  /// [intentChanged], which only covers bail-outs that put nothing on the wire.
  abandonedAfterCreate,

  /// The active project changed while `session:start` was on the wire, so the
  /// session is running but the app never focused it. The one outcome where
  /// the user is owed the session's whereabouts rather than a reason it
  /// doesn't exist.
  startedAfterSwitch,

  /// A `session:create`/`session:start` reply never arrived. The bridge may
  /// hold a session either way, which is the whole reason this is its own
  /// reason and not a refusal.
  replyTimedOut,
}

/// One start's outcome: why it produced no session, plus what it nonetheless
/// left behind on the machine.
///
/// [branchSwitchedTo] is orthogonal to [reason] rather than a reason of its
/// own: the checkout runs FIRST and is the one step of a start the app cannot
/// undo, so every later abort — a Stop, a form edit, a refused create, a reply
/// that never came — ends with the folder on a branch the user did not ask to
/// be left on. Folding it into the reason enum would need a parallel value for
/// each of them.
class NewSessionStartAbort {
  final NewSessionStartAbortReason reason;

  /// Branch this start checked out before it ended, or null when it moved
  /// nothing. Set only for the shared-checkout path — an isolated start passes
  /// its base branch to `session:create` and never touches the project's tree.
  final String? branchSwitchedTo;

  const NewSessionStartAbort(this.reason, {this.branchSwitchedTo});

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is NewSessionStartAbort &&
          other.reason == reason &&
          other.branchSwitchedTo == branchSwitchedTo;

  @override
  int get hashCode => Object.hash(reason, branchSwitchedTo);

  @override
  String toString() => branchSwitchedTo == null
      ? 'NewSessionStartAbort($reason)'
      : 'NewSessionStartAbort($reason, branchSwitchedTo: $branchSwitchedTo)';
}

/// Snapshot of one in-flight start: the phase it has reached plus the intent it
/// was launched with.
///
/// The intent is CAPTURED here rather than re-read from the form providers, so
/// the status line and the optimistic Recents row keep describing the session
/// actually being started even after the user edits the form behind them.
class NewSessionStartProgress {
  /// Stage currently running.
  final NewSessionStartPhase phase;

  /// Picker target id (local projectId or remote registrationId).
  final String targetId;

  /// Project name, for the row subtitle.
  final String targetName;

  /// Machine the project lives on. Empty for a local target — there is no
  /// machine to wake, and [phaseLabel] words the activating phase accordingly.
  final String deviceName;

  /// Human agent name ("Claude Code"), not the tool key.
  final String agentLabel;

  /// Explicitly selected branch, null when the start takes the checkout as-is.
  final String? branch;

  /// Whether the session was asked for in a managed worktree.
  final bool isolated;

  /// Session name, else the leading prompt text — what the optimistic row shows
  /// where a real session shows its title.
  final String title;

  /// Set by [NewSessionStartController.requestCancel]. `startNewSession`
  /// observes it at its intent checkpoints and aborts at the next one.
  final bool cancelRequested;

  const NewSessionStartProgress({
    required this.phase,
    required this.targetId,
    required this.targetName,
    required this.deviceName,
    required this.agentLabel,
    required this.isolated,
    required this.title,
    this.branch,
    this.cancelRequested = false,
  });

  /// Whether Stop is still offered. Once `session:create` is on the wire,
  /// abandoning the start would orphan a created-but-unstarted session on the
  /// bridge, so from [NewSessionStartPhase.creating] on the user waits it out
  /// (bounded by the two 15s reply timeouts).
  bool get isCancellable => phase.index < NewSessionStartPhase.creating.index;

  /// Only the two fields a running start ever revises. A general `copyWith`
  /// over the captured intent would be a way to make the snapshot stop
  /// describing the session actually being started — and its `branch ??`
  /// arm could never clear a branch anyway.
  NewSessionStartProgress copyWith({
    NewSessionStartPhase? phase,
    bool? cancelRequested,
  }) => NewSessionStartProgress(
    phase: phase ?? this.phase,
    targetId: targetId,
    targetName: targetName,
    deviceName: deviceName,
    agentLabel: agentLabel,
    branch: branch,
    isolated: isolated,
    title: title,
    cancelRequested: cancelRequested ?? this.cancelRequested,
  );

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is NewSessionStartProgress &&
          other.phase == phase &&
          other.targetId == targetId &&
          other.targetName == targetName &&
          other.deviceName == deviceName &&
          other.agentLabel == agentLabel &&
          other.branch == branch &&
          other.isolated == isolated &&
          other.title == title &&
          other.cancelRequested == cancelRequested;

  @override
  int get hashCode => Object.hash(
    phase,
    targetId,
    targetName,
    deviceName,
    agentLabel,
    branch,
    isolated,
    title,
    cancelRequested,
  );

  @override
  String toString() =>
      'NewSessionStartProgress($phase, $targetId, cancelRequested: '
      '$cancelRequested)';
}

/// The in-flight start, or null when idle.
///
/// Lives in a provider rather than composer state because `NewSessionScreen`
/// rebuilds three different trees around the compact breakpoint: a resize mid
/// start disposes the composer, and widget-local state would take the lock with
/// it while the start kept running.
final newSessionStartProgressProvider =
    NotifierProvider<NewSessionStartController, NewSessionStartProgress?>(
      NewSessionStartController.new,
    );

/// How the last start ended, or null if none has since it was consumed.
///
/// Separate from [newSessionStartProgressProvider] because it must OUTLIVE the
/// progress it describes: `startNewSession` clears progress in its `finally`,
/// and the composer only gets to message the outcome after the await returns.
final newSessionStartAbortProvider =
    NotifierProvider<
      ValueController<NewSessionStartAbort?>,
      NewSessionStartAbort?
    >(() => ValueController(null));

class NewSessionStartController extends Notifier<NewSessionStartProgress?> {
  @override
  NewSessionStartProgress? build() => null;

  /// Branch the running start has already checked out, or null. Held here
  /// rather than on [NewSessionStartProgress] because nothing renders it — it
  /// exists only to be folded into whatever abort comes next.
  String? _branchSwitchedTo;

  /// Arm a start at [phase] with the intent it was launched with. Clears any
  /// abort reason left unconsumed by a previous attempt.
  void begin({
    required NewSessionStartPhase phase,
    required String targetId,
    required String targetName,
    required String deviceName,
    required String agentLabel,
    required bool isolated,
    required String title,
    String? branch,
  }) {
    ref.read(newSessionStartAbortProvider.notifier).set(null);
    _branchSwitchedTo = null;
    state = NewSessionStartProgress(
      phase: phase,
      targetId: targetId,
      targetName: targetName,
      deviceName: deviceName,
      agentLabel: agentLabel,
      isolated: isolated,
      title: title,
      branch: branch,
    );
  }

  /// Move to [phase]. A no-op when idle, so a stage that completes after [end]
  /// cannot resurrect the lock — and monotonic, so no publisher can rewind a
  /// start already past [NewSessionStartPhase.creating] and re-offer a Stop the
  /// flow can no longer honour. Every publisher is inside `startNewSession`;
  /// keep it that way, because monotonicity refuses rewinds and cannot refuse a
  /// foreign forward jump.
  void advance(NewSessionStartPhase phase) {
    final current = state;
    if (current == null || phase.index <= current.phase.index) return;
    state = current.copyWith(phase: phase);
  }

  /// Ask the running start to stop. Returns false — and changes nothing — when
  /// idle or past the cancel boundary
  /// (see [NewSessionStartProgress.isCancellable]).
  bool requestCancel() {
    final current = state;
    if (current == null || !current.isCancellable) return false;
    if (current.cancelRequested) return true;
    state = current.copyWith(cancelRequested: true);
    return true;
  }

  /// Note that this start has moved the project's working tree to [branch].
  /// Called the moment the checkout returns, because from then on no outcome
  /// of this start can honestly claim it left the folder alone.
  void markBranchSwitched(String branch) => _branchSwitchedTo = branch;

  /// Record why this start produced no session. Does NOT clear the progress —
  /// `startNewSession` still runs its `finally`, which calls [end].
  void abort(NewSessionStartAbortReason reason) {
    ref
        .read(newSessionStartAbortProvider.notifier)
        .set(NewSessionStartAbort(reason, branchSwitchedTo: _branchSwitchedTo));
  }

  /// Read the pending outcome and clear it, so one abort is messaged once.
  NewSessionStartAbort? takeAbort() {
    final abort = ref.read(newSessionStartAbortProvider);
    if (abort != null) {
      ref.read(newSessionStartAbortProvider.notifier).set(null);
    }
    return abort;
  }

  /// Disarm. Idempotent.
  ///
  /// Drops the checkout too, not only [begin] — `startNewSession` records the
  /// isolation-unavailable abort BEFORE it arms, so a branch left standing here
  /// would be appended to a start that touched no working tree.
  void end() {
    state = null;
    _branchSwitchedTo = null;
  }
}

/// Whether the user has asked the running start to stop. `startNewSession`
/// folds this into its intent checkpoints.
final newSessionStartCancelRequestedProvider = Provider<bool>(
  (ref) => ref.watch(
    newSessionStartProgressProvider.select(
      (p) => p != null && p.cancelRequested,
    ),
  ),
);

/// True while a start is in flight. Derived from
/// [newSessionStartProgressProvider], so nothing has to keep a second flag in
/// step with it.
///
/// Re-exported by `new_session_picker.dart`, which is where its long-standing
/// readers import it from.
final newSessionStartInFlightProvider = Provider<bool>(
  (ref) => ref.watch(newSessionStartProgressProvider.select((p) => p != null)),
);

/// The one place New Session phase copy lives — chrome prose, so sans at every
/// call site.
String phaseLabel(NewSessionStartProgress p) {
  if (p.cancelRequested) return 'Cancelling...';
  switch (p.phase) {
    case NewSessionStartPhase.switchingBranch:
      final branch = p.branch;
      return branch == null ? 'Switching branch...' : 'Switching to $branch...';
    case NewSessionStartPhase.activating:
      // A local target has no machine to wake; the work is the same, the story
      // isn't.
      return p.deviceName.isEmpty
          ? 'Opening ${p.targetName}...'
          : 'Waking ${p.deviceName}...';
    case NewSessionStartPhase.connecting:
      return 'Starting project...';
    case NewSessionStartPhase.preparing:
      return 'Preparing workspace...';
    case NewSessionStartPhase.creating:
      return 'Creating session...';
    case NewSessionStartPhase.launching:
      return p.agentLabel.isEmpty
          ? 'Launching agent...'
          : 'Launching ${p.agentLabel}...';
  }
}
