import 'dart:math' as math;

import 'package:flutter/widgets.dart';

import '../foundations/icons.dart';
import '../foundations/theme.dart';
import '../foundations/tokens.dart';
import '../primitives/focus_ring.dart';
import '../primitives/interaction.dart';

/// A check box with a 16px indicator inside a full-height interaction target.
///
/// [value] is Flutter's `bool?` model: true is checked, false unchecked and
/// null indeterminate. Null renders as indeterminate only when [tristate] is
/// set; otherwise it is shown as unchecked, so a host cannot show a mixed state
/// by accident. The host owns the value: [onChanged] reports the requested next
/// value and the box shows exactly what the host passes back.
///
/// The indicator and the label are one target, so a tap anywhere on the row
/// toggles once. [onChanged] null disables the control; [readOnly] keeps it
/// focusable and announced but inert.
class CarbonCheckbox extends StatelessWidget {
  const CarbonCheckbox({
    super.key,
    required this.value,
    required this.onChanged,
    this.tristate = false,
    this.label,
    this.labelText,
    this.semanticLabel,
    this.helperText,
    this.errorText,
    this.invalid = false,
    this.readOnly = false,
    this.focusNode,
    this.autofocus = false,
  });

  /// Checked (true), unchecked (false) or, with [tristate], indeterminate
  /// (null).
  final bool? value;

  /// Requests the next value; null disables the checkbox.
  final ValueChanged<bool?>? onChanged;

  /// Enables the indeterminate state. Activation then cycles unchecked,
  /// checked, indeterminate.
  final bool tristate;

  /// A custom label. Without [labelText] or [semanticLabel] its semantics merge
  /// into the checkbox's node and name it. With either, that name wins and the
  /// label keeps its own nodes, so interactive content in it (a link) stays
  /// reachable instead of being folded into the checkbox.
  final Widget? label;

  /// A plain text label; also the accessible name.
  final String? labelText;

  /// Accessible name for a checkbox shown without visible text.
  final String? semanticLabel;

  final String? helperText;

  /// Validation message shown with an icon and announced with the control;
  /// takes the place of [helperText].
  final String? errorText;

  /// Draws the invalid border without a message of its own, for a checkbox
  /// whose group shows the error once. Implied by [errorText].
  final bool invalid;

  final bool readOnly;
  final FocusNode? focusNode;
  final bool autofocus;

  bool get _isMixed => tristate && value == null;
  bool get _isChecked => value == true;

  bool? _next() {
    if (!tristate) return !_isChecked;
    return switch (value) {
      false => true,
      true => null,
      null => false,
    };
  }

