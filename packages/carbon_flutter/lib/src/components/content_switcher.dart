import 'package:flutter/semantics.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

import '../foundations/theme.dart';
import '../foundations/tokens.dart';
import '../primitives/focus_ring.dart';
import '../primitives/interaction.dart';
import '../primitives/option.dart';
import 'tabs.dart' show CarbonActivationMode;

/// Carbon's content switcher heights. Touch density uses [CarbonThemeData.touchTarget] for every size.
enum CarbonContentSwitcherSize {
  /// 32 in compact density.
  small,

  /// 40 in compact density.
  medium,

  /// 48 in compact density.
  large,
}

/// A segmented control for switching between related views, with exactly one
/// option selected at all times.
///
/// Unlike tabs it does not own a panel and does not scroll: segments share the
/// widest natural width and a label that does not fit wraps inside its segment,
/// so enlarged text grows the control instead of clipping.
///
/// Selection is shown with Carbon's inverse fill and text, which no hover or
/// focus treatment reuses: hover tints an unselected segment, focus draws the
/// 2px ring.
///
/// Keyboard contract (same as [CarbonTabs]):
/// * One tab stop; Tab always enters on the selected segment and focus that
///   was moved without selecting is not remembered once it leaves.
/// * Left and Right move to the previous and next enabled option, wrapping
///   (swapped in right-to-left layouts); Home and End jump to the ends.
/// * With [CarbonActivationMode.automatic] moving focus selects; with
///   [CarbonActivationMode.manual] Enter or Space selects.
///
/// Set [iconOnly] to show only each option's [CarbonOption.icon]; the option's
/// `label` then becomes its accessible name, so every option must carry both.
/// [value] must match an option, and re-selecting the current option never
/// reports a change.
class CarbonContentSwitcher<T> extends StatefulWidget {
  const CarbonContentSwitcher({
    super.key,
    required this.options,
    required this.value,
    required this.onChanged,
    this.size = CarbonContentSwitcherSize.medium,
    this.iconOnly = false,
    this.activation = CarbonActivationMode.automatic,
    this.expand = false,
    this.semanticLabel,
  });

  final List<CarbonOption<T>> options;
  final T value;
  final ValueChanged<T> onChanged;
  final CarbonContentSwitcherSize size;

  /// Shows icons without text. Requires an icon on every option.
  final bool iconOnly;

  final CarbonActivationMode activation;

  /// Fills the available width instead of sizing to the widest option. Needs a
  /// bounded width.
  final bool expand;

  /// Names the group for assistive technology.
  final String? semanticLabel;

  @override
  State<CarbonContentSwitcher<T>> createState() =>
      _CarbonContentSwitcherState<T>();
}

class _CarbonContentSwitcherState<T> extends State<CarbonContentSwitcher<T>> {
  final Map<Object?, FocusNode> _nodes = <Object?, FocusNode>{};
  // The flag exists because null is a legal option value and cannot double as
  // "no stop".
  Object? _stop;
  bool _hasStop = false;
  // Carbon hides the divider beside a hovered or focused segment, so the
  // neighbours of a segment need to know about it.
  int _hoverIndex = -1;
  int _focusIndex = -1;

  @override
  void initState() {
    super.initState();
    _syncNodes();
  }

  @override
  void didUpdateWidget(CarbonContentSwitcher<T> oldWidget) {
    super.didUpdateWidget(oldWidget);
    _syncNodes();
  }

  @override
  void dispose() {
    for (final node in _nodes.values) {
      node.dispose();
    }
    super.dispose();
  }

  void _syncNodes() {
    assert(
      !widget.iconOnly || widget.options.every((o) => o.icon != null),
      'Every option of an icon-only CarbonContentSwitcher needs an icon.',
    );
    final values = <Object?>{for (final o in widget.options) o.value};
    assert(
      values.contains(widget.value),
      'CarbonContentSwitcher value must match one of the options.',
    );
    assert(
      values.length == widget.options.length,
      'CarbonContentSwitcher values must be distinct.',
    );
    for (final v in values) {
      _nodes.putIfAbsent(v, () => FocusNode(debugLabel: 'CarbonSegment'));
    }
    final stale = _nodes.keys.where((k) => !values.contains(k)).toList();
    if (stale.isEmpty) return;
    final removed = <FocusNode>[for (final k in stale) _nodes.remove(k)!];
    // The removed segments' interaction widgets still hold these nodes until
    // the next build unmounts them.
    SchedulerBinding.instance.addPostFrameCallback((_) {
      for (final node in removed) {
        node.dispose();
      }
    });
    if (_hasStop && stale.contains(_stop)) _clearStop();
  }

  void _clearStop() {
    _stop = null;
    _hasStop = false;
  }

