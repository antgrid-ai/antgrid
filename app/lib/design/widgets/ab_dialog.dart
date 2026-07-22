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
Widget abDialogTitle(String title, {required VoidCallback onClose}) {
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
            height: 1.0,
          ),
        ),
      ),
      AbIconButton(icon: AbIcons.close, onTap: onClose, tooltip: 'Close'),
    ],
  );
}
