import 'package:fake_async/fake_async.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:antgrid/project/mobile_lifecycle.dart';
import 'package:antgrid/project/project_session_registry.dart';

void main() {
  group('MobileLifecycleObserver', () {
    test('background → 30s → all warm evicted; focused kept', () {
      fakeAsync((async) {
        final evicted = <String>[];
        final registry = ProjectSessionRegistry(
          localCap: 100,
          relayCap: 100,
          onEvict: (id) async {
            evicted.add(id);
          },
        );
        registry.touch('a', isLocal: true);
        registry.touch('b', isLocal: true);
        registry.touch('c', isLocal: true);

        final lifecycle = MobileLifecycleObserver(
          registry: registry,
          focusedProjectId: () => 'b',
          backgroundDemoteDelay: const Duration(seconds: 30),
        );
        lifecycle.handleState(AppLifecycleState.paused);
        async.elapse(const Duration(seconds: 29));
        expect(evicted, isEmpty);
        async.elapse(const Duration(seconds: 2));
        async.flushMicrotasks();
        expect(evicted, containsAll(<String>['a', 'c']));
        expect(evicted, isNot(contains('b')));
        expect(registry.openProjects, ['b']);
        lifecycle.dispose();
      });
    });

    test('resume before 30s cancels the demote', () {
      fakeAsync((async) {
        final evicted = <String>[];
        final registry = ProjectSessionRegistry(
          localCap: 100,
          relayCap: 100,
          onEvict: (id) async {
            evicted.add(id);
          },
        );
        registry.touch('a', isLocal: true);
        final lifecycle = MobileLifecycleObserver(
          registry: registry,
          focusedProjectId: () => null,
          backgroundDemoteDelay: const Duration(seconds: 30),
        );
        lifecycle.handleState(AppLifecycleState.paused);
        async.elapse(const Duration(seconds: 5));
        lifecycle.handleState(AppLifecycleState.resumed);
        async.elapse(const Duration(seconds: 60));
        async.flushMicrotasks();
        expect(evicted, isEmpty);
        expect(registry.openProjects, ['a']);
        lifecycle.dispose();
      });
    });

    test('hidden state also schedules demote', () {
      fakeAsync((async) {
        final evicted = <String>[];
        final registry = ProjectSessionRegistry(
          localCap: 100,
          relayCap: 100,
          onEvict: (id) async {
            evicted.add(id);
          },
        );
        registry.touch('a', isLocal: true);
        final lifecycle = MobileLifecycleObserver(
          registry: registry,
          focusedProjectId: () => null,
          backgroundDemoteDelay: const Duration(seconds: 30),
        );
        lifecycle.handleState(AppLifecycleState.hidden);
        async.elapse(const Duration(seconds: 31));
        async.flushMicrotasks();
        expect(evicted, ['a']);
        lifecycle.dispose();
      });
    });

    test('dispose cancels pending timer', () {
      fakeAsync((async) {
        final evicted = <String>[];
        final registry = ProjectSessionRegistry(
          localCap: 100,
          relayCap: 100,
          onEvict: (id) async {
            evicted.add(id);
          },
        );
        registry.touch('a', isLocal: true);
        final lifecycle = MobileLifecycleObserver(
          registry: registry,
          focusedProjectId: () => null,
          backgroundDemoteDelay: const Duration(seconds: 30),
        );
        lifecycle.handleState(AppLifecycleState.paused);
        async.elapse(const Duration(seconds: 5));
        lifecycle.dispose();
        async.elapse(const Duration(seconds: 60));
        expect(evicted, isEmpty);
      });
    });
  });
}
