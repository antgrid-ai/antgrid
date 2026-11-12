import 'dart:math' as math;

import 'package:flutter/rendering.dart';
import 'package:flutter/widgets.dart';

import '../foundations/localizations.dart';
import '../foundations/theme.dart';
import '../foundations/tokens.dart';
import '../primitives/focus_ring.dart';
import '../primitives/interaction.dart';
import 'loading.dart';
import 'tooltip.dart';

/// Carbon's button treatments.
enum CarbonButtonKind {
  /// The single most important action in a region.
  primary,

  /// An alternative to [primary] that carries equal weight, e.g. in a pair.
  secondary,

  /// An outlined, lower-emphasis action.
  tertiary,

  /// A text-only action with no resting container.
  ghost,

  /// A destructive action in the strongest treatment.
  danger,

  /// An outlined destructive action.
  dangerTertiary,

  /// A text-only destructive action.
  dangerGhost,
}

/// Explicit heights for [CarbonButton], from Carbon's size scale.
///
/// Touch density never renders a button below the touch target whatever size
/// is requested, and enlarged text grows a button past these heights.
enum CarbonButtonSize {
  /// Carbon's `xs`, for icon-only triggers in dense rows. Compact density
  /// only: it is the one size allowed under the 32 compact target, and touch
  /// density still floors it to the touch target.
  extraSmall(CarbonSizes.xs),
  small(CarbonSizes.sm),
  medium(CarbonSizes.md),
  large(CarbonSizes.lg),
  extraLarge(CarbonSizes.xl);

  const CarbonButtonSize(this.height);

  final double height;
}

void _ignore() {}

/// A Carbon button.
///
/// * Disabled: `onPressed` null. The button is inert and leaves the focus
///   order.
/// * Busy: [busy] true shows an inline spinner in place of the icon (or over
///   the label of a text-only button) without changing the button's size, and
///   swallows activation so a pending action cannot be submitted twice. The
///   button keeps focus and announces the localized "Loading". The host owns
///   the busy flag; the button never sets it.
/// * Height follows density (32 compact, [CarbonThemeData.touchTarget] touch) unless [size] is given.
///   Text scaling grows the button; labels wrap rather than clip.
/// * [CarbonButton.iconOnly] has a square footprint and requires a
///   `semanticLabel`.
///
/// The [icon] is any widget, typically a `CarbonIcon`; it is sized to the
/// density's icon size and sits at the trailing edge, as Carbon places it.
class CarbonButton extends StatelessWidget {
  const CarbonButton({
    super.key,
    required String this.label,
    this.onPressed,
    this.kind = CarbonButtonKind.primary,
    this.size,
    this.icon,
    this.busy = false,
    this.expand = false,
    this.minWidth,
    this.semanticLabel,
    this.focusNode,
    this.autofocus = false,
    this.expanded,
    this.maxLines,
    this.leading,
  }) : iconSize = null,
       hoverFill = true,
       _iconOnly = false;

  /// A square button showing only [icon]. [semanticLabel] names it for
  /// assistive technology.
  const CarbonButton.iconOnly({
    super.key,
    required Widget this.icon,
    required String this.semanticLabel,
    this.onPressed,
    this.kind = CarbonButtonKind.ghost,
    this.size,
    this.busy = false,
    this.focusNode,
    this.autofocus = false,
    this.iconSize,
    this.hoverFill = true,
    this.expanded,
  }) : label = null,
       maxLines = null,
       leading = null,
       expand = false,
       minWidth = null,
       _iconOnly = true;

  /// The visible text; null for an icon-only button.
  final String? label;

  /// Clamps the label to this many lines with an ellipsis. Null (the default)
  /// lets the label wrap to whatever it needs. Ignored by the icon-only form.
  final int? maxLines;

  /// For a button that discloses content: whether that content is showing.
  /// Null (the default) says nothing; true or false announces the expanded or
  /// collapsed state. The host owns the state and what it reveals.
  final bool? expanded;

  /// Activation callback. Null disables the button.
  final VoidCallback? onPressed;

  final CarbonButtonKind kind;