  @override
  Widget build(BuildContext context) {
    final theme = CarbonTheme.of(context);
    final colors = theme.colors;
    final enabled = onChanged != null;
    final invalid = errorText != null || this.invalid;
    final message = errorText ?? helperText;
    final hasLabel = label != null || labelText != null;
    final name = labelText ?? semanticLabel;
    final labelStyle = theme.typography.control.copyWith(
      color: enabled ? colors.textPrimary : colors.textDisabled,
    );

    Widget? labelWidget = label;
    if (labelWidget == null && labelText != null) {
      labelWidget = Text(labelText!, style: labelStyle);
    }

    final row = CarbonInteraction(
      onPressed: readOnly
          ? (enabled ? _ignore : null)
          : (enabled ? () => onChanged!(_next()) : null),
      focusNode: focusNode,
      autofocus: autofocus,
      button: false,
      label: name,
      hint: message,
      checked: _isChecked,
      mixed: _isMixed,
      excludeChildSemantics: labelText != null && label == null,
      mouseCursor: readOnly ? SystemMouseCursors.basic : null,
      builder: (context, state, _) {
        final box = CarbonFocusRing(
          visible: state.focusVisible,
          borderRadius: _CheckboxIndicator.radius,
          child: _CheckboxIndicator(
            checked: _isChecked,
            mixed: _isMixed,
            enabled: enabled,
            readOnly: readOnly,
            invalid: invalid,
          ),
        );
        if (!hasLabel) {
          return SizedBox.square(
            dimension: theme.minTarget,
            child: Center(child: box),
          );
        }
        // The indicator is centred on the label's first line, so a wrapped
        // label never detaches it from the line it names.
        final lineHeight = MediaQuery.textScalerOf(
          context,
        ).scale(labelStyle.fontSize! * (labelStyle.height ?? 1));
        final pad = lineHeight + 2 * CarbonSpacing.spacing02 >= theme.minTarget
            ? CarbonSpacing.spacing02
            : (theme.minTarget - lineHeight) / 2;
        return Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            // Carbon seats the box 3px in and starts the text 30px in
            // (checkbox.scss:78, :84, :124).
            const SizedBox(width: _boxInset),
            SizedBox(
              height: lineHeight + 2 * pad,
              child: Center(child: box),
            ),
            const SizedBox(width: _labelGap),
            Flexible(
              child: Padding(
                padding: EdgeInsets.symmetric(vertical: pad),
                child: DefaultTextStyle.merge(
                  style: labelStyle,
                  // Its own boundary once the box has another name, so the
                  // label's nodes stay out of the checkbox's node.
                  child: label != null && name != null
                      ? Semantics(
                          container: true,
                          explicitChildNodes: true,
                          child: labelWidget!,
                        )
                      : labelWidget!,
                ),
              ),
            ),
          ],
        );
      },
    );

    // A custom label with no other name is the only name the box has, so it
    // joins the box's node. Once a name exists, merging would read the label
    // twice or contradict the name, and would fold a link into the checkbox.
    final labelNamesBox = label != null && name == null;
    final semantic = Semantics(readOnly: readOnly ? true : null, child: row);
    final target = labelNamesBox || label == null
        ? MergeSemantics(child: semantic)
        : semantic;
    // Always a Column, so the control keeps its element, focus node and
    // hover state when a message appears or clears.
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        target,
        if (message != null)
          _FieldMessage(text: message, error: invalid, enabled: enabled),
      ],
    );
  }

  static const double _boxInset = 3;
  static const double _labelGap = 11;

  static void _ignore() {}
}

/// The helper or error line under a checkbox or group.
class _FieldMessage extends StatelessWidget {
  const _FieldMessage({
    required this.text,
    required this.error,
    required this.enabled,
  });

  final String text;
  final bool error;
  final bool enabled;

  @override
  Widget build(BuildContext context) {
    final theme = CarbonTheme.of(context);
    final colors = theme.colors;
    final style = theme.typography.helper.copyWith(
      color: error
          ? colors.textError
          : (enabled ? colors.textHelper : colors.textDisabled),
    );
    return ExcludeSemantics(
      child: Padding(
        padding: const EdgeInsetsDirectional.only(
          bottom: CarbonSpacing.spacing02,
        ),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            if (error) ...[
              // checkbox.scss:258 seats the glyph 1px down and 3px in; the
              // text follows at spacing-03 (:294).
              Padding(
                padding: const EdgeInsetsDirectional.only(
                  start: 3,
                  top: 1,
                  end: 1,
                ),
                child: CarbonIcon(
                  CarbonIcons.warningFilled,
                  size: 16,
                  color: colors.supportError,
                ),
              ),
              const SizedBox(width: CarbonSpacing.spacing03),
            ],
            Flexible(child: Text(text, style: style)),
          ],
        ),
      ),
    );
  }
}

class _CheckboxIndicator extends StatelessWidget {
  const _CheckboxIndicator({
    required this.checked,
    required this.mixed,
    required this.enabled,
    required this.readOnly,
    required this.invalid,
  });

  final bool checked;
  final bool mixed;
  final bool enabled;
  final bool readOnly;
  final bool invalid;

  static const double _size = 16;
  static const BorderRadius radius = BorderRadius.all(Radius.circular(2));

  @override
  Widget build(BuildContext context) {
    final colors = CarbonTheme.of(context).colors;
    final filled = (checked || mixed) && !readOnly;
    final Color border;
    if (!enabled || readOnly) {
      border = colors.iconDisabled;
    } else if (invalid) {
      border = colors.supportError;
    } else {
      border = colors.iconPrimary;
    }
    final Color fill = filled
        ? (enabled ? colors.iconPrimary : colors.iconDisabled)
        : const Color(0x00000000);
    final Color glyph = filled
        ? colors.iconInverse
        : (enabled ? colors.iconPrimary : colors.iconDisabled);
    final showGlyph = checked || mixed;
    return SizedBox.square(
      dimension: _size,
      child: CustomPaint(
        foregroundPainter: showGlyph
            ? _CheckMarkPainter(mixed: mixed, color: glyph)
            : null,
        child: DecoratedBox(
          decoration: BoxDecoration(
            color: fill,
            borderRadius: radius,
            // Invalid only recolours the 1px border (checkbox.scss:219).
            border: Border.all(color: border),
          ),
        ),
      ),
    );
  }
}

