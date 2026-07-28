import 'package:flutter_test/flutter_test.dart';
import 'package:antgrid/project/project_session_registry.dart';

void main() {
  test('relay overflow evicts a relay project, never a local one', () {
    final evicted = <String>[];
    final reg = ProjectSessionRegistry(
      localCap: 2,
      relayCap: 2,
      onEvict: (id) async => evicted.add(id),
    );
    reg.touch('localA', isLocal: true);
    reg.touch('localB', isLocal: true);
    reg.touch('M.r1', isLocal: false);
    reg.touch('M.r2', isLocal: false);
    reg.touch('M.r3', isLocal: false); // relay bucket overflows (cap 2)
    expect(evicted, ['M.r1']); // oldest RELAY victim
    expect(
      reg.openProjects,
      containsAll(['localA', 'localB']),
    ); // locals untouched
  });

  test('local overflow evicts a local project, never a relay one', () {
    final evicted = <String>[];
    final reg = ProjectSessionRegistry(
      localCap: 2,
      relayCap: 2,
      onEvict: (id) async => evicted.add(id),
    );
    reg.touch('M.r1', isLocal: false);
    reg.touch('M.r2', isLocal: false);
    reg.touch('localA', isLocal: true);
    reg.touch('localB', isLocal: true);
    reg.touch('localC', isLocal: true); // local bucket overflows (cap 2)
    expect(evicted, ['localA']); // oldest LOCAL victim
    expect(reg.openProjects, containsAll(['M.r1', 'M.r2'])); // relay untouched
  });

  test('localOpenProjects follows the isLocal flag, not the id shape', () {
    final reg = ProjectSessionRegistry(
      localCap: 4,
      relayCap: 4,
      onEvict: (id) async {},
    );
    reg.touch('localA', isLocal: true);
    reg.touch('M.r1', isLocal: false);
    // A bare machine uuid is dot-free but names a REMOTE control-plane
    // session — a local-host respawn must not tear it down.
    reg.touch('96352d71-dc6f-4479-904b-79cd7a5b5bab', isLocal: false);
    expect(reg.localOpenProjects(), ['localA']);
  });

  test('forceEvictAndSettle awaits the onEvict callback before returning', () {
    // The delete paths purge a project's status-cache file right after evicting
    // it, but `onEvict` WRITES that file (final-status snapshot). If the evict
    // were fire-and-forget the purge could run before the write lands and the
    // stale file would survive. `forceEvictAndSettle` must await the callback so
    // write-then-purge is deterministic.
    var writeDone = false;
    final reg = ProjectSessionRegistry(
      localCap: 2,
      relayCap: 2,
      onEvict: (id) async {
        await Future<void>.delayed(const Duration(milliseconds: 10));
        writeDone = true;
      },
    );
    reg.touch('localA', isLocal: true);

    final future = reg.forceEvictAndSettle('localA');
    // Not yet: the callback's async work hasn't completed.
    expect(writeDone, isFalse);
    return future.then((_) {
      expect(writeDone, isTrue);
      expect(reg.openProjects, isEmpty);
    });
  });

  test(
    'forceEvictAndSettle is a no-op (no callback) for an unknown id',
    () async {
      var fired = false;
      final reg = ProjectSessionRegistry(
        localCap: 2,
        relayCap: 2,
        onEvict: (id) async => fired = true,
      );
      await reg.forceEvictAndSettle('never-opened');
      expect(fired, isFalse);
    },
  );

  test(
    'forceEvict swallows an onEvict failure (no unhandled async error)',
    () async {
      // forceEvict is fire-and-forget. If it let onEvict's future error go
      // unobserved, flutter_test would report it as an unhandled async error
      // and fail this test. It must share forceEvictAndSettle's swallow so the
      // two paths can't drift in error handling.
      final reg = ProjectSessionRegistry(
        localCap: 2,
        relayCap: 2,
        onEvict: (id) async => throw StateError('status write failed'),
      );
      reg.touch('localA', isLocal: true);

      reg.forceEvict('localA');
      // Let the onEvict microtask run so any unobserved error would surface.
      await Future<void>.delayed(Duration.zero);

      expect(reg.openProjects, isEmpty);
    },
  );

  test(
    'forceEvictAndSettle swallows an onEvict failure and still evicts the project',
    () async {
      // onEvict does best-effort status I/O (a file write that can throw on a
      // full/locked disk). A failure there must not propagate and abort the
      // caller's removal — the fire-and-forget forceEvict never could.
      final reg = ProjectSessionRegistry(
        localCap: 2,
        relayCap: 2,
        onEvict: (id) async => throw StateError('status write failed'),
      );
      reg.touch('localA', isLocal: true);

      await reg.forceEvictAndSettle('localA'); // must NOT throw

      expect(reg.openProjects, isEmpty);
    },
  );
}