  /// Null uses the density's default control height.
  final CarbonButtonSize? size;

  final Widget? icon;

  /// A small non-interactive mark before the label, such as a status dot
  /// that belongs to the value the label names. Excluded from semantics; say
  /// what it means in [semanticLabel].
  final Widget? leading;

  /// A host-owned pending flag; see the class documentation.
  final bool busy;

  /// Fills the available width with the label at the start and the icon at the
  /// end. Requires a bounded width.
  final bool expand;

  /// A floor under the button's width. With an [icon] the icon stays at the
  /// trailing edge of the extra width, as Carbon pins it.
  final double? minWidth;

  /// Overrides the announced name; defaults to [label].
  final String? semanticLabel;

  final FocusNode? focusNode;
  final bool autofocus;

  /// Glyph size of an icon-only button; null follows the density's icon size.
  /// The button keeps its own footprint, so a larger glyph gains no tap area.
  final double? iconSize;

  /// False keeps an icon-only ghost button's fill clear and its glyph colour
  /// unchanged on hover and press, as Carbon's notification close buttons are;
  /// the focus ring still shows.
  final bool hoverFill;

  final bool _iconOnly;

  static const double _maxWidth = 320;

  // (lg 48 - 18 line height) / 2 - 1 border, the cap in _mixins.scss.
  static const double _pinnedPadding = 14;

  bool get _isFilled => switch (kind) {
    CarbonButtonKind.primary ||
    CarbonButtonKind.secondary ||
    CarbonButtonKind.danger => true,
    _ => false,
  };

  @override
  Widget build(BuildContext context) {
    final theme = CarbonTheme.of(context);
    final loc = CarbonLocalizations.of(context);
    final disabled = onPressed == null;
    final extraSmall = size == CarbonButtonSize.extraSmall && !theme.isTouch;
    final height = extraSmall
        ? CarbonSizes.xs
        : math.max(size?.height ?? theme.controlHeight, theme.minTarget);
    final name = semanticLabel ?? label ?? '';
    // Carbon caps a button's block padding at what a 48px button needs, so a
    // taller one keeps its label near the top instead of centring it.
    final topPinned =
        !_iconOnly && !theme.isTouch && height > CarbonSizes.lg;
    final hPad = switch ((_iconOnly, extraSmall)) {
      (true, true) => CarbonSpacing.spacing02,
      (true, false) || (false, true) => CarbonSpacing.spacing03,
      (false, false) => CarbonSpacing.spacing05,
    };
    final vPad = extraSmall
        ? 0.0
        : CarbonSpacing.spacing02 + CarbonSpacing.spacing01;

    final button = CarbonInteraction(
      onPressed: disabled ? null : (busy ? _ignore : onPressed),
      focusNode: focusNode,
      autofocus: autofocus,
      expanded: expanded,
      label: name,
      value: busy ? loc.loading : null,
      excludeChildSemantics: true,
      mouseCursor: busy ? SystemMouseCursors.basic : null,
      builder: (context, state, _) {
        // A busy button reads as active, not disabled, but gives no hover or
        // press feedback because pressing does nothing.
        final feedback =
            !busy &&
            (hoverFill ||
                !_iconOnly ||
                (kind != CarbonButtonKind.ghost &&
                    kind != CarbonButtonKind.dangerGhost));
        final hovered = state.hovered && feedback;
        final pressed = state.pressed && feedback;
        final style = _CarbonButtonStyle.resolve(
          theme,
          kind,
          disabled: disabled,
          hovered: hovered,
          pressed: pressed,
          focused: state.focusVisible,
          iconOnly: _iconOnly,
        );
        return ConstrainedBox(
          constraints: BoxConstraints(
            minHeight: height,
            minWidth: _iconOnly
                ? height
                : (expand ? double.infinity : (minWidth ?? 0)),
            // Carbon caps a button's inline size, so a long label wraps.
            maxWidth: _iconOnly || expand ? double.infinity : _maxWidth,
          ),
          child: _ButtonStateTag(
            focused: state.focused,
            disabled: disabled,
            child: CarbonFocusRing(
            visible: state.focusVisible,
            // Outlined kinds fill on focus, so they need the inner ring too.
            onColor: _isFilled || (!disabled && style.focusFilled),
            child: DecoratedBox(
              decoration: BoxDecoration(
                color: style.background,
                border: style.border == null
                    ? null
                    : Border.all(
                        color: style.border!,
                        width: CarbonBorders.hairline,
                      ),
              ),
              child: Padding(
                // The minimum height centres the content, so extra small
                // needs no vertical padding to fit 24.
                padding: EdgeInsetsDirectional.fromSTEB(
                  hPad,
                  topPinned ? _pinnedPadding : vPad,
                  hPad,
                  topPinned ? _pinnedPadding : vPad,
                ),
                child: Align(
                  alignment: _iconOnly
                      ? Alignment.center
                      : (topPinned
                            ? AlignmentDirectional.topStart
                            : AlignmentDirectional.centerStart),
                  widthFactor: 1,
                  heightFactor: 1,
                  child: _content(context, theme, style, hPad),
                ),
              ),
            ),
            ),
          ),
        );
      },
    );
    // Sighted pointer and keyboard users get the name Carbon shows in a
    // tooltip for every icon-only button; the button already carries the name
    // as its label, so the tooltip stays out of semantics.
    return _iconOnly && name.isNotEmpty
        ? CarbonTooltip(
            message: name,
            excludeFromSemantics: true,
            child: button,
          )
        : button;
  }

