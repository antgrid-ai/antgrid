import 'package:flutter/widgets.dart';

import '../ab_icons.dart';
import '../ab_tokens.dart';
import 'ab_icon_button.dart';

/// Standard padding for AlertDialog titlePadding.
const abDialogTitlePadding = EdgeInsets.fromLTRB(
  AbTokens.space16,
  AbTokens.space12,
  AbTokens.space8,
  0,
);

/// Builds a standard dialog title row with close button.
///
/// [wraps] budgets the second line this row has always allowed. The default
/// leading is exactly the font size, which shows nothing while a caller passes a
/// short constant — 'Fork session', 'Open link' — and puts one line's
/// descenders into the next line's ascenders the moment a title composes in text
/// of the user's own length. Pass it wherever the title is not a constant.
Widget abDialogTitle(
  String title, {
  required VoidCallback onClose,
  bool wraps = false,
}) {
  return Row(
    children: [
      Expanded(
        child: Text(
          title,
          maxLines: 2,
          overflow: TextOverflow.ellipsis,
          style: AbTokens.sansStyle(
            fontSize: AbTokens.fontBody,
            fontWeight: FontWeight.w600,
            // AbListRow's own leading for wrapped chrome text, so a title and
            // the rows under it break at the same rhythm.
            height: wraps ? 1.2 : 1.0,
          ),
        ),
      ),
      AbIconButton(icon: AbIcons.close, onTap: onClose, tooltip: 'Close'),
    ],
  );
}
