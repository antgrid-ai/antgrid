import 'package:flutter/material.dart';
import '../ab_tokens.dart';
import '../ab_colors.dart';
import 'pulse_builder.dart';

/// Terminal-native loading indicator — a pulsing cursor block.
///
/// Mimics a blinking terminal cursor to stay true to the dev-tool aesthetic.
/// Use [message] for loading text and [AbLoadingDot] in compact spaces.
class AbLoading extends StatelessWidget {
  /// Optional status message shown below the cursor.
  final String? message;

  /// Size of the cursor block.
  final double size;

  const AbLoading({super.key, this.message, this.size = 14});

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          PulseBuilder(
            halfCycle: const Duration(milliseconds: 800),
            restingValue: 0.5,
            builder: (context, value, _) => Container(
              width: size,
              height: size * 1.4,
              decoration: BoxDecoration(
                color: context.antgrid.accent.withValues(
                  alpha: 0.2 + 0.8 * value,
                ),
                borderRadius: AbTokens.borderRadius3,
              ),
            ),
          ),
          if (message != null) ...[
            const SizedBox(height: AbTokens.space12),
            Text(
              message!,
              style: AbTokens.sansStyle(
                fontSize: AbTokens.fontXs,
                color: context.antgrid.textMuted,
              ),
            ),
          ],
        ],
      ),
    );
  }
}

/// Inline loading indicator — a small pulsing dot for use inside
/// buttons, bars, and compact spaces. Replaces CircularProgressIndicator.
class AbLoadingDot extends StatelessWidget {
  final double size;
  final Color? color;

  const AbLoadingDot({super.key, this.size = 12, this.color});

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: size,
      height: size,
      child: PulseBuilder(
        halfCycle: const Duration(milliseconds: 600),
        restingValue: 0.5,
        builder: (context, value, child) => Center(
          child: Transform.scale(scale: 0.4 + 0.6 * value, child: child),
        ),
        child: Container(
          width: size,
          height: size,
          decoration: BoxDecoration(
            color: color ?? context.antgrid.accent,
            borderRadius: AbTokens.borderRadius3,
          ),
        ),
      ),
    );
  }
}
