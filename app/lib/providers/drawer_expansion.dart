import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../util/device_id.dart';
import 'agent_transport.dart';

/// Ids the user has explicitly EXPANDED, for drawer rows whose default state is
/// COLLAPSED — remote MACHINE entries (keyed by bare deviceUuid) and the
/// advertised PROJECT sub-rows nested under them (keyed by the compound
/// `<uuid>.<projectId>` regId). This is the inverse of
/// [collapsedDrawerIdsProvider], which serves rows that default to EXPANDED
/// (local projects).
///
/// Kept in-memory (never persisted): a freshly-launched app must start with
/// every remote machine CLOSED — except the focused project's, which is already
/// connected — so it doesn't open control-plane sockets the user isn't looking
/// at. Expanding a machine is the gesture that opens its
/// control-plane socket — `controlPlaneAliveTargetsProvider` unions these ids
/// (the bare-uuid machine ones) so the reaper keeps that socket alive while the
/// row stays open, and closes it again on collapse.
class ExpandedDrawerIdsNotifier extends Notifier<Set<String>> {
  @override
  Set<String> build() {
    // Focusing a remote project is a strong "show me this" signal, so its
    // machine and project rows open to reveal the session on screen. Seeded by
    // a one-shot read and listened to WITHOUT fireImmediately: a listener that
    // fires during build() would write `state` mid-build, which throws.
    ref.listen<String?>(selectedRegistrationIdProvider, (_, next) {
      if (next != null) _expandForFocus(next);
    });
    final focused = ref.read(selectedRegistrationIdProvider);
    return focused == null ? const {} : _withFocus(const {}, focused);
  }

  /// Compound `<uuid>.<projectId>` ids are remote; a bare id is a local project
  /// whose expansion [collapsedDrawerIdsProvider] already forces on selection.
  static Set<String> _withFocus(Set<String> ids, String regId) {
    final machine = baseDeviceUuid(regId);
    if (machine == regId) return ids;
    return {...ids, machine, regId};
  }

  void _expandForFocus(String regId) {
    final next = _withFocus(state, regId);
    if (next.length != state.length) state = next;
  }

  /// Flips [id] between expanded and collapsed.
  void toggle(String id) => state.contains(id) ? collapse(id) : expand(id);

  void expand(String id) {
    if (state.contains(id)) return;
    state = {...state, id};
  }

  void collapse(String id) {
    if (!state.contains(id)) return;
    state = {...state}..remove(id);
  }
}

/// Whether the "This machine" band has folded its local projects away.
///
/// In-memory and default-open, unlike the remote machines: collapsing here
/// hides rows that are already listed rather than gating a socket, so there is
/// nothing to protect on launch and a persisted fold would only hide the user's
/// own projects from them on the next start.
///
/// Focusing a local project unfolds it, for the same reason the remote rows
/// open on focus: the session on screen must have a row the user can see.
class LocalMachineCollapsedNotifier extends Notifier<bool> {
  @override
  bool build() {
    // Not fireImmediately: the band starts open anyway, and writing `state`
    // from inside build() throws.
    ref.listen<String?>(selectedRegistrationIdProvider, (_, next) {
      if (next != null && baseDeviceUuid(next) == next) state = false;
    });
    return false;
  }

  void toggle() => state = !state;
}

final localMachineCollapsedProvider =
    NotifierProvider<LocalMachineCollapsedNotifier, bool>(
      LocalMachineCollapsedNotifier.new,
    );

final expandedDrawerIdsProvider =
    NotifierProvider<ExpandedDrawerIdsNotifier, Set<String>>(
      ExpandedDrawerIdsNotifier.new,
    );
