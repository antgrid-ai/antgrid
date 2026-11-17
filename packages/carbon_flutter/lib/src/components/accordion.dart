import 'package:flutter/widgets.dart';

import '../foundations/icons.dart';
import '../foundations/theme.dart';
import '../foundations/tokens.dart';
import '../primitives/focus_ring.dart';
import '../primitives/interaction.dart';

/// Where an accordion item's chevron sits relative to its title.
enum CarbonAccordionAlign {
  /// Chevron before the title.
  start,

  /// Chevron after the title.
  end,
}

/// Carbon's accordion heading heights. Touch density uses
/// [CarbonThemeData.touchTarget] for every size.
enum CarbonAccordionSize {
  /// 32 in compact density.
  small,

  /// 40 in compact density.
  medium,

  /// 48 in compact density.
  large,
}

class _AccordionScope extends InheritedWidget {
  const _AccordionScope({
    required this.align,
    required this.flush,
    required this.size,
    required this.disabled,
    required super.child,
  });

  final CarbonAccordionAlign align;
  final bool flush;
  final CarbonAccordionSize size;
  final bool disabled;

  static _AccordionScope? maybeOf(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<_AccordionScope>();

  @override
  bool updateShouldNotify(_AccordionScope old) =>
      old.align != align ||
      old.flush != flush ||
      old.size != size ||
      old.disabled != disabled;
}

/// A vertical stack of [CarbonAccordionItem]s separated by 1px rules.
///
/// [flush] removes the inline padding of titles, chevrons and content so the
/// accordion lines up with surrounding content. [disabled] disables every item.
/// Items are independent: opening one never closes another.
class CarbonAccordion extends StatelessWidget {
  const CarbonAccordion({
    super.key,
    required this.children,
    this.align = CarbonAccordionAlign.end,
    this.flush = false,
    this.size = CarbonAccordionSize.medium,
    this.disabled = false,
  });

  final List<CarbonAccordionItem> children;
  final CarbonAccordionAlign align;
  final bool flush;
  final CarbonAccordionSize size;
  final bool disabled;

  @override
  Widget build(BuildContext context) {
    final theme = CarbonTheme.of(context);
    final level = CarbonLayer.of(context);
    return _AccordionScope(
      align: align,
      flush: flush,
      size: size,
      disabled: disabled,
      child: DecoratedBox(
        decoration: BoxDecoration(
          border: Border(
            bottom: BorderSide(
              color: theme.borderSubtle(level),
              width: CarbonBorders.hairline,
            ),
          ),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: children,
        ),
      ),
    );
  }
}

/// One collapsible section of a [CarbonAccordion]: a heading button and the
/// [child] it reveals.
///
/// Uncontrolled by default, starting from [initiallyOpen]; the open state
/// lives in the element's State, so giving the item a new key resets it. Pass
/// [open] to control it, in which case a press only reports through
/// [onOpenChanged] and the host decides. Closed content is not focusable and
/// is hidden from assistive technology.
///
/// The heading is announced as a heading containing a button with an expanded
/// flag; Enter and Space toggle it. A [title] that is a plain [Text] names the
/// button automatically, otherwise set [semanticLabel].
class CarbonAccordionItem extends StatefulWidget {
  const CarbonAccordionItem({
    super.key,
    required this.title,
    required this.child,
    this.open,
    this.initiallyOpen = false,
    this.onOpenChanged,
    this.disabled = false,
    this.semanticLabel,
    this.focusNode,
  });

  final Widget title;
  final Widget child;

  /// Controlled open state; null leaves it to the item.
  final bool? open;
  final bool initiallyOpen;

  /// Called with the requested state on every user toggle, in both modes.
  final ValueChanged<bool>? onOpenChanged;
  final bool disabled;
  final String? semanticLabel;
  final FocusNode? focusNode;

