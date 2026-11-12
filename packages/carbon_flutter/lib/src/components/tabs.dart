import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/rendering.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

import '../foundations/icons.dart';
import '../foundations/localizations.dart';
import '../foundations/theme.dart';
import '../foundations/tokens.dart';
import '../primitives/focus_ring.dart';
import '../primitives/interaction.dart';
import '../primitives/option.dart';

/// Where a tab list's variant draws its selected indicator.
enum CarbonTabsVariant {
  /// Tabs sit on the page with a 2px bottom rule under the selected tab.
  line,

  /// Filled tabs with a 3px top rule on the selected tab; the selected tab
  /// takes the fill of the layer it sits on so it joins the panel below.
  contained,
}

/// How keyboard focus relates to selection in a roving-focus group.
enum CarbonActivationMode {
  /// Arrow, Home and End keys move focus and select in one step. Use when
  /// switching is instant and cheap.
  automatic,

  /// Arrow, Home and End keys only move focus; Enter or Space (or a click)
  /// selects. Use when selecting loads content or has side effects, so
  /// arrowing across the list does not trigger every panel.
  manual,
}

/// The tab list: a single row of tabs with a roving tab stop.
///
/// Only the list is provided. The host owns the selected [value] and composes
/// the content, typically with [CarbonTabPanels], which keeps hidden panes
/// mounted (so scroll position and field text survive) while muting their
/// tickers and removing them from focus.
///
/// Keyboard contract:
/// * The list is one tab stop. Tab always enters on the selected tab (the
///   first enabled one when nothing is selected) and leaves past the list;
///   focus that was moved without selecting is not remembered once it leaves.
/// * Left and Right move focus to the previous and next enabled tab, wrapping
///   at the ends; the two swap in right-to-left layouts. Home and End jump to
///   the first and last enabled tab.
/// * With [CarbonActivationMode.automatic] moving focus selects the tab. With
///   [CarbonActivationMode.manual] focus moves alone and Enter or Space
///   selects. A click or tap always selects.
///
/// When the tabs are wider than the list they scroll horizontally, with
/// backward and forward buttons at the ends. The focused and selected tabs are
/// scrolled into view. A label wider than the whole list wraps inside its tab.
///
/// Tabs are identified by [CarbonOption.value]; a disabled option is shown but
/// cannot be focused or selected. [CarbonOption.icon] shows before the label.
class CarbonTabs<T> extends StatefulWidget {
  const CarbonTabs({
    super.key,
    required this.tabs,
    required this.value,
    required this.onChanged,
    this.variant = CarbonTabsVariant.line,
    this.activation = CarbonActivationMode.automatic,
    this.semanticLabel,
  });

  final List<CarbonOption<T>> tabs;

  /// The selected tab's value. A value no tab carries selects nothing.
  final T? value;

  /// Called with the tab the user selected. Never called for the tab that is
  /// already selected.
  final ValueChanged<T> onChanged;

  final CarbonTabsVariant variant;
  final CarbonActivationMode activation;

  /// Names the tab list for assistive technology.
  final String? semanticLabel;

  @override
  State<CarbonTabs<T>> createState() => _CarbonTabsState<T>();
}

class _CarbonTabsState<T> extends State<CarbonTabs<T>> {
  final Map<Object?, FocusNode> _nodes = <Object?, FocusNode>{};
  final ScrollController _scroll = ScrollController();
  final GlobalKey _viewportKey = GlobalKey();

  // Last tab that held focus while the list had it; the tab stop when manual
  // focus differs from selection. Cleared when focus leaves the list. The flag
  // exists because null is a legal tab value and cannot double as "no stop".
  Object? _stop;
  bool _hasStop = false;
  bool _overflow = false;
  bool _canBack = false;
  bool _canForward = false;
  double _buttonExtent = 32;

  @override
  void initState() {
    super.initState();
    _syncNodes();
    _revealAfterFrame(widget.value, animate: false);
  }

