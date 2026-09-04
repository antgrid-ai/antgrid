import 'package:flutter/widgets.dart';

import '../design/ab_colors.dart';
import '../design/ab_icons.dart';
import '../design/ab_tokens.dart';
import '../design/widgets/ab_icon.dart';
import '../design/widgets/ab_tooltip.dart';
import '../models/session_entry.dart';

/// The one marker that says this session is not working alone — it is a member
/// of a session led on another machine.
///
/// Renders nothing for a session that leads itself, so every call site mounts it
/// unconditionally and none of them re-derives what membership means. It reads
/// only the row it is handed and never the wire, so it is safe on any surface
/// that names a session — including one served from the persisted session
/// cache, which is the common case for a peer, whose lead lives on a machine
/// this app may not be connected to at all.
///
/// Paired with `SessionSharedWorkspaceBadge`, which answers a different
/// question: that one is company inside ONE directory on this machine, this one
/// is a session spanning machines. Both can show, and neither restates the
/// other.
///
/// A glyph rather than the machine's name, matching its siblings: this sits
/// beside a session NAME in rows that are already tight. The tooltip — hover on
/// a pointer, tap on touch — carries the machine and the state.
class SessionMemberBadge extends StatelessWidget {
  const SessionMemberBadge({super.key, required this.session});

  final SessionEntry session;

  @override
  Widget build(BuildContext context) {
    final memberOf = session.memberOf;
    if (memberOf == null) return const SizedBox.shrink();
    // Labels are optional on the wire — an older carrier, or one that recorded
    // the membership before it could resolve a name. The id is a worse name but
    // a true one, and a row with no machine at all would be the badge saying
    // less than it knows.
    final machine = memberOf.ref.machineLabel?.trim().isNotEmpty == true
        ? memberOf.ref.machineLabel!
        : memberOf.ref.machineId;
    final (Color color, String tip) = memberOf.isOrphaned
        // Warning, matching the isolation badge's unavailable arm: the session
        // is intact and still working, but the lead it answers to is not there.
        ? (
            context.antgrid.warning,
            'Member session — its lead on $machine has not answered. Nothing '
                'is removed while a lead is unreachable; this clears when it '
                'answers again.',
          )
        : (
            context.antgrid.textMuted,
            'Member session — part of a session led on $machine.',
          );
    // The badge owns its own leading gap so a call site reserves no space for a
    // widget that usually renders nothing.
    return Padding(
      padding: const EdgeInsets.only(left: AbTokens.space6),
      child: AbTooltip(
        message: tip,
        triggerMode: TooltipTriggerMode.tap,
        child: AbIcon(
          AbIcons.sessionMemberOf,
          size: _glyphSize,
          color: color,
        ),
      ),
    );
  }
}

/// Matched to the row text beside it rather than to [AbTokens.iconButtonGlyph]:
/// this glyph is a marker on a line of text, not a control.
const double _glyphSize = AbTokens.fontSm;
