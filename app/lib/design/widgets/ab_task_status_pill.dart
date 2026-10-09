import 'package:flutter/widgets.dart';

import '../ab_colors.dart';
import '../ab_status_tone.dart';
import '../ab_tokens.dart';

/// A labelled, tone-driven pill for a persistent, user-owned state.
///
/// Deliberately not [AbStatusPill], which is typed to `AbAgentStatus` and
/// carries its own dot — and that dot pulses. A row can show a user-owned state
/// and a live agent's liveness at once, and the two must never share a shape:
/// the state is a labelled pill, liveness is a dot. Putting a pulsing pill
/// beside a pulsing dot is exactly the ambiguity this widget exists to avoid.
///
/// [AbStatusTone.disabled] resolves to `iconMuted`, which that enum documents
/// as a dot/glyph tone rather than a readable-text one — so this widget maps it
/// to `textMuted` itself instead of asking every caller to remember.
class AbTaskStatusPill extends StatelessWidget {
  const AbTaskStatusPill({
    super.key,
    required this.label,
    required this.tone,
    this.compact = false,
  });

  final String label;
  final AbStatusTone tone;

  /// Drops the fill and the border, leaving toned text. For the narrow lists
  /// where the pill's chrome costs more width than the state is worth.
  final bool compact;

  @override
  Widget build(BuildContext context) {
    final color = tone == AbStatusTone.disabled
        ? context.antgrid.textMuted
        : tone.color(context);
    final text = Text(
      label,
      style: AbTokens.sansStyle(
        fontSize: AbTokens.fontXxs,
        fontWeight: FontWeight.w600,
        color: color,
        height: 1.0,
      ).copyWith(letterSpacing: 0.4),
    );
    if (compact) return text;
    return Container(
      padding: const EdgeInsets.symmetric(
        horizontal: AbTokens.space6,
        vertical: AbTokens.space2,
      ),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.12),
        border: Border.all(color: color.withValues(alpha: 0.5)),
        borderRadius: AbTokens.borderRadius3,
      ),
      child: text,
    );
  }
}
