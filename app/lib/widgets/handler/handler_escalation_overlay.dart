import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../design/ab_colors.dart';
import '../../design/ab_icons.dart';
import '../../design/ab_tokens.dart';
import '../../design/widgets/ab_chip.dart';
import '../../design/widgets/ab_icon_button.dart';
import '../../design/widgets/ab_tap_target.dart';
import '../../models/handler_state.dart';
import '../../providers/providers.dart';
import '../../providers/visible_surface.dart';
import '../../services/handler_service.dart';
import '../../util/detached.dart';
import 'handler_escalation_answer.dart';
import 'handler_escalation_row.dart';
import 'handler_layout.dart';

/// The focused session's standing escalation, floated over the terminal it
/// stopped.
///
/// A judge escalation used to be answerable only on the Handler workspace tab —
/// a surface the user is not on, because they are watching the session that
/// went quiet. This puts the question where the silence is.
///
/// A FLOATING card rather than another row in the panel's column, deliberately:
/// the terminal keeps its full height, and every height change on it sends a
/// `terminal:resize` up the wire (`_maybeSendResize` in
/// terminal_view_wrapper.dart derives its row count off the incoming
/// constraints). What the terminal does reserve is the collapsed strip alone —
/// see [handlerEscalationCollapsedHeight] and the mount in `AgentPanel`.
///
/// It is not the only thing pinned to that bottom edge — `CommandOutputOverlay`
/// occupies the same band — and the order the two are stacked in is decided at
/// the mount in `AgentPanel`, not here.
///
/// Arrives expanded, because a question that announces itself as one line the
/// user has to open is a question they will not read. The chevron is the way
/// back to the terminal underneath.
class HandlerEscalationOverlay extends ConsumerStatefulWidget {
  const HandlerEscalationOverlay({super.key});

  @override
  ConsumerState<HandlerEscalationOverlay> createState() =>
      _HandlerEscalationOverlayState();
}

