import 'dart:math' as math;

import 'package:flutter/widgets.dart';

import '../foundations/icons.dart';
import '../foundations/localizations.dart';
import '../foundations/theme.dart';
import '../foundations/tokens.dart';
import 'button.dart';
import 'loading.dart';

/// Where an operation shown by [CarbonInlineLoading] currently stands.
enum CarbonInlineLoadingStatus {
  /// Nothing is happening; only the description, if any, is shown.
  inactive,

  /// Work is in progress.
  active,

  /// The work completed.
  finished,

  /// The work failed.
  error,
}

/// Compact pending, success and failure feedback beside an action.
///
/// A fixed 16px indicator box keeps the description aligned whichever status
/// is showing. The host owns the status and any timing, for instance when a
/// "finished" message goes away; this widget never changes status itself.
///
/// A status change is announced once through a polite live region; the
/// spinner's animation is not announced. On [CarbonInlineLoadingStatus.error]
/// an explicit retry button appears when [onRetry] is given. Retrying is always
/// a user action.
class CarbonInlineLoading extends StatelessWidget {
  const CarbonInlineLoading({
    super.key,
    required this.status,
    this.description,
    this.onRetry,
    this.retryLabel,
    this.statusLabel,
  });

  final CarbonInlineLoadingStatus status;

  /// Text beside the indicator, e.g. "Saving...".
  final String? description;

  /// Shows a ghost "Retry" button after the description while [status] is
  /// error.
  final VoidCallback? onRetry;

  /// Overrides the localized retry label.
  final String? retryLabel;

  /// Overrides the announced status word (localized "Loading", "Success",
  /// "Error" by default).
  final String? statusLabel;

  static const double _indicator = 16;

  @override
  Widget build(BuildContext context) {
    final theme = CarbonTheme.of(context);
    final loc = CarbonLocalizations.of(context);
    final colors = theme.colors;

    final Widget indicator = switch (status) {
      CarbonInlineLoadingStatus.inactive => const SizedBox.shrink(),
      CarbonInlineLoadingStatus.active => const CarbonSpinner(size: _indicator),
      CarbonInlineLoadingStatus.finished => CarbonIcon(
        CarbonIcons.checkmarkFilled,
        size: _indicator,
        color: colors.supportSuccess,
      ),
      CarbonInlineLoadingStatus.error => CarbonIcon(
        CarbonIcons.errorFilled,
        size: _indicator,
        color: colors.supportError,
      ),
    };

    final style = theme.typography.body.copyWith(color: colors.textSecondary);
    final text = description;
    // Center the 16px box on the first text line, so a wrapped description
    // keeps its indicator at the top.
    final lineHeight = MediaQuery.textScalerOf(
      context,
    ).scale((style.fontSize ?? 14) * (style.height ?? 1.3));
    final box = SizedBox(
      width: _indicator,
      height: math.max(_indicator, lineHeight),
      child: Center(child: SizedBox.square(dimension: _indicator, child: indicator)),
    );

    final status0 = switch (status) {
      CarbonInlineLoadingStatus.inactive => null,
      CarbonInlineLoadingStatus.active => statusLabel ?? loc.loading,
      CarbonInlineLoadingStatus.finished => statusLabel ?? loc.success,
      CarbonInlineLoadingStatus.error => statusLabel ?? loc.error,
    };

    final row = Row(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        box,
        if (text != null) ...[
          const SizedBox(width: CarbonSpacing.spacing03),
          Flexible(child: Text(text, style: style)),
        ],
      ],
    );

    final announced = Semantics(
      container: true,
      liveRegion: status != CarbonInlineLoadingStatus.inactive,
      label: text,
      value: status0,
      child: ExcludeSemantics(child: row),
    );

    final showRetry =
        status == CarbonInlineLoadingStatus.error && onRetry != null;
    if (!showRetry) return announced;
    return Wrap(
      crossAxisAlignment: WrapCrossAlignment.center,
      spacing: CarbonSpacing.spacing03,
      runSpacing: CarbonSpacing.spacing02,
      children: [
        announced,
        CarbonButton(
          label: retryLabel ?? loc.retry,
          kind: CarbonButtonKind.ghost,
          size: CarbonButtonSize.small,
          onPressed: onRetry,
        ),
      ],
    );
  }
}
