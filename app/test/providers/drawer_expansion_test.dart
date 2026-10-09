// Focusing a project must leave the session on screen with a visible row in
// the drawer: its machine and project rows open, and a folded "This machine"
// band unfolds. These pin that, and that nothing opens without a focus — a
// remote machine's row is what keeps its control-plane socket alive.
import 'package:antgrid/models/session_target.dart';
import 'package:antgrid/providers/agent_transport.dart';
import 'package:antgrid/providers/collapsed_drawer.dart';
import 'package:antgrid/providers/drawer_expansion.dart';
import 'package:antgrid/storage/drawer_collapsed_store.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import '../helpers/prefs_test_mock.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  ProviderContainer makeContainer() {
    final c = ProviderContainer();
    addTearDown(c.dispose);
    return c;
  }

  test('nothing is expanded without a focus', () {
    final c = makeContainer();
    expect(c.read(expandedDrawerIdsProvider), isEmpty);
  });

  test('focusing a remote project opens its machine and project rows', () {
    final c = makeContainer();
    c.read(expandedDrawerIdsProvider);

    c
        .read(selectedTargetProvider.notifier)
        .set(const RemoteProject(machineUuid: 'm1', projectId: 'p1'));

    expect(c.read(expandedDrawerIdsProvider), {'m1', 'm1.p1'});
  });

  test('a remote project focused before the drawer reads is open at once', () {
    final c = makeContainer();
    c
        .read(selectedTargetProvider.notifier)
        .set(const RemoteProject(machineUuid: 'm1', projectId: 'p1'));

    expect(c.read(expandedDrawerIdsProvider), {'m1', 'm1.p1'});
  });

  test('focus adds to what the user opened, never closes it', () {
    final c = makeContainer();
    c.read(expandedDrawerIdsProvider.notifier).expand('m2');

    c
        .read(selectedTargetProvider.notifier)
        .set(const RemoteProject(machineUuid: 'm1', projectId: 'p1'));

    expect(c.read(expandedDrawerIdsProvider), {'m2', 'm1', 'm1.p1'});
  });

  test('focusing a local project opens no remote row', () {
    final c = makeContainer();
    c.read(expandedDrawerIdsProvider);

    c.read(selectedTargetProvider.notifier).set(const LocalProject('p1'));

    expect(c.read(expandedDrawerIdsProvider), isEmpty);
  });

  // The band's fold lives in the persisted collapsed set, so these need a store.
  Future<ProviderContainer> makeBandContainer() async {
    useInMemoryPrefs();
    final store = await DrawerCollapsedStore.open();
    final c = ProviderContainer(
      overrides: [drawerCollapsedStoreProvider.overrideWithValue(store)],
    );
    addTearDown(c.dispose);
    // The drawer watches the band; without a listener Riverpod pauses the
    // provider and its focus listener never fires.
    c.listen(localMachineCollapsedProvider, (_, _) {});
    return c;
  }

  void foldBand(ProviderContainer c) =>
      c.read(collapsedDrawerIdsProvider.notifier).toggle(kLocalMachineDrawerId);

  test('focusing a local project unfolds the This machine band', () async {
    final c = await makeBandContainer();
    foldBand(c);
    expect(c.read(localMachineCollapsedProvider), isTrue);

    c.read(selectedTargetProvider.notifier).set(const LocalProject('p1'));
    // The focus reaches the band's listener on Riverpod's next flush.
    await Future<void>.delayed(Duration.zero);

    expect(c.read(localMachineCollapsedProvider), isFalse);
  });

  test(
    'focusing a remote project leaves the This machine band folded',
    () async {
      final c = await makeBandContainer();
      foldBand(c);
      expect(c.read(localMachineCollapsedProvider), isTrue);

      c
          .read(selectedTargetProvider.notifier)
          .set(const RemoteProject(machineUuid: 'm1', projectId: 'p1'));
      await Future<void>.delayed(Duration.zero);

      expect(c.read(localMachineCollapsedProvider), isTrue);
    },
  );
}