  Widget _spinner(CarbonThemeData theme, _CarbonButtonStyle style) {
    return CarbonSpinner(
      size: theme.iconSize,
      color: style.foreground,
      trackColor: style.foreground.withValues(alpha: 0.3),
    );
  }

  Widget _iconBox(CarbonThemeData theme, _CarbonButtonStyle style) {
    final icon = this.icon;
    final glyph = (_iconOnly ? iconSize : null) ?? theme.iconSize;
    return SizedBox.square(
      dimension: glyph,
      child: busy
          ? _spinner(theme, style)
          : IconTheme(
              data: IconThemeData(color: style.iconColor, size: glyph),
              child: icon ?? const SizedBox.shrink(),
            ),
    );
  }

  Widget _content(
    BuildContext context,
    CarbonThemeData theme,
    _CarbonButtonStyle style,
    double hPad,
  ) {
    if (_iconOnly) return _iconBox(theme, style);

    final Widget labelText = Text(
      label!,
      maxLines: maxLines,
      overflow: maxLines == null ? null : TextOverflow.ellipsis,
      style: theme.typography.control.copyWith(color: style.foreground),
    );
    final leading = this.leading;
    final text = leading == null
        ? labelText
        : Row(
            mainAxisSize: MainAxisSize.min,
            spacing: CarbonSpacing.spacing03,
            children: [
              ExcludeSemantics(child: leading),
              Flexible(child: labelText),
            ],
          );
    final hasIcon = icon != null;
    final floor = minWidth;
    final labelWidget = hasIcon || !busy
        ? text
        // The label stays in layout, invisible, so a text-only button keeps
        // its width while the spinner is shown.
        : Stack(
            alignment: Alignment.center,
            children: [
              Visibility(
                visible: false,
                maintainSize: true,
                maintainAnimation: true,
                maintainState: true,
                child: text,
              ),
              _spinner(theme, style),
            ],
          );
    if (!hasIcon) return expand ? _fill(labelWidget) : labelWidget;
    if (floor != null && !expand) {
      // The row sizes to the floor, and spaceBetween pins the icon to the end.
      // The border is painted over the padding box and takes no layout space.
      final chrome = 2 * hPad;
      return ConstrainedBox(
        constraints: BoxConstraints(minWidth: math.max(0, floor - chrome)),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          crossAxisAlignment: CrossAxisAlignment.center,
          children: [
            Flexible(
              child: Padding(
                padding: const EdgeInsetsDirectional.only(
                  end: CarbonSpacing.spacing05,
                ),
                child: labelWidget,
              ),
            ),
            _iconBox(theme, style),
          ],
        ),
      );
    }
    final row = Row(
      mainAxisSize: expand ? MainAxisSize.max : MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.center,
      children: [
        expand ? Expanded(child: labelWidget) : Flexible(child: labelWidget),
        const SizedBox(width: CarbonSpacing.spacing05),
        _iconBox(theme, style),
      ],
    );
    return row;
  }

  Widget _fill(Widget child) => Row(children: [Expanded(child: child)]);
}

