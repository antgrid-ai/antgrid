import 'package:flutter/semantics.dart';
import 'package:flutter/widgets.dart';

import '../foundations/icons.dart';
import '../foundations/localizations.dart';
import '../foundations/theme.dart';
import '../foundations/tokens.dart';

/// Label, helper and validation text around a form field.
///
/// Lays out, top to bottom: the label (`label` type role), the field
/// ([child], usually a [CarbonFieldBox]), then either the error, the warning
/// or the helper text. Error and warning replace the helper, as in Carbon.
///
/// Validation is host-owned: pass [errorText] / [warnText] when the host has
/// decided the value is invalid. Disabled and read-only fields suppress
/// validation messages, matching Carbon; [resolvedError] and
/// [resolvedWarning] report what is actually shown, so the field box can be
/// given matching `invalid` / `warn` flags.
///
/// Requiredness is never a color-only marker. A required field is announced
/// with [CarbonLocalizations.requiredField] and Flutter's `isRequired` flag;
/// with [showOptional], optional fields instead show the localized optional
/// suffix after the label.
///
/// ### Semantics for text fields
///
/// By default the label, helper and error are separate text nodes. A text
/// field should instead fold them into its editable's node, so a screen
/// reader announces "Name, Required, Invalid email" on the field itself:
///
/// ```dart
/// MergeSemantics(
///   child: CarbonFieldFrame(
///     label: 'Email',
///     required: true,
///     errorText: error,
///     child: CarbonFieldBox(invalid: error != null, child: editable),
///   ),
/// )
/// ```
///
/// Where merging is not possible (the field's node already carries its own
/// label), set [excludeTextSemantics] and apply [resolvedLabel],
/// [resolvedError] and [required] to the editable's semantics yourself.
class CarbonFieldFrame extends StatelessWidget {
  const CarbonFieldFrame({
    super.key,
    this.label,
    this.helperText,
    this.errorText,
    this.warnText,
    this.required = false,
    this.showOptional = false,
    this.enabled = true,
    this.readOnly = false,
    this.excludeTextSemantics = false,
    required this.child,
  });

  final String? label;
  final String? helperText;

  /// The host's validation error. Shown in place of the helper text.
  final String? errorText;

  /// A non-blocking warning, shown when there is no error.
  final String? warnText;

  final bool required;

  /// Appends [CarbonLocalizations.optionalField] to the label of fields that
  /// are not [required], for forms where most fields are required.
  final bool showOptional;

  final bool enabled;
  final bool readOnly;

  /// Removes the label, helper and message texts from the semantics tree, for
  /// fields that carry those strings on their own node.
  final bool excludeTextSemantics;

  final Widget child;

  bool get _validates => enabled && !readOnly;

  /// The label as displayed and announced, including the optional suffix.
  String? resolvedLabel(BuildContext context) {
    final text = label;
    if (text == null || text.isEmpty) return null;
    if (!showOptional || required) return text;
    return '$text ${CarbonLocalizations.of(context).optionalField}';
  }

  /// The error actually shown: null when disabled, read-only or empty.
  String? get resolvedError {
    final text = errorText;
    return _validates && text != null && text.isNotEmpty ? text : null;
  }

  /// The warning actually shown: null when an error wins, or when disabled,
  /// read-only or empty.
  String? get resolvedWarning {
    final text = warnText;
    return _validates && resolvedError == null && text != null && text.isNotEmpty
        ? text
        : null;
  }