  @override
  void didUpdateWidget(CarbonTabs<T> oldWidget) {
    super.didUpdateWidget(oldWidget);
    _syncNodes();
    if (widget.value != oldWidget.value) _revealAfterFrame(widget.value);
  }

  @override
  void dispose() {
    for (final node in _nodes.values) {
      node.dispose();
    }
    _scroll.dispose();
    super.dispose();
  }

  void _syncNodes() {
    final values = <Object?>{for (final t in widget.tabs) t.value};
    assert(
      values.length == widget.tabs.length,
      'CarbonTabs values must be distinct.',
    );
    for (final v in values) {
      _nodes.putIfAbsent(v, () => FocusNode(debugLabel: 'CarbonTab'));
    }
    final stale = _nodes.keys.where((k) => !values.contains(k)).toList();
    if (stale.isEmpty) return;
    final removed = <FocusNode>[for (final k in stale) _nodes.remove(k)!];
    // The removed tabs' interaction widgets still hold these nodes until the
    // next build unmounts them.
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
    for (var i = 0; i < widget.tabs.length; i++) {
      if (widget.tabs[i].value == value) return i;
    }
    return -1;
  }

  int _focusedIndex() {
    for (var i = 0; i < widget.tabs.length; i++) {
      if (_nodes[widget.tabs[i].value]?.hasFocus ?? false) return i;
    }
    return -1;
  }

