import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../design/ab_icons.dart';
import '../design/widgets/ab_menu.dart';
import '../models/session_entry.dart';
import '../models/session_target.dart';
import '../providers/agent_transport.dart';
import '../providers/demo_mode.dart';
import '../providers/session_members.dart';
import '../providers/sessions.dart';
import '../util/detached.dart';
import 'add_machine_dialog.dart';
import 'session_member_remove_flow.dart';

/// Which membership action the session on screen can offer, and against which
/// row — the whole of the kebab's membership section, derived in one place so
/// the mobile and desktop menus can never offer different items for the same
/// session.
@immutable
class SessionMembershipActions {
  const SessionMembershipActions({this.add, this.atCap = false, this.remove});

  /// The lead this machine may join another machine to, or null when the
  /// session on screen cannot take one.
  final ({String registrationId, String sessionId})? add;

  /// [add] is offered but disabled: the session already holds
  /// [kMaxSessionMembers] machines. Kept reachable rather than hidden, so the
  /// cap explains itself instead of the item silently disappearing.
  final bool atCap;

  /// The peer whose tab the user is standing on, addressed together with the
  /// lead that has to record its release.
  final ({SessionMemberRef peer, String leadRegistrationId, String leadSessionId})?
  remove;

  bool get isEmpty => add == null && remove == null;
}

/// The membership actions for the focused session.
///
/// Add is offered only from the LEAD's own tab and only while that lead is a
/// project on THIS machine: the desktop app carrying the session bus is the one
/// running the lead (D7), so a lead the user is merely watching from another
/// machine has no carrier here to add to it.
///
/// Remove is offered only from a PEER's tab — `selected` is null on the lead's
/// own, which is what makes "remove the row I am looking at" the only removal
/// the menu can express, rather than a submenu of every member.
final sessionMembershipActionsProvider = Provider<SessionMembershipActions>((
  ref,
) {
  // The sample project has no second machine and must never dial one.
  if (ref.watch(demoModeProvider)) return const SessionMembershipActions();
  final session = ref.watch(activeSessionOrCachedProvider);
  if (session == null) return const SessionMembershipActions();

  final view = ref.watch(memberViewProvider);
  final selected = view?.selected;
  if (selected != null && view != null) {
    return SessionMembershipActions(
      remove: (
        peer: selected,
        leadRegistrationId: view.leadRegistrationId,
        leadSessionId: view.leadSessionId,
      ),
    );
  }

  // A row that is itself a member leads nothing, even on its own tab.
  if (session.memberOf != null) return const SessionMembershipActions();
  final registrationId = ref.watch(selectedRegistrationIdProvider);
  if (registrationId == null) return const SessionMembershipActions();
  if (ref.watch(selectedTargetProvider) is! LocalProject) {
    return const SessionMembershipActions();
  }
  final active = session.members.where((m) => m.isActive).length;
  return SessionMembershipActions(
    add: (registrationId: registrationId, sessionId: session.id),
    atCap: active >= kMaxSessionMembers,
  );
});

/// The kebab's membership rows, shared by the mobile overflow menu and the
/// desktop agent bar's own kebab so both surfaces stay one implementation.
///
/// Renders nothing at all for a session with neither action, which is what lets
/// the desktop kebab hide itself entirely rather than open onto an empty popup.
class SessionMembershipMenuItems extends ConsumerWidget {
  const SessionMembershipMenuItems({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final actions = ref.watch(sessionMembershipActionsProvider);
    if (actions.isEmpty) return const SizedBox.shrink();

    final add = actions.add;
    final remove = actions.remove;
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (add != null)
          AbLiveMenuRow(
            label: 'Add machine',
            icon: AbIcons.sessionMemberOf,
            enabled: !actions.atCap,
            disabledReason:
                'This session already works with as many machines as it can '
                'hold.',
            onTap: () => _run(
              context,
              ref,
              (host, _) => promptAddMachine(
                host,
                leadRegistrationId: add.registrationId,
                leadSessionId: add.sessionId,
              ),
            ),
          ),
        if (remove != null)
          AbLiveMenuRow(
            label: 'Remove from session',
            icon: AbIcons.trash,
            onTap: () => _run(
              context,
              ref,
              (host, container) => confirmAndRemoveMember(
                host,
                container,
                leadRegistrationId: remove.leadRegistrationId,
                leadSessionId: remove.leadSessionId,
                peer: remove.peer,
              ),
            ),
          ),
      ],
    );
  }

  /// Closes the popup, then acts from surfaces that outlive it — same contract
  /// as the Handler row beside these: the popup content pops itself, and a
  /// dialog opened under a live menu route lands behind its barrier.
  void _run(
    BuildContext context,
    WidgetRef ref,
    Future<void> Function(BuildContext host, ProviderContainer container) act,
  ) {
    final navigator = Navigator.of(context);
    final host = navigator.context;
    final container = ref.container;
    navigator.pop();
    detached(
      'SessionMembership',
      'membership menu action failed',
      () => act(host, container),
    );
  }
}