  @override
  Widget build(BuildContext context) {
    final theme = CarbonTheme.of(context);
    final colors = theme.colors;
    final type = theme.typography;
    final messages = CarbonLocalizations.of(context);
    final labelText = resolvedLabel(context);
    final error = resolvedError;
    final warning = resolvedWarning;
    final helper = helperText;

    Widget text(String value, TextStyle style) {
      final widget = Text(value, style: style);
      return excludeTextSemantics ? ExcludeSemantics(child: widget) : widget;
    }

    final Widget? labelWidget = labelText == null
        ? null
        : text(
            labelText,
            type.label.copyWith(
              color: enabled ? colors.textSecondary : colors.textDisabled,
            ),
          );

    final String? message;
    final Color messageColor;
    if (error != null) {
      message = error;
      messageColor = colors.textError;
    } else if (warning != null) {
      message = warning;
      messageColor = colors.textPrimary;
    } else {
      message = helper == null || helper.isEmpty ? null : helper;
      messageColor = enabled ? colors.textHelper : colors.textDisabled;
    }

    Widget field = child;
    if (!excludeTextSemantics) {
      // Carried on a node that a surrounding MergeSemantics folds into the
      // editable, so requiredness and validity are announced on the field.
      field = Semantics(
        isRequired: required ? true : null,
        hint: required ? messages.requiredField : null,
        validationResult: error != null
            ? SemanticsValidationResult.invalid
            : SemanticsValidationResult.none,
        child: field,
      );
    }

    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        if (labelWidget != null) ...<Widget>[
          labelWidget,
          const SizedBox(height: CarbonSpacing.spacing03),
        ],
        field,
        if (message != null) ...<Widget>[
          const SizedBox(height: CarbonSpacing.spacing02),
          text(message, type.helper.copyWith(color: messageColor)),
        ],
      ],
    );
  }
}

/// The Carbon field surface shared by text input, select, dropdown and
/// search.
///
/// Fills with the current layer's `field` color (hover `fieldHover`), draws a
/// 1px `borderStrong` bottom rule, and grows from
/// [CarbonThemeData.controlHeight] when the content needs more room (enlarged
/// text, multiple lines).
///
/// State treatments, all painted over the content so no state changes the
/// layout:
/// * [focused]: 2px inset `focus` outline. Wins over the invalid outline.
/// * [invalid]: 2px `supportError` outline plus a trailing error glyph.
/// * [warn]: a trailing warning glyph, no outline.
/// * [readOnly]: transparent fill, `borderSubtle` rule, no hover.
/// * disabled ([enabled] false): no rule, disabled text and icon colors.
///
/// Invalid and warning treatments are suppressed when disabled or read-only,
/// matching [CarbonFieldFrame]. The glyphs are decorative; the frame's message
/// text carries the meaning.
///
/// Slots: [leading] sits inside the start padding. [trailing] is for glyphs
/// (a chevron) and keeps the end padding; [trailingAction] is for buttons
/// (clear, reveal) and sits flush with the end edge so its full target fits
/// inside the field.
class CarbonFieldBox extends StatefulWidget {
  const CarbonFieldBox({
    super.key,
    required this.child,
    this.leading,
    this.trailing,
    this.trailingAction,
    this.focused = false,
    this.enabled = true,
    this.readOnly = false,
    this.invalid = false,
    this.warn = false,
    this.minHeight,
    this.crossAxisAlignment = CrossAxisAlignment.center,
  });

  final Widget child;
  final Widget? leading;
  final Widget? trailing;
  final Widget? trailingAction;

  /// Whether the field's editable or trigger holds focus. The box does not
  /// observe focus itself, because the focusable widget lives inside it.
  final bool focused;

  final bool enabled;
  final bool readOnly;
  final bool invalid;
  final bool warn;

  /// Overrides [CarbonThemeData.controlHeight] for size variants. Still a
  /// minimum.
  final double? minHeight;

  /// [CrossAxisAlignment.start] for multi-line content.
  final CrossAxisAlignment crossAxisAlignment;

  @override
  State<CarbonFieldBox> createState() => _CarbonFieldBoxState();
}

class _CarbonFieldBoxState extends State<CarbonFieldBox> {
  bool _hovered = false;

  void _setHovered(bool value) {
    if (_hovered != value) setState(() => _hovered = value);
  }