/// Carbon draws the mark from borders, not a glyph: a 9x5 L of 1.5px strokes
/// turned -45 degrees about its bottom-right corner, or an 8x2 bar
/// (checkbox.scss:131-135, :171-173). A scaled icon glyph is half that weight.
class _CheckMarkPainter extends CustomPainter {
  const _CheckMarkPainter({required this.mixed, required this.color});

  final bool mixed;
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()..color = color;
    if (mixed) {
      canvas.drawRect(
        Rect.fromCenter(center: size.center(Offset.zero), width: 8, height: 2),
        paint,
      );
      return;
    }
    paint
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.5
      ..strokeJoin = StrokeJoin.miter;
    // Stroke centrelines of the element's left and bottom borders, in the
    // box's coordinates before the turn.
    const pivot = Offset(13, 5.5);
    final path = Path()
      ..moveTo(4.75, 0.5)
      ..lineTo(4.75, 4.75)
      ..lineTo(13, 4.75);
    canvas
      ..save()
      ..translate(pivot.dx, pivot.dy)
      ..rotate(-math.pi / 4)
      ..translate(-pivot.dx, -pivot.dy)
      ..drawPath(path, paint)
      ..restore();
  }

  @override
  bool shouldRepaint(_CheckMarkPainter old) =>
      old.mixed != mixed || old.color != color;
}

/// One entry of a [CarbonCheckboxGroup]; identity is [value].
@immutable
class CarbonCheckboxItem<T> {
  const CarbonCheckboxItem({
    required this.value,
    required this.label,
    this.enabled = true,
    this.helperText,
  });

  final T value;
  final String label;
  final bool enabled;
  final String? helperText;
}

/// A legend plus a vertical list of checkboxes with a group-level helper or
/// error.
///
/// The host owns [selected]; [onChanged] reports the full next selection,
/// ordered by [items] and keeping any selected value not listed there. The group is announced with its legend as
/// a named container so each checkbox is read in context.
class CarbonCheckboxGroup<T> extends StatelessWidget {
  const CarbonCheckboxGroup({
    super.key,
    required this.legend,
    required this.items,
    required this.selected,
    required this.onChanged,
    this.helperText,
    this.errorText,
    this.readOnly = false,
  });

  final String legend;
  final List<CarbonCheckboxItem<T>> items;
  final Set<T> selected;

  /// Receives the whole next selection; null disables every checkbox.
  final ValueChanged<Set<T>>? onChanged;

  final String? helperText;
  final String? errorText;
  final bool readOnly;

  @override
  Widget build(BuildContext context) {
    final theme = CarbonTheme.of(context);
    final colors = theme.colors;
    final enabled = onChanged != null;
    final invalid = errorText != null;
    final message = errorText ?? helperText;
    return Semantics(
      container: true,
      explicitChildNodes: true,
      label: legend,
      hint: message,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          ExcludeSemantics(
            child: Padding(
              padding: const EdgeInsetsDirectional.only(
                bottom: CarbonSpacing.spacing03,
              ),
              child: Text(
                legend,
                style: theme.typography.label.copyWith(
                  color: enabled ? colors.textSecondary : colors.textDisabled,
                ),
              ),
            ),
          ),
          for (final item in items)
            CarbonCheckbox(
              key: ValueKey<T>(item.value),
              value: selected.contains(item.value),
              labelText: item.label,
              helperText: item.helperText,
              invalid: invalid,
              readOnly: readOnly,
              onChanged: enabled && item.enabled
                  ? (checked) {
                      final known = {for (final i in items) i.value};
                      // Values the host selected that this list does not show
                      // are not the user's to drop.
                      final next = <T>{
                        for (final value in selected)
                          if (!known.contains(value)) value,
                        for (final other in items)
                          if (other.value == item.value
                              ? checked == true
                              : selected.contains(other.value))
                            other.value,
                      };
                      onChanged!(next);
                    }
                  : null,
            ),
          if (message != null)
            _FieldMessage(text: message, error: invalid, enabled: enabled),
        ],
      ),
    );
  }
}
