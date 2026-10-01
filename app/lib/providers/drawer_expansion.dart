import 'package:flutter_riverpod/flutter_riverpod.dart';

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
}

final localMachineCollapsedProvider =
    NotifierProvider<LocalMachineCollapsedNotifier, bool>(
      LocalMachineCollapsedNotifier.new,
    );

final expandedDrawerIdsProvider =
    NotifierProvider<ExpandedDrawerIdsNotifier, Set<String>>(
      ExpandedDrawerIdsNotifier.new,
    );