  int _indexOf(Object? value) {
    for (var i = 0; i < widget.options.length; i++) {
      if (widget.options[i].value == value) return i;
    }
    return -1;
  }

  int _focusedIndex() {
    for (var i = 0; i < widget.options.length; i++) {
      if (_nodes[widget.options[i].value]?.hasFocus ?? false) return i;
    }
    return -1;
  }

  int _stopIndex(int selected) {
    final options = widget.options;
    var i = _hasStop ? _indexOf(_stop) : -1;
    if (i >= 0 && options[i].enabled) return i;
    i = selected;
    if (i >= 0 && options[i].enabled) return i;
    return options.indexWhere((o) => o.enabled);
  }

  int _step(int from, int direction) {
    final n = widget.options.length;
    for (var k = 1; k <= n; k++) {
      final j = ((from + direction * k) % n + n) % n;
      if (widget.options[j].enabled) return j;
    }
    return -1;
  }

  KeyEventResult _onKey(FocusNode node, KeyEvent event) {
    if (event is KeyUpEvent) return KeyEventResult.ignored;
    final keyboard = HardwareKeyboard.instance;
    if (keyboard.isControlPressed ||
        keyboard.isAltPressed ||
        keyboard.isMetaPressed ||
        keyboard.isShiftPressed) {
      return KeyEventResult.ignored;
    }
    final current = _focusedIndex();
    if (current < 0) return KeyEventResult.ignored;
    final rtl = Directionality.of(context) == TextDirection.rtl;
    final key = event.logicalKey;
    int target;
    if (key == LogicalKeyboardKey.arrowRight) {
      target = _step(current, rtl ? -1 : 1);
    } else if (key == LogicalKeyboardKey.arrowLeft) {
      target = _step(current, rtl ? 1 : -1);
    } else if (key == LogicalKeyboardKey.home) {
      target = widget.options.indexWhere((o) => o.enabled);
    } else if (key == LogicalKeyboardKey.end) {
      target = widget.options.lastIndexWhere((o) => o.enabled);
    } else {
      return KeyEventResult.ignored;
    }
    if (target < 0) return KeyEventResult.handled;
    final option = widget.options[target];
    _nodes[option.value]?.requestFocus();
    if (widget.activation == CarbonActivationMode.automatic) _select(option);
    return KeyEventResult.handled;
  }

  void _select(CarbonOption<T> option) {
    if (!option.enabled || option.value == widget.value) return;
    widget.onChanged(option.value);
  }

  void _handleFocus(int index, Object? value, bool focused) {
    if (!focused) {
      if (_focusIndex == index) setState(() => _focusIndex = -1);
      return;
    }
    setState(() {
      _focusIndex = index;
      _stop = value;
      _hasStop = true;
    });
  }

  void _handleHover(int index, bool hovered) {
    final next = hovered ? index : (_hoverIndex == index ? -1 : _hoverIndex);
    if (next != _hoverIndex) setState(() => _hoverIndex = next);
  }

  bool _lit(int index) => _hoverIndex == index || _focusIndex == index;

  void _handleGroupFocus(bool focused) {
    if (focused || !_hasStop) return;
    setState(_clearStop);
  }

  @override
  Widget build(BuildContext context) {
    final theme = CarbonTheme.of(context);
    final level = CarbonLayer.of(context);
    final options = widget.options;
    final selected = _indexOf(widget.value);
    final stop = _stopIndex(selected);
    for (var i = 0; i < options.length; i++) {
      _nodes[options[i].value]?.skipTraversal = i != stop;
    }
    final height = theme.isTouch
        ? theme.touchTarget
        : switch (widget.size) {
            CarbonContentSwitcherSize.small => 32.0,
            CarbonContentSwitcherSize.medium => 40.0,
            CarbonContentSwitcherSize.large => 48.0,
          };

    final row = Row(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        for (var i = 0; i < options.length; i++)
          Expanded(
            child: _Segment(
              option: options[i],
              selected: i == selected,
              // A rule next to the selected segment would double its edge.
              showEndRule:
                  i < options.length - 1 &&
                  i != selected &&
                  i + 1 != selected &&
                  !_lit(i) &&
                  !_lit(i + 1),
              first: i == 0,
              last: i == options.length - 1,
              largeIcons:
                  !theme.isTouch &&
                  widget.size == CarbonContentSwitcherSize.large,
              iconOnly: widget.iconOnly,
              focusNode: _nodes[options[i].value]!,
              level: level,
              height: height,
              onSelect: () => _select(options[i]),
              onFocusChange: (f) => _handleFocus(i, options[i].value, f),
              onHoverChange: (h) => _handleHover(i, h),
            ),
          ),
      ],
    );

