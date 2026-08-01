import 'package:flutter/widgets.dart';

import '../ab_agent_marks.dart';
import '../ab_colors.dart';
import '../ab_tokens.dart';
import 'ab_icon.dart';

/// The focused agent's identity in one square: its brand mark, tinted to the
/// surrounding text colour, or a monogram when [AbAgentMarks] has none.
///
/// The monogram is the point of the widget, not an afterthought. The launchable
/// agent set is a compile-time table that grows without an app release on the
/// bridge side, so a mark-or-nothing design would silently blank out for exactly
/// the newest agents; two letters is always available and always honest.
///
/// Both branches occupy the same [size] square so a row of these can't jitter as
/// the focus moves between a mapped and an unmapped agent.
class AbAgentMark extends StatelessWidget {
  const AbAgentMark({
    super.key,
    required this.toolKey,
    required this.label,
    this.size = 14,
    this.color,
  });

  /// Bridge registry key (`AgentKey`), used to look the mark up.
  final String toolKey;

  /// Display name — the monogram source, and what callers put in the tooltip.
  final String label;

  final double size;

  /// Defaults to `textSecondary`: present but never competing with the accent,
  /// which in this UI means "selected".
  final Color? color;

  /// Up to two uppercase letters for [name]: initials when it reads as multiple
  /// words (`Claude Code` -> CC), otherwise its opening pair (`kilo` -> KI).
  /// Falls back to `?` for a name with no letters at all rather than rendering
  /// an empty box that reads as a failed image.
  @visibleForTesting
  static String monogram(String name) {
    final words = name
        .split(RegExp(r'[\s\-_.]+'))
        .where((w) => w.isNotEmpty)
        .toList();
    if (words.isEmpty) return '?';
    final raw = words.length > 1
        ? '${words[0][0]}${words[1][0]}'
        : words[0].padRight(2).substring(0, 2);
    return raw.trim().toUpperCase();
  }

  @override
  Widget build(BuildContext context) {
    final tint = color ?? context.antgrid.textSecondary;
    final mark = AbAgentMarks.byToolKey[toolKey];
    if (mark != null) return AbIcon(mark, size: size, color: tint);

    return SizedBox.square(
      dimension: size,
      child: Center(
        // Two glyphs at chrome scale overflow a 14px box; shrink to fit rather
        // than clip, so a long-initialled agent stays readable.
        child: FittedBox(
          child: Text(
            monogram(label),
            style: AbTokens.sansStyle(
              fontSize: AbTokens.fontXxs,
              fontWeight: FontWeight.w600,
              color: tint,
            ).copyWith(letterSpacing: 0.4),
          ),
        ),
      ),
    );
  }
}