class _HandlerEscalationOverlayState
    extends ConsumerState<HandlerEscalationOverlay> {
  /// The escalation the flag below belongs to. Answering one row promotes the
  /// next into this slot, and a new blocking question inheriting the last one's
  /// collapsed flag arrives as a line of text nobody opened — the same class of
  /// inheritance `HandlerDecisionCard` guards its pending flag against, and one
  /// the per-session key on this widget cannot cover on its own.
  String? _shownId;

  bool _expanded = true;

  @override
  Widget build(BuildContext context) {
    // Narrowed to the focused session by the provider itself, and never the
    // unnarrowed [handlerStateProvider] the agent bar's NEEDS YOU pill reads
    // thirty lines away in `agent_panel.dart`: that one spans sessions on
    // purpose, and floating its head here would put a BACKGROUND session's
    // question over this terminal, attributed to the agent on screen.
    final state = ref.watch(focusedSessionHandlerStateProvider);
    final escalations = state.escalations;
    if (escalations.isEmpty) {
      // Released rather than left pinned to the row that just went away.
      // `HandlerService._dropRows` retires an answered row optimistically and
      // the next `handler:status` reconciles authoritatively — which can put
      // the SAME escalationId back a round trip later. The guard below reads
      // that as no change, so a still-unanswered question would return wearing
      // the collapsed flag the user set on it before they answered.
      _shownId = null;
      return const SizedBox.shrink();
    }
    // Urgent first, then oldest — `compareEscalations` has already banded the
    // list, so the head is the row holding the session up. Never `.last`: the
    // newest row is routinely a normal-urgency question standing behind a
    // blocking one.
    final e = escalations.first;
    // Assigned during build with no setState because it establishes this
    // frame's own state rather than reacting to a change — the same shape
    // `didUpdateWidget`'s escalationId guard takes on the cards this draws.
    if (_shownId != e.escalationId) {
      _shownId = e.escalationId;
      _expanded = true;
    }

    final p = context.antgrid;
    // Positioned.fill so the card can be pinned to the bottom of the terminal
    // area, and [Align] — never a fill-sized barrier — so the hit region stays
    // the card. An `Align` render object hit-tests only its child, so a pointer
    // landing on the terminal beside or above the card misses this widget
    // entirely. Giving this fill a ColoredBox, or an opaque gesture surface,
    // silently turns the whole terminal into a dead zone: no error, no visual
    // change, clicks and text selection simply stop.
    return Positioned.fill(
      child: Align(
        alignment: Alignment.bottomCenter,
        // Full width, height to content: [Align] hands its child LOOSE
        // constraints, so without this the card would shrink to whatever its
        // longest line happens to be and float as an island over the terminal.
        child: SizedBox(
          width: double.infinity,
          // Opaque over the card's own bounds, and only because [Align] has
          // already made those bounds the card: painting over the terminal is
          // not the same as covering it, and every part of the card that isn't
          // a control — the header band beside the chevron, the gutters — hands
          // its pointers straight through to `TerminalScreen`. Mouse reporting
          // is always on in an agent session, so that is a click delivered into
          // the agent's own TUI from a tap the user aimed at a Handler card,
          // and a drag started there selects terminal text under an opaque
          // surface. Children still hit-test first, so the chevron, the chips
          // and the decision buttons are untouched.
          child: Listener(
            behavior: HitTestBehavior.opaque,
            child: DecoratedBox(
              decoration: BoxDecoration(
                color: p.bgSurface,
                border: Border(top: BorderSide(color: p.borderDefault)),
              ),
              child: _expanded
                  ? _card(context, state, e, escalations.length)
                  : _strip(context, e, escalations.length),
            ),
          ),
        ),
      ),
    );
  }

  Widget _card(
    BuildContext context,
    HandlerState state,
    HandlerEscalation e,
    int total,
  ) {
    final HandlerService? service = serviceWhenReady(
      ref,
      handlerServiceProvider,
    );
    final container = ref.container;
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Align(
          alignment: Alignment.centerRight,
          child: _controls(context, total: total, compact: false),
        ),
        // Flexible inside a bottom-aligned Align is what bounds the card to the
        // terminal's own height: without it a long question grows the card
        // until the chevron that escapes it is off screen, which is the one
        // state the chevron exists to get out of.
        Flexible(
          child: SingleChildScrollView(
            child: HandlerEscalationRow(
              escalation: e,
              // The narrowed state holds only the focused session, which is the
              // only session this overlay can ever show a row for.
              backlog: state.sessions[e.terminalId]?.backlog ?? const [],
              // Re-resolved through the container on every tap for the reason
              // [answerHandlerEscalation] spells out: the focused project's
              // session can be rebuilt under a card that stays on screen, and
              // the build-time instance is disposed by then.
              //
              // Null for an option-based prompt, which is the one row whose
              // answer this surface cannot carry: the id the agent is blocked
              // on lives in its own prompt, and that prompt is the terminal
              // this card is floating over — so the branch
              // [answerHandlerEscalation] would take is a focus change onto the
              // session already in focus. `AbListRow` renders a null `onTap` as
              // an informational row, which is what stops it offering hover and
              // press feedback for a tap that can do nothing. The PA bar
              // directly beneath says where the answer goes.
              onReply: service == null || e.kind == 'resolve_in_session'
                  ? null
                  : () => detached(
                      'HandlerEscalationOverlay',
                      'answer escalation',
                      () => answerHandlerEscalation(context, container, e),
                    ),
              onDismiss: service == null
                  ? null
                  : () =>
                        focusedServiceOrNull(
                          container,
                          (s) => s.handlerService,
                        )?.dismiss(e),
              onChoice: service == null
                  ? null
                  : (choiceId) =>
                        focusedServiceOrNull(
                          container,
                          (s) => s.handlerService,
                        )?.answerWithChoice(e, choiceId) ??
                        false,
              onAskOption: service == null
                  ? null
                  : (choiceId) =>
                        focusedServiceOrNull(
                          container,
                          (s) => s.handlerService,
                        )?.answerAsk(e, choiceId) ??
                        false,
            ),
          ),
        ),
      ],
    );
  }

  /// One line of what is waiting, standing in the band the terminal reserved
  /// for it — so the strip sits under the last row rather than on it.
  ///
  /// The whole band expands, not just the chevron in its corner. The strip is
  /// the one state where the question is unreadable and the only route back to
  /// it is a 24px glyph in the bottom-right corner of a phone, directly above
  /// the PA bar's own controls; a thumb that misses it low answers the PA bar
  /// instead. Giving the band the toggle is also what earns the strip its
  /// [AbCompactTapTargets] below.
  Widget _strip(BuildContext context, HandlerEscalation e, int total) =>
      GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: () => setState(() => _expanded = true),
        child: ConstrainedBox(
          // A FLOOR, not a fixed height: the chevron's box scales with the
          // user's text size (see AbIconButton), and a strip that refused to
          // grow with it would overflow rather than cover one more terminal
          // row. The reserve is derived from the same call, so the two scale
          // together.
          constraints: BoxConstraints(
            minHeight: handlerEscalationCollapsedHeight(context),
          ),
          child: Row(
            children: [
              const SizedBox(width: handlerGutter),
              Expanded(
                child: Text(
                  e.question,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: AbTokens.sansStyle(fontWeight: FontWeight.w600),
                ),
              ),
              const SizedBox(width: AbTokens.space8),
              HandlerRowMeta.forEscalation(e),
              _controls(context, total: total, compact: true),
            ],
          ),
        ),
      );

  /// The trailing cluster, defined once for both states so a collapse cannot
  /// change what is in it or what order it is in.
  ///
  /// [compact] suppresses the mobile tap-target inflation and only the strip
  /// may ask for it, on [AbCompactTapTargets]' own terms: the strip band is a
  /// tap target across its whole height for the same toggle, so the chevron's
  /// 44px box would buy nothing and would push the strip past the height the
  /// terminal gave up for it. The expanded card's header band belongs to
  /// nothing and answers no tap, so the chevron there has to carry its own.
  Widget _controls(
    BuildContext context, {
    required int total,
    required bool compact,
  }) {
    final row = Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        if (total > 1) ...[
          AbChip.label(
            label: '+${total - 1} more',
            // Accent because it is a route to the rest of the queue and not a
            // count: `textMuted` is this codebase's idiom for the labels that
            // only report, and a phone has no hover to correct the impression.
            color: context.antgrid.accent,
            onTap: _openHandler,
          ),
          const SizedBox(width: AbTokens.space6),
        ],
        AbIconButton(
          // Down means "push it out of the way", up means "bring it back" —
          // the chevron names the direction the card moves, not the one the
          // reader's eye travels.
          icon: _expanded ? AbIcons.chevronDown : AbIcons.chevronUp,
          tooltip: _expanded ? 'Collapse — read the terminal' : 'Expand',
          onTap: () => setState(() => _expanded = !_expanded),
        ),
      ],
    );
    return Padding(
      padding: const EdgeInsets.symmetric(
        horizontal: handlerGutter,
        vertical: AbTokens.space8,
      ),
      child: compact ? AbCompactTapTargets(child: row) : row,
    );
  }

  /// The rest of the queue, on the one surface that lists all of it. No focus
  /// change is involved — every row this overlay can show already belongs to
  /// the focused session — so this takes the plain reveal rather than the
  /// pending-view handover `AgentPanel.openHandler` needs.
  void _openHandler() => revealHandlerTabNow(ref);
}
