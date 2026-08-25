import 'package:flutter/widgets.dart';

import '../design/ab_colors.dart';
import '../design/ab_icons.dart';
import '../design/ab_tokens.dart';
import '../design/widgets/ab_icon.dart';
import '../design/widgets/ab_tooltip.dart';
import '../design/widgets/pulsing_opacity.dart';
import '../models/session_entry.dart';
import '../providers/session_setup.dart'
    show SessionSetupPhase, sessionSetupPhase;

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
/// A provisioning run in flight pulses that same glyph rather than adding a
/// second marker: the rows this sits in have no room for two, and "isolated"
/// and "not ready yet" are the identity and the state of one workspace.
///
/// A glyph rather than a word: it sits beside a session NAME in rows that are
/// already tight, and the name is what the user scans for. The tooltip — hover
/// on a pointer, tap on touch — carries the whole explanation, so nothing the
/// badge means depends on reading the icon.
class SessionIsolationBadge extends StatelessWidget {
  const SessionIsolationBadge({super.key, required this.session, this.setup});

  final SessionEntry session;

  /// This session's provisioning run, or null where the caller has no
  /// trustworthy account of one.
  ///
  /// Taken as a parameter rather than read off [session] because a row is
  /// served from the persisted session cache as often as from the live list,
  /// and the cache deliberately carries no `setup` at all — a stored `running`
  /// would restore with nothing alive to finish it, so the badge would pulse
  /// forever on a session whose setup ended before the app was last closed
  /// (`cached_sessions_store.dart`). `sessionSetupProvider` is the one honest
  /// source; a call site that cannot reach it passes nothing and the badge
  /// simply omits the arm.
  final SessionSetup? setup;

  @override
  Widget build(BuildContext context) {
    if (!sessionIsIsolated(session)) return const SizedBox.shrink();
    final health = sessionCheckoutHealth(session.checkoutState);
    // Setup only ever runs against a checkout the bridge calls `ready`, so a
    // workspace it cannot reach is both the more urgent claim and the more
    // certain one — it outranks the run happening inside it.
    final preparing =
        health != SessionCheckoutHealth.unavailable &&
        sessionSetupPhase(setup) == SessionSetupPhase.running;
    final (Color? color, String tip) = preparing
        // Accent, matching the transcript's own in-progress glyph: the pulse
        // has to swing against the row's background to read as motion, and the
        // resting muted gray barely moves under a fade.
        ? (context.antgrid.accent, 'Preparing this session\'s workspace…')
        : switch (health) {
            SessionCheckoutHealth.ready => (
              null,
              'Isolated session — its own workspace, separate from your main tree.',
            ),
            SessionCheckoutHealth.unavailable => (
              context.antgrid.warning,
              'This isolated session\'s workspace is unavailable.',
            ),
            // The most conservative claim available: it stays true whatever the
            // state turns out to mean.
            SessionCheckoutHealth.unknown => (null, 'Isolated session.'),
          };
    Widget glyph = AbIcon(
      AbIcons.isolated,
      size: _glyphSize,
      color: color ?? context.antgrid.textMuted,
    );
    // Fade alone, no `minScale`: this glyph is sized to the text beside it, so
    // a pulse that resized it would move the line under the reader.
    if (preparing) glyph = PulsingOpacity(child: glyph);
    // The badge owns its own leading gap so a call site can drop it into a row
    // without reserving space for a widget that usually renders nothing.
    return Padding(
      padding: const EdgeInsets.only(left: AbTokens.space6),
      child: AbTooltip(
        message: tip,
        triggerMode: TooltipTriggerMode.tap,
        child: glyph,
      ),
    );
  }
}

/// Matched to the row text beside it rather than to [AbTokens.iconButtonGlyph]:
/// this glyph is a marker on a line of text, not a control.
const double _glyphSize = AbTokens.fontSm;
