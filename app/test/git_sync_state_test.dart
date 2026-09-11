import 'package:flutter_test/flutter_test.dart';
import 'package:antgrid/models/ab_message.dart';
import 'package:antgrid/models/git_sync_state.dart';
import 'package:antgrid/widgets/git_sync_failure_handoff.dart';

void main() {
  group('GitSyncState', () {
    test('parses the wire shape the bridge sends', () {
      final s = GitSyncState.fromJson(const {
        'branch': 'main',
        'remote': 'origin',
        'remoteBranch': 'main',
        'ahead': 2,
        'behind': 3,
        'hasUpstream': true,
        'hasRemote': true,
      });
      expect(s.ahead, 2);
      expect(s.behind, 3);
      expect(s.remoteRefLabel, 'origin/main');
      expect(s.canPush, isTrue);
      expect(s.canPull, isTrue);
      expect(s.canPublish, isFalse);
    });

    test('offers Publish, not Push, for a branch with no upstream', () {
      const s = GitSyncState(branch: 'feature', hasRemote: true);
      expect(s.canPublish, isTrue);
      // Push means "send commits the upstream lacks", and there is no upstream
      // to measure against — the two must never both be offered.
      expect(s.canPush, isFalse);
      expect(s.canPull, isFalse);
    });

    test('offers nothing in a repository with no remote', () {
      const s = GitSyncState(branch: 'main');
      expect(s.canPublish, isFalse);
      expect(s.canPush, isFalse);
      expect(s.canPull, isFalse);
    });

    test('renders no remote ref label when only one half resolved', () {
      const s = GitSyncState(branch: 'main', remote: 'origin');
      // A dangling "origin/" would reach user-visible copy.
      expect(s.remoteRefLabel, isNull);
    });

    test('a missing state field means no probe ran, not an unknown state', () {
      final s = GitSyncState.fromJson(const {'ahead': 0, 'behind': 0});
      expect(s.state, isNull);
    });
  });

  group('GitSyncFailureKind.fromWire', () {
    test('maps every kind the bridge can send', () {
      const pairs = {
        'no-remote': GitSyncFailureKind.noRemote,
        'no-upstream': GitSyncFailureKind.noUpstream,
        'ambiguous-remote': GitSyncFailureKind.ambiguousRemote,
        'not-fast-forward': GitSyncFailureKind.notFastForward,
        'rejected': GitSyncFailureKind.rejected,
        'diverged': GitSyncFailureKind.diverged,
        'auth': GitSyncFailureKind.auth,
        'conflict': GitSyncFailureKind.conflict,
        'dirty-tree': GitSyncFailureKind.dirtyTree,
        'detached': GitSyncFailureKind.detached,
      };
      pairs.forEach((wire, kind) {
        expect(GitSyncFailureKind.fromWire(wire), kind, reason: wire);
      });
    });

    test('reads an unrecognized kind as unknown rather than throwing', () {
      // A newer bridge shipping a kind this app predates must still surface the
      // failure — with the stderr intact, which is what the handoff forwards.
      expect(
        GitSyncFailureKind.fromWire('some-future-kind'),
        GitSyncFailureKind.unknown,
      );
    });
  });

  group('git:sync-result parsing', () {
    Map<String, dynamic> frame(Map<String, dynamic> extra) => {
      'type': 'git:sync-result',
      'id': 'm1',
      'timestamp': 0,
      'projectId': 'p1',
      ...extra,
    };

    test('folds a failure into the shape the handoff reads', () {
      final parsed = parseAbMessage(
        frame({
          'op': 'push',
          'success': false,
          'branch': 'main',
          'remote': 'origin',
          'remoteBranch': 'main',
          'error': 'rejected',
          'failureKind': 'not-fast-forward',
          'command': 'git push',
          'stderr': '! [rejected] main -> main (non-fast-forward)',
        }),
      );
      expect(parsed, isA<GitSyncResultMessage>());
      final failure = (parsed as GitSyncResultMessage).failure!;
      expect(failure.kind, GitSyncFailureKind.notFastForward);
      expect(failure.stderr, contains('non-fast-forward'));
      expect(failure.warrantsAgent, isTrue);
    });

    test('a success carries no failure', () {
      final parsed =
          parseAbMessage(frame({'op': 'pull', 'success': true, 'branch': 'main'}))
              as GitSyncResultMessage;
      expect(parsed.failure, isNull);
    });

    test('a null branch survives a detached HEAD result', () {
      final parsed =
          parseAbMessage(frame({'op': 'push', 'success': false, 'branch': null}))
              as GitSyncResultMessage;
      expect(parsed.branch, isNull);
      expect(parsed.failure!.kind, GitSyncFailureKind.unknown);
    });

    test('rejects a frame whose op it cannot attribute', () {
      // Clearing the wrong button is worse than clearing none: the wall-clock
      // latch still unsticks whichever one is spinning.
      expect(
        parseAbMessage(frame({'op': 'rebase', 'success': true, 'branch': 'x'})),
        isNull,
      );
    });
  });

  group('composeSyncFailureReport', () {
    const failure = GitSyncFailure(
      op: GitSyncOp.push,
      kind: GitSyncFailureKind.notFastForward,
      message: 'rejected',
      branch: 'main',
      remote: 'origin',
      remoteBranch: 'main',
      command: 'git push',
      stderr: '! [rejected] main -> main (non-fast-forward)\n'
          "error: failed to push some refs to 'origin'",
    );

    const sync = GitSyncState(
      branch: 'main',
      remote: 'origin',
      remoteBranch: 'main',
      ahead: 2,
      behind: 3,
      hasUpstream: true,
      hasRemote: true,
    );

    test('carries the command, the verbatim stderr and the counts', () {
      final report = composeSyncFailureReport(failure: failure, sync: sync);
      expect(report, contains('`git push` failed.'));
      expect(report, contains('non-fast-forward'));
      expect(report, contains("failed to push some refs to 'origin'"));
      expect(report, contains('2 ahead and 3 behind'));
      expect(report, contains('`origin/main`'));
    });

    test('tells the agent not to discard commits or force-push', () {
      // The load-bearing line: without it a helpful agent reaches for
      // `reset --hard` or `push --force` to make the error stop.
      final report = composeSyncFailureReport(failure: failure, sync: sync);
      expect(report, contains('without discarding my local commits'));
      expect(report, contains('without force-pushing'));
    });

    test('a diverged pull asks for reconciliation, not a discard', () {
      final report = composeSyncFailureReport(
        failure: const GitSyncFailure(
          op: GitSyncOp.pull,
          kind: GitSyncFailureKind.diverged,
          message: 'diverged',
          branch: 'main',
        ),
        sync: sync,
      );
      expect(report, contains('reconcile the two histories'));
      expect(report, contains('without discarding my local commits'));
    });

    test('an auth failure never invites the agent to store a secret', () {
      final report = composeSyncFailureReport(
        failure: const GitSyncFailure(
          op: GitSyncOp.push,
          kind: GitSyncFailureKind.auth,
          message: 'authentication failed',
          branch: 'main',
        ),
      );
      expect(report, contains('do not store any secret in the repo'));
    });

    test('falls back to the bridge message when there is no stderr', () {
      final report = composeSyncFailureReport(
        failure: const GitSyncFailure(
          op: GitSyncOp.push,
          kind: GitSyncFailureKind.ambiguousRemote,
          message: "'feature' has no upstream and this repository has 2 remotes",
          branch: 'feature',
        ),
      );
      expect(report, contains('has no upstream'));
      expect(report, contains('which remote this branch should track'));
    });

    test('counts the working tree, deduping a path listed on both sides', () {
      // A staged path edited again appears twice in the entry list; the report
      // must not claim two dirty files where there is one.
      final report = composeSyncFailureReport(
        failure: failure,
        sync: sync,
        changed: const [
          GitFileStatusEntry(path: 'a.dart', status: 'M', staged: true),
          GitFileStatusEntry(path: 'a.dart', status: 'M', staged: false),
          GitFileStatusEntry(path: 'new.dart', status: 'U', staged: false),
        ],
      );
      expect(report, contains('Working tree: 1 modified, 1 untracked.'));
    });

    test('omits the working-tree line when nothing has changed', () {
      final report = composeSyncFailureReport(failure: failure, sync: sync);
      expect(report, isNot(contains('Working tree:')));
    });
  });

  group('GitSyncFailure.warrantsAgent', () {
    test('is false for the states the user fixes in one tap', () {
      for (final kind in [
        GitSyncFailureKind.noRemote,
        GitSyncFailureKind.detached,
      ]) {
        expect(
          const GitSyncFailure(
            op: GitSyncOp.push,
            kind: GitSyncFailureKind.noRemote,
            message: 'x',
          ).copyKind(kind).warrantsAgent,
          isFalse,
          reason: kind.name,
        );
      }
    });

    test('is true for everything that needs judgement, unknown included', () {
      for (final kind in [
        GitSyncFailureKind.notFastForward,
        GitSyncFailureKind.diverged,
        GitSyncFailureKind.auth,
        GitSyncFailureKind.conflict,
        GitSyncFailureKind.dirtyTree,
        GitSyncFailureKind.ambiguousRemote,
        GitSyncFailureKind.unknown,
      ]) {
        expect(
          const GitSyncFailure(
            op: GitSyncOp.push,
            kind: GitSyncFailureKind.unknown,
            message: 'x',
          ).copyKind(kind).warrantsAgent,
          isTrue,
          reason: kind.name,
        );
      }
    });
  });
}

extension on GitSyncFailure {
  GitSyncFailure copyKind(GitSyncFailureKind kind) => GitSyncFailure(
    op: op,
    kind: kind,
    message: message,
    branch: branch,
    remote: remote,
    remoteBranch: remoteBranch,
    command: command,
    stderr: stderr,
  );
}
