import 'package:flutter/widgets.dart';

import '../ab_icons.dart';
import '../ab_tokens.dart';
import '../ab_colors.dart';
import 'ab_brand_mark.dart';
import 'ab_icon.dart';

enum _EmptyVariant { full, compact }

/// Canonical empty-state placeholder.
///
/// Three constructors:
/// - default: optional icon (32px) + title + optional subtitle + optional action
/// - .compact: one-line muted text, no icon, no action
/// - .error: red icon (default `AbIcons.error`) + title + optional subtitle/action
///
/// Vertical rhythm: icon→title `space12`, title→subtitle `space4`,
/// subtitle/title→action `space14`. Always centered.
class AbEmptyState extends StatelessWidget {
  const AbEmptyState({
    super.key,
    required this.title,
    this.icon,
    this.subtitle,
    this.action,
    this.showBrand = false,
  }) : _variant = _EmptyVariant.full,
       _isError = false;

  const AbEmptyState.compact({super.key, required this.title})
    : _variant = _EmptyVariant.compact,
      icon = null,
      subtitle = null,
      action = null,
      showBrand = false,
      _isError = false;

  const AbEmptyState.error({
    super.key,
    required this.title,
    this.icon = AbIcons.error,
    this.subtitle,
    this.action,
  }) : _variant = _EmptyVariant.full,
       showBrand = false,
       _isError = true;

  final String title;
  final String? subtitle;
  final String? icon; // AbIcons.* is a String (SVG asset)
  final Widget? action;
  // Brand moment fits only the neutral full-variant empty state — never an
  // error or one-line compact state, so .error/.compact force this false.
  final bool showBrand;
  final _EmptyVariant _variant;
  final bool _isError;

  @override
  Widget build(BuildContext context) {
    if (_variant == _EmptyVariant.compact) {
      return Center(
        child: Text(
          title,
          style: AbTokens.sansStyle(
            fontSize: AbTokens.fontSm,
            color: context.antgrid.textMuted,
          ),
          textAlign: TextAlign.center,
        ),
      );
    }
    return Center(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: AbTokens.space16),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.center,
          children: [
            if (showBrand) ...[
              const Opacity(opacity: 0.5, child: AbBrandMark()),
              const SizedBox(height: AbTokens.space12),
            ],
            if (icon != null) ...[
              AbIcon(
                icon!,
                size: 32,
                color: _isError ? context.antgrid.error : context.antgrid.textDisabled,
              ),
              const SizedBox(height: AbTokens.space12),
            ],
            Text(
              title,
              style: AbTokens.sansStyle(
                fontSize: AbTokens.fontSm,
                color: _isError ? context.antgrid.textPrimary : context.antgrid.textMuted,
                fontWeight: _isError ? FontWeight.w500 : FontWeight.normal,
              ),
              textAlign: TextAlign.center,
            ),
            if (subtitle != null) ...[
              const SizedBox(height: AbTokens.space4),
              Text(
                subtitle!,
                style: AbTokens.sansStyle(
                  fontSize: AbTokens.fontXxs,
                  color: context.antgrid.textMuted,
                ),
                textAlign: TextAlign.center,
              ),
            ],
            if (action != null) ...[
              const SizedBox(height: AbTokens.space14),
              action!,
            ],
          ],
        ),
      ),
    );
  }
}