  int _stopIndex(int selected) {
    final tabs = widget.tabs;
    var i = _hasStop ? _indexOf(_stop) : -1;
    if (i >= 0 && tabs[i].enabled) return i;
    i = selected;
    if (i >= 0 && tabs[i].enabled) return i;
    return tabs.indexWhere((t) => t.enabled);
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
      target = widget.tabs.indexWhere((t) => t.enabled);
    } else if (key == LogicalKeyboardKey.end) {
      target = widget.tabs.lastIndexWhere((t) => t.enabled);
    } else {
      return KeyEventResult.ignored;
    }
    if (target < 0) return KeyEventResult.handled;
    final tab = widget.tabs[target];
    _nodes[tab.value]?.requestFocus();
    if (widget.activation == CarbonActivationMode.automatic) {
      _select(tab);
    }
    return KeyEventResult.handled;
  }

  int _step(int from, int direction) {
    final tabs = widget.tabs;
    for (var n = 1; n <= tabs.length; n++) {
      final i = (from + direction * n) % tabs.length;
      final j = i < 0 ? i + tabs.length : i;
      if (tabs[j].enabled) return j;
    }
    return -1;
  }

  void _select(CarbonOption<T> tab) {
    if (!tab.enabled || tab.value == widget.value) return;
    widget.onChanged(tab.value);
  }

  void _handleTabFocus(Object? value, bool focused) {
    if (!focused) return;
    if (!_hasStop || _stop != value) {
      setState(() {
        _stop = value;
        _hasStop = true;
      });
    }
    _revealAfterFrame(value);
  }

  void _handleGroupFocus(bool focused) {
    if (focused || !_hasStop) return;
    setState(_clearStop);
  }

  void _revealAfterFrame(Object? value, {bool animate = true}) {
    SchedulerBinding.instance.addPostFrameCallback((_) {
      if (mounted) _reveal(value, animate: animate);
    });
  }

  void _reveal(Object? value, {required bool animate}) {
    final tabBox = _nodes[value]?.context?.findRenderObject();
    final viewBox = _viewportKey.currentContext?.findRenderObject();
    if (tabBox is! RenderBox || viewBox is! RenderBox) return;
    if (!tabBox.attached || !tabBox.hasSize || !viewBox.hasSize) return;
    if (!_scroll.hasClients) return;
    final tab = tabBox.localToGlobal(Offset.zero) & tabBox.size;
    final view = viewBox.localToGlobal(Offset.zero) & viewBox.size;
    var shift = 0.0;
    if (tab.width >= view.width || tab.left < view.left) {
      shift = view.left - tab.left;
    } else if (tab.right > view.right) {
      shift = view.right - tab.right;
    }
    if (shift == 0) return;
    final position = _scroll.position;
    final reversed = position.axisDirection == AxisDirection.left;
    final target = (position.pixels + (reversed ? shift : -shift)).clamp(
      position.minScrollExtent,
      position.maxScrollExtent,
    );
    _scrollTo(target, animate: animate);
  }

  void _scrollTo(double target, {required bool animate}) {
    final position = _scroll.position;
    final duration = animate
        ? CarbonMotion.resolve(context, CarbonMotion.moderate01)
        : Duration.zero;
    if (duration == Duration.zero) {
      position.jumpTo(target);
      return;
    }
    unawaited(
      position
          .animateTo(target, duration: duration, curve: CarbonMotion.standard)
          .then<void>((_) {}, onError: (Object _) {}),
    );
  }

  void _page(int direction) {
    if (!_scroll.hasClients) return;
    final position = _scroll.position;
    final target = (position.pixels + direction * position.viewportDimension * 0.75)
        .clamp(position.minScrollExtent, position.maxScrollExtent);
    _scrollTo(target, animate: true);
  }

  void _updateMetrics(ScrollMetrics m) {
    final content = m.viewportDimension + m.maxScrollExtent - m.minScrollExtent;
    final full = m.viewportDimension + (_overflow ? 2 * _buttonExtent : 0);
    final overflow = content > full + 0.5;
    final back = m.pixels > m.minScrollExtent + 0.5;
    final forward = m.pixels < m.maxScrollExtent - 0.5;
    if (overflow == _overflow && back == _canBack && forward == _canForward) {
      return;
    }
    void apply() {
      if (!mounted) return;
      final overflowChanged = overflow != _overflow;
      setState(() {
        _overflow = overflow;
        _canBack = back;
        _canForward = forward;
      });
      // The buttons narrow the viewport, which can push the tab that was in
      // view under them.
      if (overflowChanged) {
        _revealAfterFrame(_hasStop ? _stop : widget.value, animate: false);
      }
    }

    if (SchedulerBinding.instance.schedulerPhase ==
        SchedulerPhase.persistentCallbacks) {
      SchedulerBinding.instance.addPostFrameCallback((_) => apply());
    } else {
      apply();
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = CarbonTheme.of(context);
    final level = CarbonLayer.of(context);
    final loc = CarbonLocalizations.of(context);
    final contained = widget.variant == CarbonTabsVariant.contained;
    final height = math.max(theme.isTouch ? 48.0 : 40.0, theme.minTarget);
    _buttonExtent = theme.minTarget;

    final selected = _indexOf(widget.value);
    final stop = _stopIndex(selected);
    for (var i = 0; i < widget.tabs.length; i++) {
      _nodes[widget.tabs[i].value]?.skipTraversal = i != stop;
    }

    final scroller = LayoutBuilder(
      builder: (context, constraints) {
        final maxTab = constraints.maxWidth;
        return NotificationListener<ScrollMetricsNotification>(
          onNotification: (n) {
            _updateMetrics(n.metrics);
            return false;
          },
          child: NotificationListener<ScrollNotification>(
            onNotification: (n) {
              if (n.depth == 0) _updateMetrics(n.metrics);
              return false;
            },
            child: ScrollConfiguration(
              behavior: ScrollConfiguration.of(
                context,
              ).copyWith(scrollbars: false),
              child: SingleChildScrollView(
                key: _viewportKey,
                controller: _scroll,
                scrollDirection: Axis.horizontal,
                child: Semantics(
                  role: SemanticsRole.tabBar,
                  container: true,
                  explicitChildNodes: true,
                  label: widget.semanticLabel,
                  child: IntrinsicHeight(
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: <Widget>[
                      for (var i = 0; i < widget.tabs.length; i++)
                        ConstrainedBox(
                          constraints: BoxConstraints(maxWidth: maxTab),
                          child: _Tab(
                            option: widget.tabs[i],
                            selected: i == selected,
                            focusNode: _nodes[widget.tabs[i].value]!,
                            contained: contained,
                            level: level,
                            height: height,
                            onSelect: () => _select(widget.tabs[i]),
                            onFocusChange: (f) =>
                                _handleTabFocus(widget.tabs[i].value, f),
                          ),
                        ),
                    ],
                  ),
                  ),
                ),
              ),
            ),
          ),
        );
      },
    );

    Widget scrollButton({required bool back}) {
      final enabled = back ? _canBack : _canForward;
      return ExcludeFocus(
        child: CarbonInteraction(
          onPressed: enabled ? () => _page(back ? -1 : 1) : null,
          label: back ? loc.scrollBackward : loc.scrollForward,
          excludeChildSemantics: true,
          builder: (context, state, _) {
            final fill = state.hovered
                ? (contained
                      ? _layerAccentHover(theme, level)
                      : theme.layerHover(level))
                : (contained ? _layerAccent(theme, level) : null);
            return Container(
              width: _buttonExtent,
              height: height,
              color: fill,
              alignment: Alignment.center,
              child: CarbonIcon(
                back ? CarbonIcons.chevronLeft : CarbonIcons.chevronRight,
                size: theme.iconSize,
                color: enabled
                    ? theme.colors.iconPrimary
                    : theme.colors.iconDisabled,
              ),
            );
          },
        ),
      );
    }

    final list = DecoratedBox(
      decoration: BoxDecoration(
        border: contained
            ? null
            : Border(
                bottom: BorderSide(
                  color: theme.borderSubtle(level),
                  width: CarbonBorders.hairline,
                ),
              ),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          if (_overflow) scrollButton(back: true),
          Expanded(child: scroller),
          if (_overflow) scrollButton(back: false),
        ],
      ),
    );

    return Focus(
      canRequestFocus: false,
      skipTraversal: true,
      onKeyEvent: _onKey,
      onFocusChange: _handleGroupFocus,
      child: list,
    );
  }
}