@immutable
class _CarbonButtonStyle {
  const _CarbonButtonStyle({
    required this.background,
    required this.foreground,
    required this.iconColor,
    this.border,
    this.focusFilled = false,
  });

  final Color background;
  final Color foreground;
  final Color iconColor;
  final Color? border;

  /// True when keyboard focus fills an outlined button, which then needs the
  /// inner focus ring like a filled one.
  final bool focusFilled;

  static const Color _clear = Color(0x00000000);

  static _CarbonButtonStyle resolve(
    CarbonThemeData theme,
    CarbonButtonKind kind, {
    required bool disabled,
    required bool hovered,
    required bool pressed,
    required bool focused,
    required bool iconOnly,
  }) {
    final c = theme.colors;
    Color pick(Color rest, Color hover, Color active) =>
        pressed ? active : (hovered ? hover : rest);

    if (disabled) {
      return switch (kind) {
        CarbonButtonKind.primary ||
        CarbonButtonKind.secondary ||
        CarbonButtonKind.danger => _CarbonButtonStyle(
          background: c.buttonDisabled,
          foreground: c.textOnColorDisabled,
          iconColor: c.iconOnColorDisabled,
        ),
        CarbonButtonKind.tertiary ||
        CarbonButtonKind.dangerTertiary => _CarbonButtonStyle(
          background: _clear,
          foreground: c.textDisabled,
          iconColor: c.iconDisabled,
          border: c.buttonDisabled,
        ),
        CarbonButtonKind.ghost ||
        CarbonButtonKind.dangerGhost => _CarbonButtonStyle(
          background: _clear,
          foreground: c.textDisabled,
          // Carbon dims an icon-only ghost glyph with the on-color role; with
          // a label the icon follows the text.
          iconColor: iconOnly ? c.iconOnColorDisabled : c.iconDisabled,
        ),
      };
    }

    _CarbonButtonStyle filled(Color rest, Color hover, Color active) =>
        _CarbonButtonStyle(
          background: pick(rest, hover, active),
          foreground: c.textOnColor,
          iconColor: c.iconOnColor,
        );

    // Outlined treatments fill on hover, press and keyboard focus, which flips
    // the text to the on-color / inverse role for contrast. The frame follows
    // the fill once pressed (and on hover for danger), so no accent edge shows
    // around a darker fill.
    _CarbonButtonStyle outlined(
      Color accent,
      Color hover,
      Color active,
      Color focusFill,
      Color hoverBorder,
      Color invertedText,
      Color invertedIcon,
    ) {
      final on = hovered || pressed || focused;
      // Focus outranks hover for the fill, as the later :focus rule does in
      // Carbon; only :active overrides it.
      final Color fill = pressed
          ? active
          : (focused ? focusFill : (hovered ? hover : _clear));
      return _CarbonButtonStyle(
        background: fill,
        foreground: on ? invertedText : accent,
        iconColor: on ? invertedIcon : accent,
        border: pressed ? active : (hovered ? hoverBorder : accent),
        focusFilled: focused,
      );
    }

    _CarbonButtonStyle ghost(
      Color text,
      Color icon,
      Color hover,
      Color active,
      Color invertedText,
      Color invertedIcon,
      Color hoverFill,
      Color activeFill,
    ) {
      final on = hovered || pressed;
      return _CarbonButtonStyle(
        background: on ? pick(_clear, hoverFill, activeFill) : _clear,
        foreground: on ? invertedText : text,
        iconColor: on ? invertedIcon : icon,
      );
    }

    return switch (kind) {
      CarbonButtonKind.primary => filled(
        c.buttonPrimary,
        c.buttonPrimaryHover,
        c.buttonPrimaryActive,
      ),
      CarbonButtonKind.secondary => filled(
        c.buttonSecondary,
        c.buttonSecondaryHover,
        c.buttonSecondaryActive,
      ),
      CarbonButtonKind.danger => filled(
        c.buttonDangerPrimary,
        c.buttonDangerHover,
        c.buttonDangerActive,
      ),
      CarbonButtonKind.tertiary => outlined(
        c.buttonTertiary,
        c.buttonTertiaryHover,
        c.buttonTertiaryActive,
        c.buttonTertiary,
        c.buttonTertiary,
        c.textInverse,
        c.iconInverse,
      ),
      CarbonButtonKind.dangerTertiary => outlined(
        c.buttonDangerSecondary,
        c.buttonDangerHover,
        c.buttonDangerActive,
        c.buttonDangerPrimary,
        c.buttonDangerHover,
        c.textOnColor,
        c.iconOnColor,
      ),
      CarbonButtonKind.ghost => ghost(
        c.linkPrimary,
        c.iconPrimary,
        c.backgroundHover,
        c.backgroundActive,
        c.linkPrimaryHover,
        c.iconPrimary,
        c.backgroundHover,
        c.backgroundActive,
      ),
      CarbonButtonKind.dangerGhost => ghost(
        c.buttonDangerSecondary,
        c.buttonDangerSecondary,
        c.buttonDangerHover,
        c.buttonDangerActive,
        c.textOnColor,
        c.iconOnColor,
        c.buttonDangerHover,
        c.buttonDangerActive,
      ),
    };
  }
}

