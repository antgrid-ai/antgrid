import 'package:flutter/widgets.dart';

import '../ab_colors.dart';
import '../ab_tokens.dart';

/// Shared chrome for the workspace's inline notice strips (relay errors, host
/// supervision). One place owns the elevated background, the padding, and the
/// bottom hairline that separates a strip from whatever is stacked under it —
/// the strips themselves provide only their message and actions.
class AbInlineBanner extends StatelessWidget {
  const AbInlineBanner({
    super.key,
    required this.text,
    required this.color,
    this.trailing,
    this.footer,
  });

  final String text;
  final Color color;

  /// Beside the message, top-aligned so a small control (a dismiss) stays at
  /// the corner however many lines the message wraps to.
  final Widget? trailing;

  /// Under the message, left-aligned — for an action that would otherwise
  /// squeeze a long message into a narrow column.
  final Widget? footer;

  @override
  Widget build(BuildContext context) {
    final colors = context.antgrid;
    return Container(
      decoration: BoxDecoration(
        color: colors.bgElevated,
        border: Border(bottom: BorderSide(color: colors.borderSubtle)),
      ),
      padding: const EdgeInsets.symmetric(
        horizontal: AbTokens.space12,
        vertical: AbTokens.space8,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            crossAxisAlignment: footer == null
                ? CrossAxisAlignment.center
                : CrossAxisAlignment.start,
            children: [
              Expanded(
                child: Text(
                  text,
                  style: AbTokens.sansStyle(
                    fontSize: AbTokens.fontXs,
                    color: color,
                  ),
                ),
              ),
              ?trailing,
            ],
          ),
          if (footer case final footer?) ...[
            const SizedBox(height: AbTokens.space8),
            footer,
          ],
        ],
      ),
    );
  }
}