    return Focus(
      canRequestFocus: false,
      skipTraversal: true,
      onKeyEvent: _onKey,
      onFocusChange: _handleGroupFocus,
      child: DecoratedBox(
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(4),
          border: Border.all(
            color: theme.colors.borderInverse,
            width: CarbonBorders.hairline,
          ),
        ),
        // Only the segments may sit directly under the tab-bar node.
        child: Semantics(
          role: SemanticsRole.tabBar,
          container: true,
          explicitChildNodes: true,
          label: widget.semanticLabel,
          child: widget.expand
              ? IntrinsicHeight(child: row)
              : IntrinsicWidth(child: IntrinsicHeight(child: row)),
        ),
      ),
    );
  }
}

class _Segment extends StatelessWidget {
  const _Segment({
    required this.option,
    required this.selected,
    required this.showEndRule,
    required this.first,
    required this.last,
    required this.largeIcons,
    required this.iconOnly,
    required this.focusNode,
    required this.level,
    required this.height,
    required this.onSelect,
    required this.onFocusChange,
    required this.onHoverChange,
  });

  final CarbonOption<Object?> option;
  final bool selected;
  final bool showEndRule;
  final bool first;
  final bool last;
  final bool largeIcons;
  final bool iconOnly;
  final FocusNode focusNode;
  final int level;
  final double height;
  final VoidCallback onSelect;
  final ValueChanged<bool> onFocusChange;
  final ValueChanged<bool> onHoverChange;

  @override
  Widget build(BuildContext context) {
    final theme = CarbonTheme.of(context);
    final colors = theme.colors;
    final enabled = option.enabled;
    return CarbonInteraction(
      onPressed: enabled ? onSelect : null,
      focusNode: focusNode,
      requestFocusOnTap: true,
      onFocusChange: onFocusChange,
      onHoverChange: onHoverChange,
      button: false,
      role: SemanticsRole.tab,
      label: option.label,
      selected: selected,
      excludeChildSemantics: true,
      builder: (context, state, _) {
        final Color fill;
        final Color text;
        if (selected) {
          fill = enabled ? colors.layerSelectedInverse : colors.layerSelectedDisabled;
          text = enabled ? colors.textInverse : colors.textDisabled;
        } else {
          // Unselected segments are clear so the page shows through the
          // outline, as in Carbon.
          fill = state.pressed || state.hovered
              ? theme.layerHover(level)
              : const Color(0x00000000);
          text = !enabled
              ? colors.textDisabled
              : state.pressed || state.hovered
              ? colors.textPrimary
              : colors.textSecondary;
        }
        // An SVG's fill ignores the button's text colour, so icon-only
        // segments use the icon roles.
        final iconColor = !iconOnly
            ? text
            : !enabled
            ? colors.iconDisabled
            : selected
            ? colors.iconInverse
            : colors.iconPrimary;
        final icon = option.icon;
        final BorderRadiusGeometry? radius = selected
            ? BorderRadius.circular(4)
            : first
            ? const BorderRadiusDirectional.horizontal(
                start: Radius.circular(4),
              )
            : last
            ? const BorderRadiusDirectional.horizontal(end: Radius.circular(4))
            : null;
        return ConstrainedBox(
          constraints: BoxConstraints(
            minHeight: height,
            minWidth: iconOnly ? height : 0,
          ),
          child: CarbonFocusRing(
            visible: state.focusVisible,
            onColor: selected,
            child: DecoratedBox(
              decoration: BoxDecoration(color: fill, borderRadius: radius),
              child: Stack(
                fit: StackFit.passthrough,
                children: <Widget>[
                  Padding(
                    padding: EdgeInsets.symmetric(
                      horizontal: iconOnly
                          ? (largeIcons ? 14 : CarbonSpacing.spacing03)
                          : CarbonSpacing.spacing05,
                      vertical: CarbonSpacing.spacing02,
                    ),
                    child: Center(
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: <Widget>[
                          if (icon != null)
                            IconTheme(
                              data: IconThemeData(
                                color: iconColor,
                                size: largeIcons ? 20 : theme.iconSize,
                              ),
                              child: icon,
                            ),
                          if (icon != null && !iconOnly)
                            const SizedBox(width: CarbonSpacing.spacing03),
                          if (!iconOnly)
                            Flexible(
                              child: Text(
                                option.label,
                                textAlign: TextAlign.center,
                                style: theme.typography.control.copyWith(
                                  color: text,
                                ),
                              ),
                            ),
                        ],
                      ),
                    ),
                  ),
                  if (showEndRule)
                    PositionedDirectional(
                      end: 0,
                      top: 0,
                      bottom: 0,
                      width: CarbonBorders.hairline,
                      child: IgnorePointer(
                        child: Center(
                          child: SizedBox(
                            width: CarbonBorders.hairline,
                            height: 16,
                            child: ColoredBox(color: theme.borderSubtle(level)),
                          ),
                        ),
                      ),
                    ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }
}