/// How a [CarbonButtonSet] distributes its width.
enum CarbonButtonSetAlignment {
  /// Buttons share the full width equally.
  fill,

  /// Buttons keep their natural width and sit at the end of the row.
  end,
}

/// Carbon's button group, as used in modal footers and forms.
///
/// Pass buttons in reading order (secondary first, primary last). They sit in
/// one row separated by a 1px rule. When the row cannot show every label at its
/// natural width, which happens in narrow containers or with enlarged text, the
/// set stacks vertically with the last button on top, so labels are never
/// clipped. Each stacked button spans the full width.
class CarbonButtonSet extends StatelessWidget {
  const CarbonButtonSet({
    super.key,
    required this.children,
    this.alignment = CarbonButtonSetAlignment.end,
  });

  final List<Widget> children;
  final CarbonButtonSetAlignment alignment;

  @override
  Widget build(BuildContext context) {
    final theme = CarbonTheme.of(context);
    return _ButtonSetLayout(
      alignment: alignment,
      separatorColor: theme.colors.buttonSeparator,
      disabledSeparatorColor: theme.colors.iconOnColorDisabled,
      stackedDisabledSeparatorColor: theme.colors.layerSelectedDisabled,
      textDirection: Directionality.of(context),
      children: children,
    );
  }
}

class _ButtonSetLayout extends MultiChildRenderObjectWidget {
  const _ButtonSetLayout({
    required super.children,
    required this.alignment,
    required this.separatorColor,
    required this.disabledSeparatorColor,
    required this.stackedDisabledSeparatorColor,
    required this.textDirection,
  });

  final CarbonButtonSetAlignment alignment;
  final Color separatorColor;
  final Color disabledSeparatorColor;
  final Color stackedDisabledSeparatorColor;
  final TextDirection textDirection;

  @override
  RenderObject createRenderObject(BuildContext context) => _RenderButtonSet(
    alignment: alignment,
    separatorColor: separatorColor,
    disabledSeparatorColor: disabledSeparatorColor,
    stackedDisabledSeparatorColor: stackedDisabledSeparatorColor,
    textDirection: textDirection,
  );

  @override
  void updateRenderObject(BuildContext context, _RenderButtonSet renderObject) {
    renderObject
      ..alignment = alignment
      ..separatorColor = separatorColor
      ..setDisabledSeparators(
        disabledSeparatorColor,
        stackedDisabledSeparatorColor,
      )
      ..textDirection = textDirection;
  }
}

