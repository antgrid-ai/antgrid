import 'package:fleather/fleather.dart';
import 'package:flutter/widgets.dart';

import '../../../design/ab_colors.dart';
import '../../../design/ab_tokens.dart';

/// Composer editor theme built exclusively from Antgrid tokens — never from
/// FleatherThemeData.fallback, which derives from Material ThemeData.
FleatherThemeData buildComposerTheme(BuildContext context) {
  final colors = context.antgrid;
  final body = AbTokens.sansStyle(color: colors.textPrimary);
  final mono = AbTokens.monoStyle(
    fontSize: AbTokens.fontMd,
    color: colors.textPrimary,
  );

  TextBlockTheme block(TextStyle style, {BoxDecoration? decoration}) =>
      TextBlockTheme(
        style: style,
        spacing: const VerticalSpacing(
          top: AbTokens.space4,
          bottom: AbTokens.space4,
        ),
        decoration: decoration,
      );

  TextBlockTheme heading(double size) => block(
        AbTokens.sansStyle(
          fontSize: size,
          fontWeight: FontWeight.w600,
          color: colors.textPrimary,
        ),
      );

  return FleatherThemeData(
    bold: body.copyWith(fontWeight: FontWeight.w600),
    italic: body.copyWith(fontStyle: FontStyle.italic),
    underline: body.copyWith(decoration: TextDecoration.underline),
    strikethrough: body.copyWith(decoration: TextDecoration.lineThrough),
    link: body.copyWith(color: colors.accent),
    paragraph: block(body),
    heading1: heading(AbTokens.fontXl),
    heading2: heading(AbTokens.fontLg),
    heading3: heading(AbTokens.fontBody),
    // 4-6 have no autoformat trigger in v1; style like h3 so decoded or
    // legacy content still renders inside the system.
    heading4: heading(AbTokens.fontBody),
    heading5: heading(AbTokens.fontBody),
    heading6: heading(AbTokens.fontBody),
    lists: block(body),
    quote: block(
      AbTokens.sansStyle(color: colors.textMuted),
      decoration: BoxDecoration(
        border: Border(left: BorderSide(color: colors.accent, width: 2)),
      ),
    ),
    code: block(
      mono,
      decoration: BoxDecoration(
        color: colors.bgElevated,
        borderRadius: AbTokens.borderRadius3,
        border: Border.all(color: colors.borderSubtle),
      ),
    ),
    inlineCode: InlineCodeThemeData(
      style: mono,
      backgroundColor: colors.bgElevated,
      radius: const Radius.circular(AbTokens.radius),
    ),
    horizontalRule: HorizontalRuleThemeData(
      height: AbTokens.space8,
      thickness: 1,
      color: colors.borderSubtle,
    ),
  );
}