  @override
  Widget build(BuildContext context) {
    final theme = CarbonTheme.of(context);
    final colors = theme.colors;
    final level = CarbonLayer.of(context);
    final enabled = widget.enabled;
    final readOnly = widget.readOnly;
    final validates = enabled && !readOnly;
    final invalid = validates && widget.invalid;
    final warn = validates && !invalid && widget.warn;
    final hoverable = enabled && !readOnly;

    final Color fill;
    if (readOnly) {
      fill = const Color(0x00000000);
    } else if (hoverable && _hovered) {
      fill = theme.fieldHover(level);
    } else {
      fill = theme.field(level);
    }

    final Color? rule = !enabled
        ? null
        : readOnly
        ? theme.borderSubtle(level)
        : theme.borderStrong(level);

    final Color? outline = widget.focused
        ? colors.focus
        : invalid
        ? colors.supportError
        : null;

    final foreground = enabled ? colors.textPrimary : colors.textDisabled;
    final iconColor = enabled ? colors.iconPrimary : colors.iconDisabled;

    Widget? status;
    if (invalid) {
      status = CarbonIcon(
        CarbonIcons.errorFilled,
        color: colors.supportError,
        // Carbon leaves the "!" unpainted so the field shows through; painting
        // it with the fill keeps that look on hover and over any backdrop.
        innerColor: fill.a == 0 ? theme.field(level) : fill,
      );
    } else if (warn) {
      status = CarbonIcon(
        CarbonIcons.warningAltFilled,
        color: colors.supportWarning,
        // Carbon's warning "!" is black in every theme for contrast against
        // yellow; the near-black icon role flips between light and dark.
        innerColor: theme.brightness == Brightness.light
            ? colors.iconPrimary
            : colors.iconInverse,
      );
    }

    final padX = theme.controlPaddingX;
    final trailingAction = widget.trailingAction;
    final children = <Widget>[
      if (widget.leading != null) ...<Widget>[
        widget.leading!,
        const SizedBox(width: CarbonSpacing.spacing03),
      ],
      Expanded(child: widget.child),
      if (status != null) ...<Widget>[
        const SizedBox(width: CarbonSpacing.spacing03),
        status,
      ],
      if (widget.trailing != null) ...<Widget>[
        const SizedBox(width: CarbonSpacing.spacing03),
        widget.trailing!,
      ],
      if (trailingAction != null) ...<Widget>[
        if (status != null || widget.trailing != null)
          const SizedBox(width: CarbonSpacing.spacing02),
        trailingAction,
      ],
    ];

    return MouseRegion(
      onEnter: hoverable ? (_) => _setHovered(true) : null,
      onExit: (_) => _setHovered(false),
      child: CustomPaint(
        foregroundPainter: _FieldPainter(rule: rule, outline: outline),
        child: DecoratedBox(
          decoration: BoxDecoration(color: fill),
          child: ConstrainedBox(
            constraints: BoxConstraints(
              minHeight: widget.minHeight ?? theme.controlHeight,
            ),
            child: Padding(
              padding: EdgeInsetsDirectional.only(
                start: padX,
                end: trailingAction == null ? padX : 0,
                top: CarbonSpacing.spacing02,
                bottom: CarbonSpacing.spacing02,
              ),
              child: DefaultTextStyle.merge(
                style: theme.typography.control.copyWith(color: foreground),
                child: IconTheme.merge(
                  data: IconThemeData(color: iconColor, size: theme.iconSize),
                  child: Row(
                    crossAxisAlignment: widget.crossAxisAlignment,
                    children: children,
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _FieldPainter extends CustomPainter {
  const _FieldPainter({required this.rule, required this.outline});

  final Color? rule;
  final Color? outline;

  @override
  void paint(Canvas canvas, Size size) {
    final ruleColor = rule;
    if (ruleColor != null) {
      canvas.drawRect(
        Rect.fromLTWH(
          0,
          size.height - CarbonBorders.hairline,
          size.width,
          CarbonBorders.hairline,
        ),
        Paint()..color = ruleColor,
      );
    }
    final outlineColor = outline;
    if (outlineColor != null) {
      const width = CarbonBorders.focus;
      final rect = (Offset.zero & size).deflate(width / 2);
      if (rect.width > 0 && rect.height > 0) {
        canvas.drawRect(
          rect,
          Paint()
            ..color = outlineColor
            ..style = PaintingStyle.stroke
            ..strokeWidth = width,
        );
      }
    }
  }

  @override
  bool shouldRepaint(_FieldPainter old) =>
      old.rule != rule || old.outline != outline;
}
