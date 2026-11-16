// A branch read made while the local host is still starting must not show as
// "Branches unavailable": seen on a first launch, where the picker said so for
// a git repo and corrected itself seconds later.
import 'package:antgrid/providers/control_plane.dart';
import 'package:antgrid/providers/host_status.dart';
import 'package:antgrid/providers/new_session_picker.dart';
import 'package:antgrid/providers/provider_retry.dart';
import 'package:antgrid/providers/value_controller.dart';
import 'package:antgrid/widgets/new_session/picker_sources.dart';
import 'package:fake_async/fake_async.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

const _local = PickerProject(
  id: 'p1',
  name: 'Project 1',
  detail: '/path/p1',
  isLocal: true,
);

// As the app's root container is: Riverpod's own retry would otherwise rebuild
// the catalog behind the grace being measured.
ProviderContainer _container({required int? hostUp}) => ProviderContainer(
  retry: noProviderRetry,
  overrides: [
    selectedTargetProjectProvider.overrideWith(() => ValueController(_local)),
    hostUpGenerationProvider.overrideWithBuild((_, _) => hostUp),
    hostControllerProvider.overrideWith(
      (_) => throw StateError('host not started'),
    ),
  ],
);

void main() {
  test('a failure before the host first comes up reads as loading, then as '
      'the failure once the grace runs out', () {
    fakeAsync((async) {
      final container = _container(hostUp: null);
      final sub = container.listen(newSessionBranchCatalogProvider, (_, _) {});
      async.flushMicrotasks();

      expect(sub.read().isLoading, isTrue);
      expect(sub.read().hasError, isFalse);

      async.elapse(kHostWarmupGrace);
      expect(sub.read().hasError, isTrue);

      sub.close();
      container.dispose();
    });
  });

  test('a failure once the host has been up shows at once', () {
    fakeAsync((async) {
      final container = _container(hostUp: 1);
      final sub = container.listen(newSessionBranchCatalogProvider, (_, _) {});
      async.flushMicrotasks();

      expect(sub.read().hasError, isTrue);

      sub.close();
      container.dispose();
    });
  });
}
