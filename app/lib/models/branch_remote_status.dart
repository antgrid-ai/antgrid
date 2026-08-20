import 'package:flutter/foundation.dart';

/// How a local branch stands against the branch it pushes to on the remote, as
/// measured by the bridge asking the remote directly. Mirrors
/// `BranchRemoteState` in `bridge/src/git-branches.ts` BY HAND — the two
/// drifting apart is silent.
///
/// [differs] is the state a `refs/remotes/*` comparison cannot produce: the
/// remote commit is not an object in the local repo, which proves the remote
/// holds work this branch does not, while making counts impossible without a
/// fetch. It is the common answer for a repo nobody has fetched lately.
enum BranchRemoteState {
  noRemote,
  noUpstream,
  gone,
  inSync,
  behind,
  ahead,
  diverged,
  differs,
  unreachable;

  static BranchRemoteState fromWire(String raw) => switch (raw) {
        'no-remote' => BranchRemoteState.noRemote,
        'no-upstream' => BranchRemoteState.noUpstream,
        'gone' => BranchRemoteState.gone,
        'in-sync' => BranchRemoteState.inSync,
        'behind' => BranchRemoteState.behind,
        'ahead' => BranchRemoteState.ahead,
        'diverged' => BranchRemoteState.diverged,
        'differs' => BranchRemoteState.differs,
        // An unknown state is a newer bridge, not a broken one. Treating it as
        // unreachable renders nothing, which is the safe end of an advisory.
        _ => BranchRemoteState.unreachable,
      };
}

@immutable
class BranchRemoteStatus {
  final String branch;
  final BranchRemoteState state;
  final String? remote;
  final String? remoteBranch;
  final int? behind;
  final int? ahead;

  const BranchRemoteStatus({
    required this.branch,
    required this.state,
    this.remote,
    this.remoteBranch,
    this.behind,
    this.ahead,
  });

  /// `origin/main` when both halves resolved, else just the branch name — used
  /// in copy, so it must never render a dangling slash.
  String get remoteRefLabel {
    final r = remote;
    final b = remoteBranch;
    if (r == null || r.isEmpty || b == null || b.isEmpty) return branch;
    return '$r/$b';
  }

  /// Whether this state is worth interrupting the composer for. Ahead-only and
  /// `gone` are deliberately silent: neither means the session would start from
  /// a stale base, which is the whole point of the warning.
  bool get isStaleBase =>
      state == BranchRemoteState.behind ||
      state == BranchRemoteState.diverged ||
      state == BranchRemoteState.differs;

  factory BranchRemoteStatus.fromJson(Map<String, dynamic> json) {
    final branch = json['branch'];
    if (branch is! String || branch.isEmpty) {
      throw const FormatException('Invalid or missing branch in BranchRemoteStatus');
    }
    final state = json['state'];
    if (state is! String) {
      throw const FormatException('Invalid or missing state in BranchRemoteStatus');
    }
    int? count(Object? v) => v is int ? v : (v is num ? v.toInt() : null);
    return BranchRemoteStatus(
      branch: branch,
      state: BranchRemoteState.fromWire(state),
      remote: json['remote'] is String ? json['remote'] as String : null,
      remoteBranch: json['remoteBranch'] is String ? json['remoteBranch'] as String : null,
      behind: count(json['behind']),
      ahead: count(json['ahead']),
    );
  }

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is BranchRemoteStatus &&
          runtimeType == other.runtimeType &&
          branch == other.branch &&
          state == other.state &&
          remote == other.remote &&
          remoteBranch == other.remoteBranch &&
          behind == other.behind &&
          ahead == other.ahead;

  @override
  int get hashCode => Object.hash(branch, state, remote, remoteBranch, behind, ahead);
}
