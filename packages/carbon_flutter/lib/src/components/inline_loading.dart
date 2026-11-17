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
class CarbonInlineLoading extends StatefulWidget {
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

  @override
  State<CarbonInlineLoading> createState() => _CarbonInlineLoadingState();
}

class _CarbonInlineLoadingState extends State<CarbonInlineLoading> {
  static const double _indicator = 16;

  final FocusNode _retryNode = FocusNode(debugLabel: 'CarbonInlineLoading retry');

  // Programmatic-only landing spot for focus when the retry button goes away.
  final FocusNode _anchor = FocusNode(
    debugLabel: 'CarbonInlineLoading',
    skipTraversal: true,
  );

  bool _showRetry(CarbonInlineLoading w) =>
      w.status == CarbonInlineLoadingStatus.error && w.onRetry != null;

  @override
  void didUpdateWidget(CarbonInlineLoading oldWidget) {
    super.didUpdateWidget(oldWidget);
    // The activated retry button unmounts when the host leaves the error state;
    // keep focus here rather than dropping it to the root scope.
    if (_showRetry(oldWidget) && !_showRetry(widget) && _retryNode.hasFocus) {
      _anchor.requestFocus();
    }
  }

  @override
  void dispose() {
    _retryNode.dispose();
    _anchor.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final status = widget.status;
    final description = widget.description;
    final statusLabel = widget.statusLabel;
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

    // label-02 in Carbon's compact sizes; touch keeps its body text.
    final style = (theme.isTouch
            ? theme.typography.body
            : theme.typography.control)
        .copyWith(color: colors.textSecondary);
    final text = description;
    // Center the 16px box on the first text line, so a wrapped description
    // keeps its indicator at the top.
    // Flutter scales the font size first and applies the line-height multiple
    // to the result, which differs from scaling the product under a nonlinear
    // text scaler.
    final lineHeight =
        MediaQuery.textScalerOf(context).scale(style.fontSize ?? 14) *
        (style.height ?? 1.3);
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

    // Carbon renders no indicator container when inactive, so the description
    // starts at the edge instead of after an empty slot.
    final inactive = status == CarbonInlineLoadingStatus.inactive;
    final row = Row(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (!inactive) box,
        if (text != null) ...[
          if (!inactive) const SizedBox(width: CarbonSpacing.spacing03),
          Flexible(child: Text(text, style: style)),
        ],
      ],
    );

    // The status word is part of the label because assistive technology
    // re-announces a live region only when its label changes.
    final spoken = switch ((text, status0)) {
      (final String t, final String w) => '$t, $w',
      (final String t, null) => t,
      (null, final String w) => w,
      _ => null,
    };
    final announced = Semantics(
      container: true,
      liveRegion: status != CarbonInlineLoadingStatus.inactive,
      label: spoken,
      child: ExcludeSemantics(child: row),
    );

    final showRetry = _showRetry(widget);
    return Focus(
      focusNode: _anchor,
      includeSemantics: false,
      child: Wrap(
        crossAxisAlignment: WrapCrossAlignment.center,
        spacing: CarbonSpacing.spacing03,
        runSpacing: CarbonSpacing.spacing02,
        children: [
          ConstrainedBox(
            constraints: BoxConstraints(minHeight: theme.isTouch ? 0 : 32),
            child: Center(widthFactor: 1, child: announced),
          ),
          if (showRetry)
            CarbonButton(
              label: widget.retryLabel ?? loc.retry,
              kind: CarbonButtonKind.ghost,
              size: CarbonButtonSize.small,
              focusNode: _retryNode,
              onPressed: widget.onRetry,
            ),
        ],
      ),
    );
  }
}
