import 'package:flutter/cupertino.dart' show CupertinoTheme;
import 'package:flutter/material.dart'
    show
        AdaptiveTextSelectionToolbar,
        ColorScheme,
        InputBorder,
        InputDecoration,
        TextSelectionTheme,
        TextSelectionThemeData,
        Theme,
        ThemeData;
import 'package:flutter/widgets.dart';

import '../foundations/theme.dart';

/// A decoration that paints nothing, for a `TextField` sitting inside a
/// Carbon field box that owns the fill, border and padding.
///
/// `TextField` backfills every null decoration field from the host app's
/// `ThemeData.inputDecorationTheme`, and a per-state border wins over
/// [InputDecoration.border]. `InputDecoration.collapsed` only sets `border`,
/// so a host theme with outlined or filled fields would paint its own box
/// inside Carbon's. Every state is therefore set here explicitly.
InputDecoration carbonBareInputDecoration({
  String? hintText,
  TextStyle? hintStyle,
  Widget? hint,
}) {
  return InputDecoration(
    isCollapsed: true,
    isDense: true,
    contentPadding: EdgeInsets.zero,
    filled: false,
    border: InputBorder.none,
    enabledBorder: InputBorder.none,
    focusedBorder: InputBorder.none,
    disabledBorder: InputBorder.none,
    errorBorder: InputBorder.none,
    focusedErrorBorder: InputBorder.none,
    constraints: const BoxConstraints(),
    hintText: hint == null ? hintText : null,
    hintStyle: hintStyle,
    hint: hint,
  );
}

/// Scopes the text selection chrome a `TextField` inherits from the host app
/// to Carbon colours.
///
/// Selection handles have no Carbon counterpart, so they follow the caret.
/// Material handles read [TextSelectionTheme] and iOS handles read
/// [CupertinoTheme], which a Material host derives from its own primary
/// colour, so both are set.
class CarbonSelectionScope extends StatelessWidget {
  const CarbonSelectionScope({super.key, required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    final colors = CarbonTheme.of(context).colors;
    return CupertinoTheme(
      data: CupertinoTheme.of(
        context,
      ).copyWith(selectionHandleColor: colors.textPrimary),
      child: TextSelectionTheme(
        data: TextSelectionThemeData(
          cursorColor: colors.textPrimary,
          selectionColor: colors.highlight,
          selectionHandleColor: colors.textPrimary,
        ),
        child: child,
      ),
    );
  }
}

/// The selection toolbar, built from Carbon tokens rather than the host
/// app's Material colour scheme. Carbon web has no toolbar of its own, so the
/// labels keep the platform's native type.
///
/// Takes the field's [theme] rather than a context: a `TextField` builds its
/// context menu in the root overlay, above any `CarbonTheme` placed below the
/// app's Navigator, where a lookup would find only the default theme.
Widget carbonSelectionToolbar(
  CarbonThemeData theme,
  EditableTextState editableTextState,
) {
  final colors = theme.colors;
  final scheme = ColorScheme(
    brightness: theme.brightness,
    primary: colors.textPrimary,
    onPrimary: colors.textInverse,
    secondary: colors.textPrimary,
    onSecondary: colors.textInverse,
    error: colors.supportError,
    onError: colors.textOnColor,
    surface: colors.layer01,
    onSurface: colors.textPrimary,
  );
  return Theme(
    data: ThemeData(
      colorScheme: scheme,
    ),
    child: AdaptiveTextSelectionToolbar.editableText(
      editableTextState: editableTextState,
    ),
  );
}
