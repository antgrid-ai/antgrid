import 'package:flutter_test/flutter_test.dart';

import 'package:antgrid/screens/app_shell.dart';
import 'package:antgrid/services/control_plane_client.dart' show AgentWorkStatus;

// Regression coverage for the bug where a session running on a LOCAL project
// the app hasn't opened this run never got a Recent/drawer row: the bridge
// correctly advertised it as "working" over `project:list`, but nothing ever
// re-peeked the project's cached SESSION LIST to learn the session existed at
// all. `shouldRepeekLocalSessions` is the pure trigger decision pulled out of
// `_ControlPlaneReaperState._pollLocalProjectStatus` for exactly this.
void main() {
  group('shouldRepeekLocalSessions', () {
    test('never-synced project always re-peeks, with nothing else known', () {
      expect(
        shouldRepeekLocalSessions(
          neverSynced: true,
          cachedSessionIds: const {},
          liveSessionIds: const {},
          hadStatus: false,
          prevStatus: null,
          newStatus: null,
        ),
        isTrue,
      );
    });

    test('a synced project whose cache already covers every live id does not re-peek', () {
      expect(
        shouldRepeekLocalSessions(
          neverSynced: false,
          cachedSessionIds: const {},
          liveSessionIds: const {},
          hadStatus: true,
          prevStatus: AgentWorkStatus.done,
          newStatus: AgentWorkStatus.done,
        ),
        isFalse,
      );
    });

    test(
      'a live session id missing from the cache re-peeks, even on the very '
      'first poll of a fresh process — the exact bug this exists to catch',
      () {
        // A project cached from an EARLIER app run (neverSynced: false), and a
        // session that was ALREADY working before this process even started —
        // so there is no "previous tick" to diff against (hadStatus: false).
        // Comparing against the cache directly (not the last poll) is what
        // still catches this on poll #1, instead of waiting for some later
        // change that may never come.
        expect(
          shouldRepeekLocalSessions(
            neverSynced: false,
            cachedSessionIds: const {},
            liveSessionIds: {'s1'},
            hadStatus: false,
            prevStatus: null,
            newStatus: AgentWorkStatus.working,
          ),
          isTrue,
        );
      },
    );

    test('a live session id already present in the cache does not re-peek on its own', () {
      expect(
        shouldRepeekLocalSessions(
          neverSynced: false,
          cachedSessionIds: {'s1'},
          liveSessionIds: {'s1'},
          hadStatus: true,
          prevStatus: AgentWorkStatus.working,
          newStatus: AgentWorkStatus.working,
        ),
        isFalse,
      );
    });

    test(
      'an unchanged, already-cached session with a plain working->done flip '
      'does not re-peek',
      () {
        // The row already exists — `remoteSessionStatusProvider` alone is
        // enough to move its dot; no session-list fetch is needed just
        // because the STATUS changed under an already-known, already-cached
        // id.
        expect(
          shouldRepeekLocalSessions(
            neverSynced: false,
            cachedSessionIds: {'s1'},
            liveSessionIds: {'s1'},
            hadStatus: true,
            prevStatus: AgentWorkStatus.working,
            newStatus: AgentWorkStatus.done,
          ),
          isFalse,
        );
      },
    );

    test(
      'a fresh flip to attention re-peeks even when every live id is already cached',
      () {
        // Mirrors the remote advert path's own statusFlipped trigger — kept
        // for parity even though the cache-coverage check alone already
        // covers most of what it exists for.
        expect(
          shouldRepeekLocalSessions(
            neverSynced: false,
            cachedSessionIds: {'s1'},
            liveSessionIds: {'s1'},
            hadStatus: true,
            prevStatus: AgentWorkStatus.working,
            newStatus: AgentWorkStatus.attention,
          ),
          isTrue,
        );
      },
    );

    test('a flip to error re-peeks even when every live id is already cached', () {
      expect(
        shouldRepeekLocalSessions(
          neverSynced: false,
          cachedSessionIds: {'s1'},
          liveSessionIds: {'s1'},
          hadStatus: true,
          prevStatus: AgentWorkStatus.working,
          newStatus: AgentWorkStatus.error,
        ),
        isTrue,
      );
    });

    test(
      'a flip TO attention on the very first poll (hadStatus false) is not '
      'itself a trigger when the cache already covers the live ids',
      () {
        // Nothing to compare the status against yet, so the statusFlipped
        // half stays inert here — but this case is never actually reached
        // unprotected in practice, because a live id absent from the cache
        // (the far more common shape of "first poll, unseen session") is
        // already caught by the cache-coverage check above it.
        expect(
          shouldRepeekLocalSessions(
            neverSynced: false,
            cachedSessionIds: {'s1'},
            liveSessionIds: {'s1'},
            hadStatus: false,
            prevStatus: null,
            newStatus: AgentWorkStatus.attention,
          ),
          isFalse,
        );
      },
    );

    test('a session exiting (no longer live) does not by itself re-peek', () {
      // Nothing missing from the cache — the cache is a superset of what's
      // live, which the coverage check is fine with. A stopped session is not
      // this trigger's concern; it still has a row, just not a running one.
      expect(
        shouldRepeekLocalSessions(
          neverSynced: false,
          cachedSessionIds: {'s1'},
          liveSessionIds: const {},
          hadStatus: true,
          prevStatus: AgentWorkStatus.working,
          newStatus: AgentWorkStatus.done,
        ),
        isFalse,
      );
    });
  });
}
