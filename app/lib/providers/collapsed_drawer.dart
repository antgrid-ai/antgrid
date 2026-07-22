import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../storage/drawer_collapsed_store.dart';
import 'agent_transport.dart';

/// Synchronous handle to the on-disk collapsed-ids store. Opened eagerly in
/// `main()` and injected via a Riverpod override; reading without the override
/// throws. Mirrors `drawerOrderStoreProvider`.
final drawerCollapsedStoreProvider = Provider<DrawerCollapsedStore>((_) {
  throw StateError('drawerCollapsedStoreProvider must be overridden in main()');
});

/// Exposes the set of drawer entry ids that should render COLLAPSED. The drawer
/// expands every project by default, so an id absent from the emitted set is
/// expanded. Consumers read this set and treat "not present" as expanded.
///
/// Two distinct inputs feed the emitted set, and keeping them separate is the
/// whole point of this class:
///
///  - [_collapsed] — the persisted truth: ids the user explicitly collapsed.
///    Only the explicit gestures ([collapse]/[expand], via [toggle]) mutate it,
///    and only it is ever written to disk.
///  - [_selected] — the active project, force-expanded in the *view only*.
///    Selecting a project is a strong "show me this" signal, so the active
///    project is shown expanded regardless of its stored collapse. This overlay
///    is transient and NEVER persisted.
///
/// The emitted state is `_collapsed` minus the active selection. Deriving it
/// this way (rather than mutating one shared set) is load-bearing:
///
///  1. The select listener fires `fireImmediately` at launch with the restored
///     active project. If selection mutated the persisted set, every launch
///     would erase that project's stored collapse. More subtly, even after
///     launch, a *later* persist of a mutated shared set (e.g. collapsing some
///     other row) would bake the selection-expand into disk and drop the active
///     project's collapse. Keeping `_collapsed` pristine closes both holes.
///  2. Because only one project is "active" at a time, moving the selection
///     elsewhere makes the previous project's stored collapse reassert
///     automatically — the overlay is a single slot, not an accumulating set.
class CollapsedDrawerIdsNotifier extends Notifier<Set<String>> {
  late final DrawerCollapsedStore _store;

  /// Persisted truth — the only thing [_persist] ever writes.
  late Set<String> _collapsed;

  /// Active selection, force-expanded in the view only. Null when nothing is
  /// selected; holds at most one id (the active project).
  String? _selected;

  @override
  Set<String> build() {
    _store = ref.watch(drawerCollapsedStoreProvider);
    _collapsed = Set.unmodifiable(_store.read());
    // Seed the selection overlay with a ONE-SHOT read, then listen WITHOUT
    // fireImmediately. A fireImmediately listener fires synchronously during
    // build(); its callback (expandForSelection → _emit) writes `state`, which
    // is illegal mid-build and throws. Later selection changes fire the listener
    // and update state through expandForSelection as normal.
    _selected = ref.read(selectedRegistrationIdProvider);
    ref.listen<String?>(selectedRegistrationIdProvider, (_, next) {
      if (next != null) {
        expandForSelection(next);
      } else if (_selected != null) {
        // Deselection (project closed / sign-out) is "moving the selection
        // elsewhere" too: drop the single-slot overlay so the previously active
        // project's stored collapse reasserts instead of staying force-expanded.
        _selected = null;
        _emit();
      }
    });
    // Return the EMITTED state (persisted collapses minus the active selection),
    // not bare _collapsed. Returning _collapsed would drop the first-frame
    // force-expand of the restored active project — the whole point of the
    // overlay. This mirrors _emit()'s computation without writing state.
    final sel = _selected;
    return sel == null
        ? _collapsed
        : Set.unmodifiable({..._collapsed}..remove(sel));
  }

  // Emitted state = persisted collapses minus the active-selection overlay.
  // _collapsed is always unmodifiable, so the sel == null path can hand it out
  // directly without re-wrapping.
  void _emit() {
    final sel = _selected;
    state = sel == null
        ? _collapsed
        : Set.unmodifiable({..._collapsed}..remove(sel));
  }

  void collapse(String id) {
    // An explicit collapse overrides the transient select-expand for this id,
    // so the collapse takes visible effect even on the active project.
    if (_selected == id) _selected = null;
    if (_collapsed.contains(id)) {
      _emit();
      return;
    }
    _collapsed = Set.unmodifiable({..._collapsed, id});
    _persist();
    _emit();
  }

  void expand(String id) {
    if (!_collapsed.contains(id)) return;
    _collapsed = Set.unmodifiable({..._collapsed}..remove(id));
    _persist();
    _emit();
  }

  /// Flips the *visible* collapsed state of [id]. Reads the emitted state (not
  /// [_collapsed]) so a tap on the force-expanded active project collapses it.
  void toggle(String id) => state.contains(id) ? expand(id) : collapse(id);

  /// In-memory force-expand for the select side-effect: marks [id] as the active
  /// selection so it renders expanded, WITHOUT persisting (see class doc).
  void expandForSelection(String id) {
    if (_selected == id) return;
    _selected = id;
    _emit();
  }

  // Fire-and-forget, matching DrawerOrderNotifier: in-memory state updates
  // synchronously, the SharedPreferences write is best-effort.
  void _persist() => unawaited(_store.write(_collapsed));
}

final collapsedDrawerIdsProvider =
    NotifierProvider<CollapsedDrawerIdsNotifier, Set<String>>(
      CollapsedDrawerIdsNotifier.new,
    );
