import 'package:flutter/widgets.dart';

import '../../design/ab_colors.dart';
import '../../design/ab_icons.dart';
import '../../design/ab_tokens.dart';
import '../../design/widgets/ab_icon.dart';
import '../../design/widgets/ab_loading.dart';

/// Shared status → glyph mapping for transcript rows (tool calls, subtasks).
Widget statusGlyph(String? status, AbColors c) => switch (status) {
  'running' => AbLoadingDot(size: AbTokens.fontSm, color: c.accent),
  'error' => AbIcon(AbIcons.error, size: AbTokens.fontSm, color: c.error),
  'cancelled' => AbIcon(AbIcons.close, size: AbTokens.fontSm, color: c.warning),
  'completed' => AbIcon(AbIcons.check, size: AbTokens.fontSm, color: c.success),
  _ => const SizedBox.shrink(),
};
