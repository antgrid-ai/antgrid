import 'package:flutter/widgets.dart';

import '../ab_colors.dart';
import '../ab_tokens.dart';

/// Shared chrome for the workspace's inline notice strips (relay errors, host
/// supervision). One place owns the elevated background, the padding, and the
/// bottom hairline that separates a strip from whatever is stacked under it —
/// the strips themselves provide only their message and trailing action.
class AbInlineBanner extends StatelessWidget {
  const AbInlineBanner({
    super.key,
    required this.text,
    required this.color,
    this.trailing,
  });

  final String text;
  final Color color;
  final Widget? trailing;

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
      child: Row(
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
    );
  }
}
