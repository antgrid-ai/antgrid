import 'package:flutter/widgets.dart';

import '../design/ab_status_tone.dart';
import '../design/widgets/ab_status_dot.dart';
import '../services/control_plane_client.dart';

/// How each work status paints: tone, fill, and whether it breathes.
///
/// Shared by the inline dot and the corner badge so the two forms can never
/// drift into saying different things about one status.
///
/// Only rest resolves to the `agent*` family; the three live states keep the
/// generic UI semantics so a busy agent speaks the same language as the rest of
/// the app — see the family rule on [AbStatusTone].
({AbStatusTone tone, AbDotStyle style, bool pulse}) agentWorkStatusDotSpec(
  AgentWorkStatus status,
) => switch (status) {
  AgentWorkStatus.working => (
    tone: AbStatusTone.info,
    style: AbDotStyle.filled,
    pulse: true,
  ),
  AgentWorkStatus.attention => (
    tone: AbStatusTone.warning,
    style: AbDotStyle.filled,
    pulse: true,
  ),
  AgentWorkStatus.error => (
    tone: AbStatusTone.danger,
    style: AbDotStyle.filled,
    pulse: false,
  ),
  // Solid but still: an answer is sitting there, which is a fact rather than an
  // event. Pulsing it would put it in the same register as a working agent and
  // make the one state you can safely ignore the loudest thing on the list.
  AgentWorkStatus.unread => (
    tone: AbStatusTone.unread,
    style: AbDotStyle.filled,
    pulse: false,
  ),
  AgentWorkStatus.done => (
    tone: AbStatusTone.agentIdle,
    style: AbDotStyle.hollow,
    pulse: false,
  ),
};

/// Whether this status is a CALL TO ACTION — something the user has to come
/// and do — as opposed to a report of what the agent is up to.
///
/// The narrow set every ROLLUP surface is limited to. A rollup speaks for rows
/// that are off screen, so it may only say "one of these wants you"; `working`
/// and `done` are the agent's own business and belong to the row itself, where
/// there is somewhere to look. One predicate so a project rollup and a machine
/// rollup cannot come to disagree about the same status.
bool agentWorkStatusNeedsUser(AgentWorkStatus status) =>
    status != AgentWorkStatus.done && status != AgentWorkStatus.working;

/// Canonical indicator for an [AgentWorkStatus], shared by the Recent list and
/// the sidebar so the four states read identically everywhere:
/// working (pulsing accent) · attention (yellow pulse — needs you) ·
/// error (red) · unread (blue — answered, not yet opened) · done (hollow idle
/// grey).
///
/// Only states that want something from you carry colour. `done` is deliberately
/// the same hollow grey as a session that never ran: once the agent is finished
/// AND you have seen the answer there is nothing to act on, so it reads as idle
/// rather than as an outcome — which is why it carries no check glyph and no
/// success colour. Opening a session is therefore the only thing that turns a
/// dot off, and `unread` is what fills the gap that left: an answer you have not
/// come back to is not the same as one you have read.
class AgentWorkStatusDot extends StatelessWidget {
  const AgentWorkStatusDot({super.key, required this.status});

  final AgentWorkStatus status;

  @override
  Widget build(BuildContext context) {
    final spec = agentWorkStatusDotSpec(status);
    return AbStatusDot(
      tone: spec.tone,
      size: AbDotSize.sm,
      style: spec.style,
      pulse: spec.pulse,
    );
  }
}

/// Corner-badge form of [AgentWorkStatusDot], for mounting on an agent mark the
/// way a presence dot sits on an avatar.
///
/// `done` keeps the hollow/filled split that separates it from the three live
/// states — nothing legible would fit inside a 6px circle anyway, and the split
/// alone still answers "is this one live".
///
/// [ringColor] must be whatever background the badge is painted over: it punches
/// the dot free of the mark's strokes, so a wrong colour reads as a halo. Only
/// the dot pulses — a breathing ring would let the mark bleed back through.
class AgentWorkStatusBadge extends StatelessWidget {
  const AgentWorkStatusBadge({
    super.key,
    required this.status,
    required this.ringColor,
  });

  final AgentWorkStatus status;
  final Color ringColor;

  /// Ring thickness per side. The sm dot size is already the floor for a
  /// legible dot, so the ring is what has to stay thin.
  static const double _ring = 1.0;

  @override
  Widget build(BuildContext context) {
    final spec = agentWorkStatusDotSpec(status);
    return DecoratedBox(
      decoration: BoxDecoration(shape: BoxShape.circle, color: ringColor),
      child: Padding(
        padding: const EdgeInsets.all(_ring),
        child: AbStatusDot(
          tone: spec.tone,
          size: AbDotSize.sm,
          style: spec.style,
          pulse: spec.pulse,
        ),
      ),
    );
  }
}
