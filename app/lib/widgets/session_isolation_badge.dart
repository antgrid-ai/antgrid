import 'package:flutter/widgets.dart';

import '../design/ab_colors.dart';
import '../design/ab_icons.dart';
import '../design/ab_tokens.dart';
import '../design/widgets/ab_icon.dart';
import '../design/widgets/ab_tooltip.dart';
import '../models/session_entry.dart';

/// Whether this session runs somewhere other than the project root.
///
/// Derived by exclusion — anything that is not `main` is isolated — because the
/// bridge's checkout kinds are an open set (`CHECKOUT_KINDS` in
/// `bridge/src/worktrees/checkout-types.ts`) and a kind this build has never
/// heard of is still not the shared tree. Matching the mechanism instead would
/// leave a future kind wearing no marker at all, which is the one answer that is
/// certainly wrong.
bool sessionIsIsolated(SessionEntry s) => s.checkoutKind != 'main';

/// What the row may claim about an isolated session's workspace.
///
/// [unknown] is the answer for a `checkoutState` this build cannot name, and it
/// is load-bearing rather than defensive: the bridge owns that vocabulary and
/// may widen it, so an unrecognised value must degrade to the weakest true
/// statement instead of being read as either healthy or broken.
enum SessionCheckoutHealth { ready, unavailable, unknown }

SessionCheckoutHealth sessionCheckoutHealth(String? state) => switch (state) {
  'ready' => SessionCheckoutHealth.ready,
  'missing' || 'failed' => SessionCheckoutHealth.unavailable,
  _ => SessionCheckoutHealth.unknown,
};

/// The one marker that says a session is isolated, mounted wherever a session
/// is named — the drawer row, the Recent/search row, the agent breadcrumb.
///
/// Renders nothing for a shared session, so every call site can mount it
/// unconditionally and none of them re-derives what "isolated" means. Its copy
/// names no mechanism: the same badge stands for every non-`main` kind, so a
/// word like "worktree" would be a guess about which backend this session runs.
///
/// A glyph rather than a word: it sits beside a session NAME in rows that are
/// already tight, and the name is what the user scans for. The tooltip — hover
/// on a pointer, tap on touch — carries the whole explanation, so nothing the
/// badge means depends on reading the icon.
class SessionIsolationBadge extends StatelessWidget {
  const SessionIsolationBadge({super.key, required this.session});

  final SessionEntry session;

  @override
  Widget build(BuildContext context) {
    if (!sessionIsIsolated(session)) return const SizedBox.shrink();
    final (Color? color, String tip) = switch (sessionCheckoutHealth(
      session.checkoutState,
    )) {
      SessionCheckoutHealth.ready => (
        null,
        'Isolated session — its own workspace, separate from your main tree.',
      ),
      SessionCheckoutHealth.unavailable => (
        context.antgrid.warning,
        'This isolated session\'s workspace is unavailable.',
      ),
      // The most conservative claim available: it stays true whatever the state
      // turns out to mean.
      SessionCheckoutHealth.unknown => (null, 'Isolated session.'),
    };
    // The badge owns its own leading gap so a call site can drop it into a row
    // without reserving space for a widget that usually renders nothing.
    return Padding(
      padding: const EdgeInsets.only(left: AbTokens.space6),
      child: AbTooltip(
        message: tip,
        triggerMode: TooltipTriggerMode.tap,
        child: AbIcon(
          AbIcons.isolated,
          size: _glyphSize,
          color: color ?? context.antgrid.textMuted,
        ),
      ),
    );
  }
}

/// Matched to the row text beside it rather than to [AbTokens.iconButtonGlyph]:
/// this glyph is a marker on a line of text, not a control.
const double _glyphSize = AbTokens.fontSm;
