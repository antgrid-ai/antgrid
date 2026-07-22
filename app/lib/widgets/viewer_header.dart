import 'package:flutter/widgets.dart';

import '../design/ab_icons.dart';
import '../design/ab_tokens.dart';
import '../design/ab_colors.dart';
import '../design/widgets/ab_icon_button.dart';
import '../design/widgets/ab_toolbar.dart';
import 'viewer_support.dart';

/// Shared header for media/preview viewers. [trailing] holds optional actions
/// (e.g. a preview/source toggle) placed left of the close button.
Widget buildViewerHeader({
  required String fileName,
  required int size,
  VoidCallback? onClose,
  List<Widget> trailing = const [],
}) {
  return Builder(
    builder: (context) => AbToolbar.custom(
      children: [
        Expanded(
          child: Row(
            children: [
              Flexible(
                child: Text(
                  fileName,
                  overflow: TextOverflow.ellipsis,
                  style: AbTokens.monoStyle(color: context.antgrid.textPrimary),
                ),
              ),
              const SizedBox(width: AbTokens.space2),
              Text(
                formatFileSize(size),
                style: AbTokens.monoStyle(color: context.antgrid.textDisabled),
              ),
            ],
          ),
        ),
        ...trailing,
        if (onClose != null)
          AbIconButton(icon: AbIcons.close, onTap: onClose),
      ],
    ),
  );
}
