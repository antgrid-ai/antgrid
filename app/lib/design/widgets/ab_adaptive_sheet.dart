import 'package:flutter/material.dart';

import '../../constants/breakpoints.dart';
import '../ab_colors.dart';

/// Shows [child] as a modal bottom sheet on compact widths and a centered
/// [Dialog] on wider ones — the shared Antgrid adaptive-sheet chrome.
///
/// The mobile sheet is scroll-controlled and padded for the keyboard inset
/// (read from the sheet's own builder context, not the caller's); the desktop
/// dialog is width-capped at [maxWidth]. Returns the value the content pops
/// the route with, or null on dismiss.
Future<T?> showAbAdaptiveSheet<T>(
  BuildContext context, {
  required Widget child,
  double maxWidth = 460,
}) {
  final isMobile = MediaQuery.sizeOf(context).width < kCompactBreakpoint;
  if (isMobile) {
    return showModalBottomSheet<T>(
      context: context,
      isScrollControlled: true,
      backgroundColor: context.antgrid.bgSurface,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(4)),
      ),
      builder: (sheetCtx) => Padding(
        padding: EdgeInsets.only(
          bottom: MediaQuery.viewInsetsOf(sheetCtx).bottom,
        ),
        child: child,
      ),
    );
  }
  return showDialog<T>(
    context: context,
    builder: (_) => Dialog(
      backgroundColor: context.antgrid.bgSurface,
      child: ConstrainedBox(
        constraints: BoxConstraints(maxWidth: maxWidth),
        child: child,
      ),
    ),
  );
}