  @override
  State<CarbonAccordionItem> createState() => _CarbonAccordionItemState();
}

class _CarbonAccordionItemState extends State<CarbonAccordionItem>
    with SingleTickerProviderStateMixin {
  late bool _open = widget.open ?? widget.initiallyOpen;
  late final AnimationController _controller = AnimationController(
    vsync: this,
    value: _open ? 1 : 0,
  );

  bool get _effectiveOpen => widget.open ?? _open;

  @override
  void didUpdateWidget(CarbonAccordionItem oldWidget) {
    super.didUpdateWidget(oldWidget);
    final before = oldWidget.open ?? _open;
    if (widget.open != null) _open = widget.open!;
    if (_effectiveOpen != before) _animateTo(_effectiveOpen);
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _animateTo(bool open) {
    final duration = CarbonMotion.resolve(context, CarbonMotion.moderate01);
    if (duration == Duration.zero) {
      _controller.value = open ? 1 : 0;
      return;
    }
    _controller.animateTo(
      open ? 1 : 0,
      duration: duration,
    );
  }

  void _toggle() {
    final next = !_effectiveOpen;
    if (widget.open == null) {
      setState(() => _open = next);
      _animateTo(next);
    }
    widget.onOpenChanged?.call(next);
  }

  String? _label() {
    final explicit = widget.semanticLabel;
    if (explicit != null) return explicit;
    final title = widget.title;
    if (title is Text) return title.data ?? title.textSpan?.toPlainText();
    return null;
  }

  @override
  Widget build(BuildContext context) {
    final theme = CarbonTheme.of(context);
    final colors = theme.colors;
    final level = CarbonLayer.of(context);
    final scope = _AccordionScope.maybeOf(context);
    final align = scope?.align ?? CarbonAccordionAlign.end;
    final flush = scope?.flush ?? false;
    final size = scope?.size ?? CarbonAccordionSize.medium;
    final disabled = widget.disabled || (scope?.disabled ?? false);
    final open = _effectiveOpen;
    final label = _label();
    final chevronFirst = align == CarbonAccordionAlign.start;

    final base = switch (size) {
      CarbonAccordionSize.small => CarbonSizes.sm,
      CarbonAccordionSize.medium => CarbonSizes.md,
      CarbonAccordionSize.large => CarbonSizes.lg,
    };
    final minHeight = theme.isTouch ? theme.touchTarget : base;
    final inline = flush ? 0.0 : CarbonSpacing.spacing05;

    final chevron = AnimatedBuilder(
      animation: _controller,
      builder: (context, child) => RotationTransition(
        turns: AlwaysStoppedAnimation<double>(
          CarbonMotion.standard.transform(_controller.value) * 0.5,
        ),
        child: child,
      ),
      child: const CarbonIcon(CarbonIcons.chevronDown),
    );

    final heading = CarbonInteraction(
      onPressed: disabled ? null : _toggle,
      focusNode: widget.focusNode,
      expanded: open,
      label: label,
      excludeChildSemantics: label != null,
      builder: (context, state, _) {
        final fill = !state.enabled
            ? null
            : state.pressed
            ? theme.layerActive(level)
            : state.hovered
            ? theme.layerHover(level)
            : null;
        final titleBox = Expanded(
          child: Padding(
            padding: EdgeInsetsDirectional.only(
              start: chevronFirst ? 0 : inline,
              top: CarbonSpacing.spacing02,
              bottom: CarbonSpacing.spacing02,
            ),
            child: DefaultTextStyle.merge(
              style: theme.typography.control.copyWith(
                color: disabled ? colors.textDisabled : colors.textPrimary,
              ),
              child: widget.title,
            ),
          ),
        );
        final glyph = Padding(
          padding: EdgeInsetsDirectional.only(
            start: chevronFirst ? inline : CarbonSpacing.spacing05,
            end: chevronFirst ? CarbonSpacing.spacing05 : inline,
          ),
          child: IconTheme.merge(
            data: IconThemeData(
              color: disabled ? colors.iconDisabled : colors.iconPrimary,
            ),
            child: chevron,
          ),
        );
        // Carbon extends the state layer 16px past a flush heading's text.
        final bleed = flush ? CarbonSpacing.spacing05 : 0.0;
        return Stack(
          clipBehavior: Clip.none,
          children: <Widget>[
            Positioned.directional(
              textDirection: Directionality.of(context),
              start: -bleed,
              end: -bleed,
              top: 0,
              bottom: 0,
              child: CarbonFocusRing(
                visible: state.focusVisible,
                child: ColoredBox(color: fill ?? const Color(0x00000000)),
              ),
            ),
            ConstrainedBox(
              constraints: BoxConstraints(minHeight: minHeight),
              child: Row(
                children: chevronFirst
                    ? <Widget>[glyph, titleBox]
                    : <Widget>[titleBox, glyph],
              ),
            ),
          ],
        );
      },
    );

    return DecoratedBox(
      decoration: BoxDecoration(
        border: Border(
          top: BorderSide(
            color: theme.borderSubtle(level),
            width: CarbonBorders.hairline,
          ),
        ),
      ),
      // The rule takes its own pixel, as Carbon's border-top does.
      child: Padding(
        padding: const EdgeInsets.only(top: CarbonBorders.hairline),
        child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          MergeSemantics(child: Semantics(header: true, child: heading)),
          AnimatedBuilder(
            animation: _controller,
            child: LayoutBuilder(
              builder: (context, constraints) => Padding(
                padding: EdgeInsetsDirectional.only(
                  start: inline,
                  end: constraints.maxWidth.isFinite
                      ? constraints.maxWidth * 0.25
                      : CarbonSpacing.spacing09,
                  top: CarbonSpacing.spacing03,
                  bottom: CarbonSpacing.spacing06,
                ),
                child: DefaultTextStyle.merge(
                  style: theme.typography.body.copyWith(
                    color: colors.textPrimary,
                  ),
                  child: widget.child,
                ),
              ),
            ),
            builder: (context, child) {
              if (!open && _controller.value == 0) {
                return const SizedBox.shrink();
              }
              return ExcludeFocus(
                excluding: !open,
                child: ExcludeSemantics(
                  excluding: !open,
                  child: ClipRect(
                    child: Align(
                      alignment: AlignmentDirectional.topStart,
                      heightFactor: CarbonMotion.standard.transform(
                        _controller.value,
                      ),
                      child: child,
                    ),
                  ),
                ),
              );
            },
          ),
        ],
      ),
      ),
    );
  }
}