class _SetParentData extends ContainerBoxParentData<RenderBox> {}

class _SetPlan {
  _SetPlan(this.size, this.offsets, this.stacked, this.childSizes);

  final Size size;
  final List<Offset> offsets;
  final bool stacked;
  final List<Size> childSizes;
}

class _RenderButtonSet extends RenderBox
    with
        ContainerRenderObjectMixin<RenderBox, _SetParentData>,
        RenderBoxContainerDefaultsMixin<RenderBox, _SetParentData> {
  _RenderButtonSet({
    required CarbonButtonSetAlignment alignment,
    required Color separatorColor,
    required Color disabledSeparatorColor,
    required Color stackedDisabledSeparatorColor,
    required TextDirection textDirection,
  }) : _alignment = alignment,
       _separatorColor = separatorColor,
       _rowDisabledSeparator = disabledSeparatorColor,
       _stackedDisabledSeparator = stackedDisabledSeparatorColor,
       _textDirection = textDirection;

  static const double _gap = CarbonBorders.hairline;

  CarbonButtonSetAlignment _alignment;
  CarbonButtonSetAlignment get alignment => _alignment;
  set alignment(CarbonButtonSetAlignment v) {
    if (_alignment == v) return;
    _alignment = v;
    markNeedsLayout();
  }

  Color _separatorColor;
  Color get separatorColor => _separatorColor;
  set separatorColor(Color v) {
    if (_separatorColor == v) return;
    _separatorColor = v;
    markNeedsPaint();
  }

  Color _rowDisabledSeparator;
  Color _stackedDisabledSeparator;
  void setDisabledSeparators(Color row, Color stacked) {
    if (_rowDisabledSeparator == row && _stackedDisabledSeparator == stacked) {
      return;
    }
    _rowDisabledSeparator = row;
    _stackedDisabledSeparator = stacked;
    markNeedsPaint();
  }

  Color _disabledSeparatorColor(bool stacked) =>
      stacked ? _stackedDisabledSeparator : _rowDisabledSeparator;

  // The state tag sits somewhere inside each button; a child without one (a
  // non-button) counts as neither focused nor disabled.
  static _RenderButtonStateTag? _tagOf(RenderObject root) {
    if (root is _RenderButtonStateTag) return root;
    _RenderButtonStateTag? found;
    root.visitChildren((c) => found ??= _tagOf(c));
    return found;
  }

  TextDirection _textDirection;
  TextDirection get textDirection => _textDirection;
  set textDirection(TextDirection v) {
    if (_textDirection == v) return;
    _textDirection = v;
    markNeedsLayout();
  }

  _SetPlan? _plan;

  @override
  void setupParentData(RenderBox child) {
    if (child.parentData is! _SetParentData) child.parentData = _SetParentData();
  }

  List<RenderBox> get _kids {
    final out = <RenderBox>[];
    var child = firstChild;
    while (child != null) {
      out.add(child);
      child = childAfter(child);
    }
    return out;
  }

  // Carbon sizes row buttons as 196 px columns (`.btn-set .btn`), so a short
  // label still gets the full column; longer labels keep their natural width.
  static const double _column = 196;

  List<double> _columns(List<double> natural) =>
      [for (final w in natural) math.max(w, _column)];

  bool _stacks(List<double> natural, double maxWidth) {
    if (!maxWidth.isFinite) return false;
    final n = natural.length;
    final gaps = _gap * (n - 1);
    if (_alignment == CarbonButtonSetAlignment.fill) {
      final share = (maxWidth - gaps) / n;
      return natural.any((w) => w > share + 0.01);
    }
    return _columns(natural).fold<double>(0, (a, b) => a + b) + gaps >
        maxWidth + 0.01;
  }

  List<double> _widths(List<double> natural, double maxWidth, bool stacked) {
    final n = natural.length;
    if (stacked) return List.filled(n, maxWidth);
    if (_alignment == CarbonButtonSetAlignment.fill && maxWidth.isFinite) {
      return List.filled(n, (maxWidth - _gap * (n - 1)) / n);
    }
    return _alignment == CarbonButtonSetAlignment.fill
        ? natural
        : _columns(natural);
  }

  // Mirrors the stack-or-row decision in layout so an intrinsic-sized parent
  // allots the height the set will actually use.
  double _intrinsicHeight(double width, double Function(RenderBox, double) of) {
    final kids = _kids;
    if (kids.isEmpty) return 0;
    final natural = [
      for (final k in kids) k.getMaxIntrinsicWidth(double.infinity),
    ];
    final stacked = _stacks(natural, width);
    final widths = _widths(natural, width, stacked);
    final heights = [for (var i = 0; i < kids.length; i++) of(kids[i], widths[i])];
    if (stacked) {
      return heights.fold<double>(0, (a, b) => a + b) + _gap * (kids.length - 1);
    }
    return heights.fold<double>(0, math.max);
  }

  _SetPlan _compute(BoxConstraints constraints, {required bool dry}) {
    final kids = _kids;
    if (kids.isEmpty) {
      return _SetPlan(constraints.constrain(Size.zero), [], false, []);
    }
    final n = kids.length;
    final maxWidth = constraints.maxWidth;
    final bounded = maxWidth.isFinite;
    final gaps = _gap * (n - 1);

    Size measure(RenderBox box, BoxConstraints c) =>
        dry ? box.getDryLayout(c) : (box..layout(c, parentUsesSize: true)).size;

    final natural = [
      for (final k in kids) k.getMaxIntrinsicWidth(double.infinity),
    ];

    final stacked = _stacks(natural, maxWidth);
    final widths = _widths(natural, maxWidth, stacked);

    final heights = <double>[];
    for (var i = 0; i < n; i++) {
      final size = measure(
        kids[i],
        BoxConstraints(minWidth: widths[i], maxWidth: widths[i]),
      );
      heights.add(size.height);
    }

    final sizes = <Size>[];
    final offsets = <Offset>[];
    late final Size total;
    if (stacked) {
      var y = 0.0;
      // The last button (primary) goes on top.
      final order = [for (var i = n - 1; i >= 0; i--) i];
      final placed = List<Offset>.filled(n, Offset.zero);
      for (final i in order) {
        placed[i] = Offset(0, y);
        y += heights[i] + _gap;
      }
      offsets.addAll(placed);
      for (var i = 0; i < n; i++) {
        sizes.add(Size(widths[i], heights[i]));
      }
      total = constraints.constrain(Size(maxWidth, y - _gap));
    } else {
      final rowHeight = heights.fold<double>(0, math.max);
      for (var i = 0; i < n; i++) {
        // Equal heights so a wrapped label in one button does not leave its
        // neighbors short.
        final tight = measure(
          kids[i],
          BoxConstraints.tightFor(width: widths[i], height: rowHeight),
        );
        sizes.add(tight);
      }
      final used = widths.fold<double>(0, (a, b) => a + b) + gaps;
      final rowWidth = bounded ? maxWidth : used;
      final ltr = _textDirection == TextDirection.ltr;
      // Logical start of the first button: end-aligned rows hug the end edge.
      final lead = _alignment == CarbonButtonSetAlignment.end && bounded
          ? rowWidth - used
          : 0.0;
      var x = lead;
      for (var i = 0; i < n; i++) {
        final w = widths[i];
        final left = ltr ? x : rowWidth - x - w;
        offsets.add(Offset(left, 0));
        x += w + _gap;
      }
      total = constraints.constrain(Size(rowWidth, rowHeight));
    }
    return _SetPlan(total, offsets, stacked, sizes);
  }

  @override
  Size computeDryLayout(BoxConstraints constraints) =>
      _compute(constraints, dry: true).size;

  @override
  void performLayout() {
    final plan = _compute(constraints, dry: false);
    _plan = plan;
    final kids = _kids;
    for (var i = 0; i < kids.length; i++) {
      (kids[i].parentData! as _SetParentData).offset = plan.offsets[i];
    }
    size = plan.size;
  }

  @override
  double computeMinIntrinsicWidth(double height) {
    var w = 0.0;
    for (final k in _kids) {
      w = math.max(w, k.getMinIntrinsicWidth(height));
    }
    return w;
  }

  @override
  double computeMaxIntrinsicWidth(double height) {
    final natural = [for (final k in _kids) k.getMaxIntrinsicWidth(height)];
    final w = (_alignment == CarbonButtonSetAlignment.fill
            ? natural
            : _columns(natural))
        .fold<double>(0, (a, b) => a + b);
    return w + _gap * math.max(0, childCount - 1);
  }

  @override
  double computeMinIntrinsicHeight(double width) =>
      _intrinsicHeight(width, (k, w) => k.getMinIntrinsicHeight(w));

  @override
  double computeMaxIntrinsicHeight(double width) =>
      _intrinsicHeight(width, (k, w) => k.getMaxIntrinsicHeight(w));

  @override
  double? computeDistanceToActualBaseline(TextBaseline baseline) =>
      defaultComputeDistanceToHighestActualBaseline(baseline);

  @override
  void paint(PaintingContext context, Offset offset) {
    final plan = _plan;
    if (plan != null && childCount > 1) {
      final kids = _kids;
      final ltr = _textDirection == TextDirection.ltr;
      for (var i = 0; i < plan.offsets.length; i++) {
        final o = plan.offsets[i];
        final s = plan.childSizes[i];
        final Rect rule;
        // The rule belongs to the button it is drawn for, and Carbon drops it
        // when that button or its neighbour holds focus.
        final int owner;
        final int neighbour;
        if (plan.stacked) {
          // Child 0 is the bottom button and has nothing below it.
          if (i == 0) continue;
          rule = Rect.fromLTWH(o.dx, o.dy + s.height, size.width, _gap);
          owner = i;
          neighbour = i - 1;
        } else {
          // The rule follows each button in reading order except the last.
          if (i == plan.offsets.length - 1) continue;
          final x = ltr ? o.dx + s.width : o.dx - _gap;
          rule = Rect.fromLTWH(x, 0, _gap, size.height);
          owner = i + 1;
          neighbour = i;
        }
        final ownerTag = _tagOf(kids[owner]);
        if (ownerTag?.focused == true || _tagOf(kids[neighbour])?.focused == true) {
          continue;
        }
        final color = ownerTag?.disabled == true
            ? _disabledSeparatorColor(plan.stacked)
            : _separatorColor;
        context.canvas.drawRect(rule.shift(offset), Paint()..color = color);
      }
    }
    defaultPaint(context, offset);
  }

  @override
  bool hitTestChildren(BoxHitTestResult result, {required Offset position}) =>
      defaultHitTestChildren(result, position: position);
}

