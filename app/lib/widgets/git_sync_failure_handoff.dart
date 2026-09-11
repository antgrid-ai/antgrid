import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../models/ab_message.dart' show GitFileStatusEntry;
import '../models/git_sync_state.dart';
import 'send_capture_to_agent.dart';
import 'send_to_agent_comment.dart';

/// Hands a failed push or pull to the coding agent.
///
/// Everything the agent needs is already structured on [failure] — the
/// invocation, git's verbatim stderr, the branch and its remote — so the report
/// is COMPOSED from those fields and never re-parsed out of git's prose. That
/// is the same split the bridge makes: it classifies, the app forwards.
///
/// Deliberately one tap and never automatic. A failure that wrote itself into
/// an agent's stdin would interleave with whatever turn was already running.
Future<void> offerSyncFailureToAgent({
  required BuildContext context,
  required ProviderContainer container,
  required GitSyncFailure failure,
  GitSyncState sync = GitSyncState.empty,
  List<GitFileStatusEntry> changed = const [],
}) async {
  final report = composeSyncFailureReport(
    failure: failure,
    sync: sync,
    changed: changed,
  );

  // The existing review dialog: it shows the composed report and lets the user
  // add a line before anything is sent. This IS the confirmation step — there
  // is deliberately no second one.
  final message = await showSendToAgentComment(
    context: context,
    selectedText: report,
    sourceLabel: '[from git ${failure.op.name}]',
  );
  if (message == null || !context.mounted) return;

  // `sendCaptureToAgent`, not `TerminalService.sendToAgentTerminal`: only it
  // routes for BOTH session modes — a terminal agent takes stdin, a chat agent
  // takes a composer handoff, and they are genuinely different destinations.
  await sendCaptureToAgent(
    context: context,
    container: container,
    text: message,
  );
}

/// The report handed to the agent.
///
/// The closing instruction is the load-bearing line and belongs in the text
/// rather than in the user's head: it is what keeps a helpful agent from
/// reaching for `reset --hard` or `push --force` to make the error go away. It
/// is a request, not a guarantee — the Handler's own destructive floor is what
/// actually bounds a force push if one is proposed.
///
/// Separated from the dialog so it can be tested without a widget tree.
String composeSyncFailureReport({
  required GitSyncFailure failure,
  GitSyncState sync = GitSyncState.empty,
  List<GitFileStatusEntry> changed = const [],
}) {
  final buffer = StringBuffer();
  final verb = failure.op == GitSyncOp.push ? 'push' : 'pull';
  final command = failure.command;

  buffer.writeln(
    command != null ? '`$command` failed.' : 'git $verb failed.',
  );

  final stderr = failure.stderr?.trim();
  if (stderr != null && stderr.isNotEmpty) {
    buffer.writeln();
    // Indented rather than fenced: this goes into a terminal agent's stdin as
    // often as into a chat composer, and a fence there is just noise.
    for (final line in stderr.split('\n')) {
      buffer.writeln('  ${line.trimRight()}');
    }
  } else {
    buffer.writeln();
    buffer.writeln('  ${failure.message}');
  }

  buffer.writeln();
  final branch = failure.branch ?? sync.branch;
  final remoteRef = failure.remoteRefLabel ?? sync.remoteRefLabel;
  if (branch != null && remoteRef != null && sync.hasUpstream) {
    buffer.writeln(
      'Branch `$branch` is ${sync.ahead} ahead and ${sync.behind} behind '
      '`$remoteRef`.',
    );
  } else if (branch != null && remoteRef != null) {
    buffer.writeln('Branch `$branch` has no upstream; `$remoteRef` is where it '
        'would be published.');
  } else if (branch != null) {
    buffer.writeln('Branch `$branch`.');
  }

  final worktree = _describeWorktree(changed);
  if (worktree != null) buffer.writeln('Working tree: $worktree.');

  buffer.writeln();
  buffer.writeln(_instructionFor(failure));
  return buffer.toString().trimRight();
}

/// What the agent is being asked to do, per failure kind. Each names the
/// outcome the user wants rather than a command, so the agent picks the route
/// — and each rules out the destructive shortcut that would technically make
/// the error stop.
String _instructionFor(GitSyncFailure failure) => switch (failure.kind) {
  GitSyncFailureKind.notFastForward ||
  GitSyncFailureKind.rejected => 'Please reconcile this and push, without '
      'discarding my local commits and without force-pushing.',
  GitSyncFailureKind.diverged => 'Please reconcile the two histories and bring '
      'the branch up to date, without discarding my local commits.',
  GitSyncFailureKind.conflict => 'Please resolve the merge conflicts, then '
      'finish the ${failure.op.name}.',
  GitSyncFailureKind.dirtyTree => 'Please get my uncommitted changes safely out '
      'of the way (commit or stash them — do not discard them), then '
      '${failure.op.name}.',
  GitSyncFailureKind.auth => 'Please work out what credentials this remote '
      'needs and tell me what to do — do not store any secret in the repo.',
  GitSyncFailureKind.noUpstream ||
  GitSyncFailureKind.ambiguousRemote => 'Please work out which remote this '
      'branch should track, set it, and push.',
  _ => 'Please work out what went wrong and finish the ${failure.op.name}, '
      'without discarding my local commits.',
};

/// "4 modified, 1 untracked" — the counts that explain a dirty-tree refusal,
/// deduped by path because a path staged AND edited again legitimately appears
/// twice in the entry list.
String? _describeWorktree(List<GitFileStatusEntry> changed) {
  if (changed.isEmpty) return null;
  final byPath = <String, String>{};
  for (final e in changed) {
    // Worktree status wins over staged, matching the emission order the bridge
    // documents — what blocks a checkout is the unstaged edit.
    byPath[e.path] = e.status;
  }
  var modified = 0;
  var untracked = 0;
  var conflicted = 0;
  for (final status in byPath.values) {
    switch (status) {
      case 'U':
        untracked++;
      case '!':
        conflicted++;
      default:
        modified++;
    }
  }
  final parts = <String>[
    if (modified > 0) '$modified modified',
    if (untracked > 0) '$untracked untracked',
    if (conflicted > 0) '$conflicted conflicted',
  ];
  return parts.isEmpty ? null : parts.join(', ');
}