class _Tab extends StatelessWidget {
  const _Tab({
    required this.option,
    required this.selected,
    required this.focusNode,
    required this.contained,
    required this.level,
    required this.height,
    required this.onSelect,
    required this.onFocusChange,
  });

  final CarbonOption<Object?> option;
  final bool selected;
  final FocusNode focusNode;
  final bool contained;
  final int level;
  final double height;
  final VoidCallback onSelect;
  final ValueChanged<bool> onFocusChange;

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
      button: false,
      role: SemanticsRole.tab,
      label: option.label,
      selected: selected,
      excludeChildSemantics: true,
      builder: (context, state, _) {
        final hovered = state.hovered;
        final Color? fill;
        if (contained) {
          fill = selected
              ? theme.layer(level)
              : state.pressed
              ? _layerAccentActive(theme, level)
              : hovered
              ? _layerAccentHover(theme, level)
              : _layerAccent(theme, level);
        } else {
          fill = state.pressed ? theme.layerActive(level) : null;
        }
        final Color textColor = !enabled
            ? colors.textDisabled
            : (selected || hovered)
            ? colors.textPrimary
            : colors.textSecondary;
        final Color iconColor = enabled ? textColor : colors.iconDisabled;
        const transparent = Color(0x00000000);
        final Border border;
        if (contained) {
          border = Border(
            top: BorderSide(
              color: selected && enabled ? colors.borderInteractive : transparent,
              width: CarbonBorders.selectedTab,
            ),
            right: BorderSide(
              color: theme.borderSubtle(level),
              width: CarbonBorders.hairline,
            ),
          );
        } else {
          border = Border(
            bottom: BorderSide(
              color: selected && enabled
                  ? colors.borderInteractive
                  : (hovered && enabled
                        ? theme.borderStrong(level)
                        : transparent),
              width: CarbonBorders.indicator,
            ),
          );
        }
        return ConstrainedBox(
          constraints: BoxConstraints(minHeight: height),
          child: CarbonFocusRing(
            visible: state.focusVisible,
            child: DecoratedBox(
              decoration: BoxDecoration(color: fill, border: border),
              child: Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: CarbonSpacing.spacing05,
                  vertical: CarbonSpacing.spacing03,
                ),
                child: Center(
                  widthFactor: 1,
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: <Widget>[
                      if (option.icon != null) ...<Widget>[
                        IconTheme(
                          data: IconThemeData(
                            color: iconColor,
                            size: theme.iconSize,
                          ),
                          child: option.icon!,
                        ),
                        const SizedBox(width: CarbonSpacing.spacing03),
                      ],
                      Flexible(
                        child: Text(
                          option.label,
                          style: theme.typography.control.copyWith(
                            color: textColor,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        );
      },
    );
  }
}

Color _layerAccent(CarbonThemeData theme, int level) => switch (level) {
  2 => theme.colors.layerAccent02,
  3 => theme.colors.layerAccent03,
  _ => theme.colors.layerAccent01,
};

Color _layerAccentHover(CarbonThemeData theme, int level) => switch (level) {
  2 => theme.colors.layerAccentHover02,
  3 => theme.colors.layerAccentHover03,
  _ => theme.colors.layerAccentHover01,
};

Color _layerAccentActive(CarbonThemeData theme, int level) => switch (level) {
  2 => theme.colors.layerAccentActive02,
  3 => theme.colors.layerAccentActive03,
  _ => theme.colors.layerAccentActive01,
};

/// One pane of a [CarbonTabPanels].
class CarbonTabPanel<T> {
  const CarbonTabPanel({required this.value, required this.child});

  /// The tab value this pane belongs to.
  final T value;
  final Widget child;
}

/// Shows the pane for the selected tab and keeps the others alive but inert.
///
/// A hidden pane stays mounted when [keepAlive] is true, so its state (scroll
/// offset, entered text, a running terminal view) survives switching tabs. An
/// `Offstage` child alone would keep animating and stay reachable by Tab, so
/// every hidden pane is wrapped in `TickerMode(enabled: false)` and
/// `ExcludeFocus`, and removed from semantics and painting.
///
/// Panes mount lazily: a pane is built the first time its tab is selected.
/// With [keepAlive] false only the selected pane exists, and leaving a tab
/// discards its state.
///
/// Typical composition:
///
/// ```dart
/// Column(children: [
///   CarbonTabs<String>(tabs: tabs, value: selected, onChanged: select),
///   Expanded(child: CarbonTabPanels<String>(
///     value: selected,
///     panels: [
///       CarbonTabPanel(value: 'files', child: FilesView()),
///       CarbonTabPanel(value: 'git', child: GitView()),
///     ],
///   )),
/// ])
/// ```
class CarbonTabPanels<T> extends StatefulWidget {
  const CarbonTabPanels({
    super.key,
    required this.value,
    required this.panels,
    this.keepAlive = true,
  });

  final T? value;
  final List<CarbonTabPanel<T>> panels;
  final bool keepAlive;

  @override
  State<CarbonTabPanels<T>> createState() => _CarbonTabPanelsState<T>();
}

class _CarbonTabPanelsState<T> extends State<CarbonTabPanels<T>> {
  final Set<Object?> _built = <Object?>{};

  @override
  Widget build(BuildContext context) {
    _built.add(widget.value);
    return Stack(
      fit: StackFit.passthrough,
      children: <Widget>[
        for (final panel in widget.panels)
          _pane(panel, active: panel.value == widget.value),
      ],
    );
  }

  Widget _pane(CarbonTabPanel<T> panel, {required bool active}) {
    final key = ValueKey<Object?>(panel.value);
    if (!active && (!widget.keepAlive || !_built.contains(panel.value))) {
      return SizedBox.shrink(key: key);
    }
    return Offstage(
      key: key,
      offstage: !active,
      child: TickerMode(
        enabled: active,
        child: ExcludeFocus(
          excluding: !active,
          child: Semantics(
            role: SemanticsRole.tabPanel,
            container: true,
            child: panel.child,
          ),
        ),
      ),
    );
  }
}
