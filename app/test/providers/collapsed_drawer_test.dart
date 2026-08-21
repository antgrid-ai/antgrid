import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:antgrid/models/session_target.dart';
import 'package:antgrid/providers/agent_transport.dart';
import 'package:antgrid/providers/collapsed_drawer.dart';
import 'package:antgrid/storage/drawer_collapsed_store.dart';
import '../helpers/prefs_test_mock.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() => useInMemoryPrefs());

  Future<ProviderContainer> makeContainer() async {
    final store = await DrawerCollapsedStore.open();
    return ProviderContainer(
      overrides: [drawerCollapsedStoreProvider.overrideWithValue(store)],
    );
  }

  test('defaults to an empty collapsed set (everything expanded)', () async {
    final c = await makeContainer();
    addTearDown(c.dispose);
    expect(c.read(collapsedDrawerIdsProvider), isEmpty);
  });

  test('collapse adds an id; expand removes it', () async {
    final c = await makeContainer();
    addTearDown(c.dispose);
    final n = c.read(collapsedDrawerIdsProvider.notifier);

    n.collapse('proj-a');
    expect(c.read(collapsedDrawerIdsProvider), {'proj-a'});

    n.expand('proj-a');
    expect(c.read(collapsedDrawerIdsProvider), isEmpty);
  });

  test('toggle flips collapsed state', () async {
    final c = await makeContainer();
    addTearDown(c.dispose);
    final n = c.read(collapsedDrawerIdsProvider.notifier);

    n.toggle('proj-a');
    expect(c.read(collapsedDrawerIdsProvider), {'proj-a'});
    n.toggle('proj-a');
    expect(c.read(collapsedDrawerIdsProvider), isEmpty);
  });

  test('collapse is idempotent; expand is a no-op when absent', () async {
    final c = await makeContainer();
    addTearDown(c.dispose);
    final n = c.read(collapsedDrawerIdsProvider.notifier);

    n.collapse('proj-a');
    n.collapse('proj-a');
    expect(c.read(collapsedDrawerIdsProvider), {'proj-a'});

    n.expand('proj-a');
    n.expand('proj-a');
    expect(c.read(collapsedDrawerIdsProvider), isEmpty);
  });

  test('mutation emits a new immutable set', () async {
    final c = await makeContainer();
    addTearDown(c.dispose);
    final n = c.read(collapsedDrawerIdsProvider.notifier);

    final before = n.state;
    n.collapse('proj-a');
    expect(identical(before, n.state), isFalse);
    expect(() => n.state.add('proj-b'), throwsUnsupportedError);
  });

  test('mutations persist to the store', () async {
    final store = await DrawerCollapsedStore.open();
    final c = ProviderContainer(
      overrides: [drawerCollapsedStoreProvider.overrideWithValue(store)],
    );
    addTearDown(c.dispose);

    c.read(collapsedDrawerIdsProvider.notifier).collapse('proj-a');
    // Persistence is fire-and-forget; let the microtask settle.
    await Future<void>.delayed(Duration.zero);
    expect(store.read(), {'proj-a'});
  });

  test('selecting a project expands it in-memory WITHOUT erasing the stored '
      'collapse', () async {
    final store = await DrawerCollapsedStore.open();
    await store.write({'proj-a'});
    final c = ProviderContainer(
      overrides: [drawerCollapsedStoreProvider.overrideWithValue(store)],
    );
    addTearDown(c.dispose);

    // Seed the notifier with the persisted collapse, then select that project.
    expect(c.read(collapsedDrawerIdsProvider), {'proj-a'});
    c.read(selectedTargetProvider.notifier).set(const LocalProject('proj-a'));
    // In-memory state shows expanded...
    expect(c.read(collapsedDrawerIdsProvider), isEmpty);
    // ...but the on-disk collapse is preserved (the select side-effect is
    // transient — only explicit collapse/expand gestures write to the store).
    await Future<void>.delayed(Duration.zero);
    expect(store.read(), {'proj-a'});
  });

  test('a persisting gesture after a select preserves the selected '
      "project's stored collapse", () async {
    final store = await DrawerCollapsedStore.open();
    await store.write({'proj-a'});
    final c = ProviderContainer(
      overrides: [drawerCollapsedStoreProvider.overrideWithValue(store)],
    );
    addTearDown(c.dispose);

    // proj-a is the active selection, so it renders expanded in-memory.
    c.read(selectedTargetProvider.notifier).set(const LocalProject('proj-a'));
    expect(c.read(collapsedDrawerIdsProvider), isEmpty);

    // Collapsing an UNRELATED project triggers a persist. It must write the
    // canonical set, NOT the selection-mutated view — proj-a's stored collapse
    // must survive.
    c.read(collapsedDrawerIdsProvider.notifier).collapse('proj-c');
    await Future<void>.delayed(Duration.zero);
    expect(store.read(), {'proj-a', 'proj-c'});
  });

  test(
    "moving the selection reasserts the previous project's collapse",
    () async {
      final store = await DrawerCollapsedStore.open();
      await store.write({'proj-a', 'proj-b'});
      final c = ProviderContainer(
        overrides: [drawerCollapsedStoreProvider.overrideWithValue(store)],
      );
      addTearDown(c.dispose);
      final sel = c.read(selectedTargetProvider.notifier);

      sel.set(const LocalProject('proj-a'));
      // proj-a force-expanded; proj-b still collapsed.
      expect(c.read(collapsedDrawerIdsProvider), {'proj-b'});

      sel.set(const LocalProject('proj-b'));
      // Selection moved on: proj-a's stored collapse reasserts, proj-b expands.
      expect(c.read(collapsedDrawerIdsProvider), {'proj-a'});
    },
  );

  test(
    "deselecting (selection -> null) reasserts the previous project's collapse",
    () async {
      final store = await DrawerCollapsedStore.open();
      await store.write({'proj-a'});
      final c = ProviderContainer(
        overrides: [drawerCollapsedStoreProvider.overrideWithValue(store)],
      );
      addTearDown(c.dispose);
      final sel = c.read(selectedTargetProvider.notifier);

      sel.set(const LocalProject('proj-a'));
      // proj-a is force-expanded while selected.
      expect(c.read(collapsedDrawerIdsProvider), isEmpty);

      sel.set(null);
      // Deselection drops the overlay: proj-a's stored collapse reasserts
      // instead of staying force-expanded.
      expect(c.read(collapsedDrawerIdsProvider), {'proj-a'});
    },
  );
}
