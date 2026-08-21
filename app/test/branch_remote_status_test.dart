import 'package:flutter_test/flutter_test.dart';
import 'package:antgrid/models/branch_remote_status.dart';
import 'package:antgrid/widgets/new_session/branch_remote_advisory.dart';

void main() {
  test('parses the wire shape the bridge sends', () {
    final s = BranchRemoteStatus.fromJson(const {
      'branch': 'main',
      'state': 'behind',
      'remote': 'origin',
      'remoteBranch': 'main',
      'behind': 3,
      'ahead': 0,
    });
    expect(s.state, BranchRemoteState.behind);
    expect(s.remoteRefLabel, 'origin/main');
    expect(s.behind, 3);
  });

  test(
    'an unrecognized state degrades to unreachable, which renders nothing',
    () {
      final s = BranchRemoteStatus.fromJson(const {
        'branch': 'main',
        'state': 'some-future-state',
      });
      expect(s.state, BranchRemoteState.unreachable);
      expect(s.isStaleBase, isFalse);
    },
  );

  test('only stale-base states warn', () {
    BranchRemoteStatus of(BranchRemoteState st) =>
        BranchRemoteStatus(branch: 'main', state: st);

    for (final st in [
      BranchRemoteState.behind,
      BranchRemoteState.diverged,
      BranchRemoteState.differs,
    ]) {
      expect(of(st).isStaleBase, isTrue, reason: '$st should warn');
    }
    // Ahead-only, gone, and every no-answer state are deliberately silent:
    // none of them means the session would start from a stale base.
    for (final st in [
      BranchRemoteState.ahead,
      BranchRemoteState.inSync,
      BranchRemoteState.gone,
      BranchRemoteState.noRemote,
      BranchRemoteState.noUpstream,
      BranchRemoteState.unreachable,
    ]) {
      expect(of(st).isStaleBase, isFalse, reason: '$st should stay silent');
    }
  });

  test('remoteRefLabel never renders a dangling slash', () {
    const s = BranchRemoteStatus(
      branch: 'main',
      state: BranchRemoteState.differs,
    );
    expect(s.remoteRefLabel, 'main');
  });

  test('copy pluralizes and omits counts it cannot know', () {
    expect(
      branchRemoteAdvisoryMessage(
        const BranchRemoteStatus(
          branch: 'main',
          state: BranchRemoteState.behind,
          remote: 'origin',
          remoteBranch: 'main',
          behind: 1,
        ),
      ),
      'main is 1 commit behind origin/main',
    );
    expect(
      branchRemoteAdvisoryMessage(
        const BranchRemoteStatus(
          branch: 'main',
          state: BranchRemoteState.behind,
          remote: 'origin',
          remoteBranch: 'main',
          behind: 3,
        ),
      ),
      'main is 3 commits behind origin/main',
    );
    expect(
      branchRemoteAdvisoryMessage(
        const BranchRemoteStatus(
          branch: 'main',
          state: BranchRemoteState.diverged,
          remote: 'origin',
          remoteBranch: 'main',
          behind: 2,
          ahead: 1,
        ),
      ),
      'main has diverged from origin/main — 2 behind, 1 ahead',
    );
    // No fetch, so no counts — and none are invented.
    final differs = branchRemoteAdvisoryMessage(
      const BranchRemoteStatus(
        branch: 'main',
        state: BranchRemoteState.differs,
        remote: 'origin',
        remoteBranch: 'main',
      ),
    );
    expect(differs, 'origin/main has commits that are not in main');
    expect(differs, isNot(contains('0')));
  });

  // The parser accepts whatever a newer/older bridge sends, so the copy has to
  // survive a state that arrives without its counts rather than print "0
  // commits behind" or the word "null" inside a warning.
  test('copy never invents a count the wire did not carry', () {
    expect(
      branchRemoteAdvisoryMessage(
        const BranchRemoteStatus(
          branch: 'main',
          state: BranchRemoteState.behind,
          remote: 'origin',
          remoteBranch: 'main',
        ),
      ),
      'origin/main has commits that are not in main',
    );
    final diverged = branchRemoteAdvisoryMessage(
      const BranchRemoteStatus(
        branch: 'main',
        state: BranchRemoteState.diverged,
        remote: 'origin',
        remoteBranch: 'main',
      ),
    );
    expect(diverged, 'main has diverged from origin/main');
    expect(diverged, isNot(contains('null')));
  });
}