/// Publishes a button's focus and disabled state to an enclosing
/// [CarbonButtonSet], whose separators depend on both.
class _ButtonStateTag extends SingleChildRenderObjectWidget {
  const _ButtonStateTag({
    required this.focused,
    required this.disabled,
    required super.child,
  });

  final bool focused;
  final bool disabled;

  @override
  RenderObject createRenderObject(BuildContext context) =>
      _RenderButtonStateTag(focused, disabled);

  @override
  void updateRenderObject(
    BuildContext context,
    _RenderButtonStateTag renderObject,
  ) {
    renderObject
      ..focused = focused
      ..disabled = disabled;
  }
}

class _RenderButtonStateTag extends RenderProxyBox {
  _RenderButtonStateTag(this._focused, this._disabled);

  bool _focused;
  bool get focused => _focused;
  set focused(bool v) {
    if (_focused == v) return;
    _focused = v;
    _repaintSet();
  }

  bool _disabled;
  bool get disabled => _disabled;
  set disabled(bool v) {
    if (_disabled == v) return;
    _disabled = v;
    _repaintSet();
  }

  void _repaintSet() {
    RenderObject? p = parent;
    while (p != null) {
      if (p is _RenderButtonSet) {
        p.markNeedsPaint();
        return;
      }
      p = p.parent;
    }
  }
}
