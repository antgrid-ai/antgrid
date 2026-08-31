import 'package:flutter/foundation.dart';

import 'branch_remote_status.dart';

/// Why a push or pull did not happen. Mirrors `GitSyncFailureKind` in
/// `bridge/src/git-sync.ts` BY HAND — the two drifting apart is silent.
///
/// The app branches its COPY on this and never on the git output beside it:
/// git's prose is localized and reworded between versions, so parsing it here
/// would be a second, worse classifier. The raw stderr is forwarded to the
/// agent untouched instead.
enum GitSyncFailureKind {
  noRemote,
  noUpstream,
  ambiguousRemote,
  notFastForward,
  rejected,
  diverged,
  auth,
  conflict,
  dirtyTree,
  detached,
  unknown;

  static GitSyncFailureKind fromWire(String raw) => switch (raw) {
    'no-remote' => GitSyncFailureKind.noRemote,
    'no-upstream' => GitSyncFailureKind.noUpstream,
    'ambiguous-remote' => GitSyncFailureKind.ambiguousRemote,
    'not-fast-forward' => GitSyncFailureKind.notFastForward,
    'rejected' => GitSyncFailureKind.rejected,
    'diverged' => GitSyncFailureKind.diverged,
    'auth' => GitSyncFailureKind.auth,
    'conflict' => GitSyncFailureKind.conflict,
    'dirty-tree' => GitSyncFailureKind.dirtyTree,
    'detached' => GitSyncFailureKind.detached,
    // An unrecognized kind is a newer bridge, not a broken one. `unknown`
    // already routes to the agent handoff with the stderr intact, which is the
    // right answer for a failure this app cannot name.
    _ => GitSyncFailureKind.unknown,
  };
}

/// Which half of a sync is in flight, and which one a result describes.
enum GitSyncOp {
  push,
  pull;

  static GitSyncOp? fromWire(String raw) => switch (raw) {
    'push' => GitSyncOp.push,
    'pull' => GitSyncOp.pull,
    _ => null,
  };

  String get label => this == GitSyncOp.push ? 'Push' : 'Pull';
}

/// How the checked-out branch stands against its upstream.
///
/// The counts are LOCAL — measured against `refs/remotes`, so they are as
/// fresh as the last fetch. That is deliberate and is the same contract VS
/// Code's own indicator has: pulling is what refreshes them, and nothing in
/// the always-on path may reach the network. [state] is the exception, present
/// only when the app explicitly asked for a probe.
@immutable
class GitSyncState {
  final String? branch;
  final String? remote;
  final String? remoteBranch;
  final int ahead;
  final int behind;
  final bool hasUpstream;
  final bool hasRemote;

  /// Result of an on-demand network probe, when one ran. Absent means the
  /// counts above are the whole answer.
  final BranchRemoteState? state;

  const GitSyncState({
    this.branch,
    this.remote,
    this.remoteBranch,
    this.ahead = 0,
    this.behind = 0,
    this.hasUpstream = false,
    this.hasRemote = false,
    this.state,
  });

  static const empty = GitSyncState();

  /// `origin/main` when both halves resolved, else null — used in copy, so it
  /// must never render a dangling slash.
  String? get remoteRefLabel {
    final r = remote;
    final b = remoteBranch;
    if (r == null || b == null) return null;
    return '$r/$b';
  }

  /// A branch with commits the remote does not have. The only condition under
  /// which Push does anything — a branch with no upstream is [canPublish].
  bool get canPush => hasUpstream && ahead > 0;

  /// A branch that has never been pushed. Offered as Publish rather than Push,
  /// matching what the bridge actually does (`push -u`).
  bool get canPublish => hasRemote && branch != null && !hasUpstream;

  bool get canPull => hasUpstream && behind > 0;

  factory GitSyncState.fromJson(Map<String, dynamic> json) {
    final rawState = json['state'];
    return GitSyncState(
      branch: json['branch'] as String?,
      remote: json['remote'] as String?,
      remoteBranch: json['remoteBranch'] as String?,
      ahead: json['ahead'] is int ? json['ahead'] as int : 0,
      behind: json['behind'] is int ? json['behind'] as int : 0,
      hasUpstream: json['hasUpstream'] == true,
      hasRemote: json['hasRemote'] == true,
      state: rawState is String ? BranchRemoteState.fromWire(rawState) : null,
    );
  }

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is GitSyncState &&
          other.branch == branch &&
          other.remote == remote &&
          other.remoteBranch == remoteBranch &&
          other.ahead == ahead &&
          other.behind == behind &&
          other.hasUpstream == hasUpstream &&
          other.hasRemote == hasRemote &&
          other.state == state;

  @override
  int get hashCode => Object.hash(
    branch,
    remote,
    remoteBranch,
    ahead,
    behind,
    hasUpstream,
    hasRemote,
    state,
  );
}

/// A push or pull that did not happen, kept whole so it can be handed to the
/// agent.
///
/// [command] and [stderr] are the load-bearing fields and are carried verbatim
/// from git: they are what the agent needs to reconcile the branch, and
/// summarizing them here would throw away the only precise account of what
/// went wrong.
@immutable
class GitSyncFailure {
  final GitSyncOp op;
  final GitSyncFailureKind kind;
  final String? branch;
  final String? remote;
  final String? remoteBranch;

  /// The bridge's own one-line message. Already user-readable — this is what
  /// the toast shows.
  final String message;
  final String? command;
  final String? stderr;

  const GitSyncFailure({
    required this.op,
    required this.kind,
    required this.message,
    this.branch,
    this.remote,
    this.remoteBranch,
    this.command,
    this.stderr,
  });

  String? get remoteRefLabel {
    final r = remote;
    final b = remoteBranch;
    if (r == null || b == null) return null;
    return '$r/$b';
  }

  /// True when reconciling this needs judgement the app does not have — a
  /// history to merge or rebase, a credential to find. These are what the
  /// agent handoff is for.
  ///
  /// The rest ([GitSyncFailureKind.detached], [GitSyncFailureKind.noRemote])
  /// are states the user fixes directly, and offering the agent for them would
  /// send it to do something a single tap already does.
  bool get warrantsAgent => switch (kind) {
    GitSyncFailureKind.noRemote || GitSyncFailureKind.detached => false,
    _ => true,
  };
}
