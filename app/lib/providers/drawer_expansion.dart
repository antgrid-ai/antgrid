import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../util/device_id.dart';

/// Ids the user has explicitly EXPANDED, for drawer rows whose default state is
/// COLLAPSED — remote MACHINE entries (keyed by bare deviceUuid) and the
/// advertised PROJECT sub-rows nested under them (keyed by the compound
/// `<uuid>.<projectId>` regId). This is the inverse of
/// [collapsedDrawerIdsProvider], which serves rows that default to EXPANDED
/// (local projects).
///
/// Kept in-memory (never persisted): a freshly-launched app must start with
/// every remote machine CLOSED so it doesn't open control-plane sockets the
/// user isn't looking at. Expanding a machine is the gesture that opens its
/// control-plane socket — `controlPlaneAliveTargetsProvider` unions these ids
/// (the bare-uuid machine ones) so the reaper keeps that socket alive while the
/// row stays open, and closes it again on collapse.
class ExpandedDrawerIdsNotifier extends Notifier<Set<String>> {
  @override
  Set<String> build() => const {};

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
class LocalMachineCollapsedNotifier extends Notifier<bool> {
  @override
  bool build() => false;

  void toggle() => state = !state;

  void set(bool collapsed) {
    if (state != collapsed) state = collapsed;
  }
}

/// Opens the drawer rows that hold the project the user is looking at: the
/// folded "This machine" band for a local project, or the remote machine and
/// its advertised project row for a remote one. A project already open in the
/// workspace is the one place the user is guaranteed to want its sessions in
/// view, so a fold left behind from earlier must not hide it.
///
/// A remote registration id is the compound `<uuid>.<projectId>`; a local one
/// never contains a dot.
void revealDrawerSelection(ProviderContainer ref, String registrationId) {
  if (registrationId.contains('.')) {
    final expanded = ref.read(expandedDrawerIdsProvider.notifier);
    expanded.expand(baseDeviceUuid(registrationId));
    expanded.expand(registrationId);
  } else {
    ref.read(localMachineCollapsedProvider.notifier).set(false);
  }
}

final localMachineCollapsedProvider =
    NotifierProvider<LocalMachineCollapsedNotifier, bool>(
      LocalMachineCollapsedNotifier.new,
    );

final expandedDrawerIdsProvider =
    NotifierProvider<ExpandedDrawerIdsNotifier, Set<String>>(
      ExpandedDrawerIdsNotifier.new,
    );
