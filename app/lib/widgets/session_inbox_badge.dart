import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../design/ab_colors.dart';
import '../design/ab_icons.dart';
import '../design/ab_tokens.dart';
import '../design/widgets/ab_chip.dart';
import '../design/widgets/ab_icon.dart';
import '../design/widgets/ab_tap_target.dart';
import '../design/widgets/ab_tooltip.dart';
import '../providers/agent_transport.dart' show selectedRegistrationIdProvider;
import '../providers/session_bus_inbox.dart';
import '../util/detached.dart';
import 'session_inbox_panel.dart';

/// How many session-bus messages another session has left unread in this one,
/// and the way in to read them.
///
/// The row where the user picks a session is the only place a session that is
/// NOT open can say it has mail, which is why this is the ENTRY POINT and not
/// just a marker: a surface scoped to the focused session can never speak for
/// the sibling whose mail is actually easy to miss. Tapping opens that
/// session's messages over the current one WITHOUT moving focus — reading what
/// a peer wrote is not a reason to leave the session being worked in.
///
/// Glyph AND count, where the isolation and shared-workspace markers beside it
/// are glyph-only: those two say what a session IS, which does not change while
/// the user reads the row, and this one says how much is piling up, which does.
///
/// Rendered for the focused PROJECT only. [sessionInboxProvider] reads the
/// focused project's bridge, and a row belonging to another project would have
/// its session id answered by a bridge that has never heard of it — a refusal
/// rendered as an empty mailbox, which is the one wrong thing a mailbox can
/// say. Recent rows from unfocused projects therefore show nothing here.
class SessionInboxBadge extends ConsumerWidget {
  const SessionInboxBadge({
    super.key,
    required this.entryId,
    required this.sessionId,
  });

  /// The project the row belongs to, not the focused one.
  final String entryId;
  final String sessionId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    if (ref.watch(selectedRegistrationIdProvider) != entryId) {
      return const SizedBox.shrink();
    }
    // `.select` on the count alone: a read that replaces the post list without
    // moving the number must not repaint every session row in the drawer.
    final unread = ref.watch(
      sessionInboxProvider(sessionId).select((s) => s.unread),
    );
    if (unread == 0) return const SizedBox.shrink();
    return Padding(
      // Owns its leading gap, so a call site mounts it without reserving space
      // for a widget that usually renders nothing.
      padding: const EdgeInsets.only(left: AbTokens.space6),
      child: AbTapTarget(
        // Opaque, so the tap stops here: the row underneath activates the
        // session, and reading a sibling's mail must not also switch to it.
        onTap: () => detached(
          'SessionInboxBadge',
          'open messages',
          () => showSessionInbox(context, sessionId: sessionId),
        ),
        child: AbTooltip(
          // Material's default trigger, where this glyph used to take tap: tap
          // is the OPEN now, and a tooltip still eating it would leave the
          // badge inert on touch, which is the platform that has no hover to
          // fall back on.
          message: unread == 1
              ? 'One message from another session is waiting in this '
                    'session\'s inbox. Open it.'
              : '$unread messages from other sessions are waiting in this '
                    'session\'s inbox. Open them.',
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              AbIcon(
                AbIcons.inbox,
                size: _glyphSize,
                color: context.antgrid.textSecondary,
              ),
              const SizedBox(width: AbTokens.space2),
              AbChip.system(
                label: '$unread',
                // Deliberately neither of the two colours already spoken for on
                // this row: `unread` is the leading dot's, for an answer THIS
                // session's agent wrote and the user has not read, and `accent`
                // is SessionHandlerBadge's, for a question waiting on the user.
                // Bus mail is neither — nobody is blocked on the human — and
                // two counts in one row that clear on different actions must
                // not be painted the same.
                color: context.antgrid.textSecondary,
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Matched to the row text beside it rather than to [AbTokens.iconButtonGlyph]:
/// this glyph is a marker on a line of text, not a control.
const double _glyphSize = AbTokens.fontSm;
