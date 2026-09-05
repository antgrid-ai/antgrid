import 'package:flutter/widgets.dart';

import 'ab_colors.dart';

/// Semantic status tone for dots, indicators, and any future status surface.
/// Resolves to a concrete color via [color]. Keep this layer thin —
/// domain enums map to tones in their own adapters, never directly to colors.
///
/// Two families live here. [neutral]/[info]/[success]/[warning]/[danger]/
/// [unread]/[muted]/[disabled] are generic UI semantics (bright, and they shift per theme
/// preset). [agentIdle]/[agentThinking]/[agentRunning]/[agentAttention] describe
/// what an agent is *doing* and resolve to the warm theme-invariant `status*`
/// palette.
///
/// The rule is narrow, and it is about REST, not about the whole family: an
/// agent at rest — idle, stopped, finished — takes [agentIdle], never [success]
/// or [muted]. An agent that finished a turn is not the same claim as an
/// operation that "succeeded"; painting them alike puts a green check beside
/// every dormant session.
///
/// Everything an agent does that is NOT rest keeps the generic semantics, so it
/// speaks the same language as the rest of the UI: [info] for live/working (the
/// accent, pulsing), [warning] for "needs you", [danger] for a failure. See
/// `agentWorkStatusDotSpec`, which is the canonical mapping.
///
/// That leaves [agentThinking]/[agentRunning]/[agentAttention] used only by
/// `AbAgentTab`, which is not currently mounted anywhere (the design gallery
/// that once previewed it is gone). Prefer the generic tones for new agent
/// surfaces; reach for these three only if the tab ships.
enum AbStatusTone {
  neutral,
  info,
  success,
  warning,
  danger,
  /// Something finished and nobody has looked at it yet. Not [info] (that is
  /// live activity) and not [success] (nothing was won) — the blue "new" a
  /// message list uses.
  unread,
  muted,
  disabled,
  agentIdle,
  agentThinking,
  agentRunning,
  agentAttention,
}

extension AbStatusToneColor on AbStatusTone {
  Color color(BuildContext context) {
    final palette = context.antgrid;
    return switch (this) {
      AbStatusTone.neutral => palette.textSecondary,
      AbStatusTone.info => palette.accent,
      AbStatusTone.success => palette.success,
      AbStatusTone.warning => palette.warning,
      AbStatusTone.danger => palette.error,
      AbStatusTone.unread => palette.unread,
      AbStatusTone.muted => palette.textMuted,
      // Every current consumer is a dot/glyph (AbStatusDot or a leading
      // icon), never body text — iconMuted's 3:1 floor is the right bar, not
      // textDisabled's WCAG-exempt one. If a future consumer renders this
      // tone as readable text, it needs textMuted explicitly, not this tone.
      AbStatusTone.disabled => palette.iconMuted,
      AbStatusTone.agentIdle => palette.statusIdle,
      AbStatusTone.agentThinking => palette.statusThinking,
      AbStatusTone.agentRunning => palette.statusRunning,
      AbStatusTone.agentAttention => palette.statusAttention,
    };
  }
}
