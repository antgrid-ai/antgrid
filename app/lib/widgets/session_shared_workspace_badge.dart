import 'package:flutter/widgets.dart';

import '../design/ab_colors.dart';
import '../design/ab_icons.dart';
import '../design/ab_tokens.dart';
import '../design/widgets/ab_icon.dart';
import '../design/widgets/ab_tooltip.dart';
import '../models/session_entry.dart';

/// The one marker that says this session's workspace is not its own — another
/// session is working in the same directory, on the same branch, right now.
/// Mounted wherever a session is named: the drawer row, the Recent/search row,
/// the agent breadcrumb.
///
/// Renders nothing for a session that has its workspace to itself, so every
/// call site can mount it unconditionally and none of them re-derives what
/// "shared" means. Paired with `SessionIsolationBadge`, which answers the other
/// half — where the session runs, rather than who else is there — so the two
/// can both show and neither restates the other.
///
/// A glyph rather than the count, matching that badge: this sits beside a
/// session NAME in rows that are already tight, and a number that moves as
/// sessions come and go is motion the reader cannot act on. The count is the
/// tooltip's job — hover on a pointer, tap on touch — which is also the only
/// place with room to say what sharing actually costs.
class SessionSharedWorkspaceBadge extends StatelessWidget {
  const SessionSharedWorkspaceBadge({super.key, required this.session});

  final SessionEntry session;

  @override
  Widget build(BuildContext context) {
    if (!session.sharedWorkspace) return const SizedBox.shrink();
    // The bridge floors the count at 1 and the model defaults it to 1, so an
    // older bridge that sets the flag and omits the number lands here at zero
    // others. Say the weaker true thing rather than "0 other sessions".
    final others = session.workspaceMemberCount - 1;
    // The badge owns its own leading gap so a call site reserves no space for a
    // widget that usually renders nothing.
    return Padding(
      padding: const EdgeInsets.only(left: AbTokens.space6),
      child: AbTooltip(
        message: others > 0
            ? 'Shared workspace — ${others == 1 ? '1 other session works' : '$others other sessions work'} '
                  'in this directory. Every one of them edits the same files '
                  'and commits to the same branch, at the same time.'
            : 'Shared workspace — other sessions work in this directory, '
                  'editing the same files and committing to the same branch.',
        triggerMode: TooltipTriggerMode.tap,
        child: AbIcon(
          AbIcons.sharedWorkspace,
          size: _glyphSize,
          color: context.antgrid.textMuted,
        ),
      ),
    );
  }
}

/// Matched to the row text beside it rather than to [AbTokens.iconButtonGlyph]:
/// this glyph is a marker on a line of text, not a control.
const double _glyphSize = AbTokens.fontSm;
