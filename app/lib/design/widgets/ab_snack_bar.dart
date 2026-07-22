import 'package:flutter/material.dart';

/// Shows a Antgrid-styled SnackBar.
///
/// Width is constrained to a centered, bounded box by the `MaterialApp`
/// builder (see `main.dart`); this helper centralizes the content so the
/// styling (sans font, `bgElevated`, border) comes from `snackBarTheme` in
/// one place instead of being copy-pasted per call site. The message is
/// capped at [maxLines] with ellipsis so a long string (e.g. an exception)
/// can't overflow the constrained width or grow the bar unboundedly tall.
ScaffoldFeatureController<SnackBar, SnackBarClosedReason> showAbSnackBar(
  BuildContext context,
  String message, {
  Duration? duration,
  bool clearPrevious = false,
}) {
  final messenger = ScaffoldMessenger.of(context);
  if (clearPrevious) messenger.clearSnackBars();
  return messenger.showSnackBar(
    SnackBar(
      // No inline style/background: the global snackBarTheme owns those. Only
      // the wrap/overflow caps live here since they're content-level.
      content: Text(message, maxLines: 3, overflow: TextOverflow.ellipsis),
      duration: duration ?? const Duration(seconds: 4),
    ),
  );
}
