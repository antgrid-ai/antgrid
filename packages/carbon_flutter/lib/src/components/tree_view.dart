import 'dart:math' as math;

import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

import '../foundations/icons.dart';
import '../foundations/theme.dart';
import '../foundations/tokens.dart';
import '../primitives/focus_ring.dart';

/// Carbon's tree view sizes: `xs` is 24 tall and `sm` is 32. Touch density
/// ignores the choice and uses the theme's touch target.
enum CarbonTreeViewSize { xs, sm }

/// One visible row of a [CarbonTreeView], described by the host.
///
/// The tree is flat: the host walks its own hierarchy, skips the children of
/// collapsed branches and hands over the remaining rows in display order, each
/// with its [depth]. Rows that are not nodes (a "loading" or "no results"
/// line) are leaves with [interactive] false.
@immutable
class CarbonTreeNodeData {
  const CarbonTreeNodeData({
    required this.id,
    required this.label,
    this.depth = 0,
    this.isBranch = false,
    this.expanded = false,
    this.selected = false,
    this.active = false,
    this.disabled = false,
    this.interactive = true,
    this.leading,
    this.content,
    this.trailing,
    this.trailingOnHover = false,
    this.semanticLabel,
  });

  /// Identifies the row in callbacks and keeps its state when the list
  /// changes. Must be unique among the visible rows.
  final Object id;

  /// The row's text, and its typeahead and accessible name unless
  /// [semanticLabel] says otherwise.
  final String label;

  /// 0 for top-level rows.
  final int depth;

  /// Shows the disclosure chevron. A branch with no children yet (not loaded)
  /// is still a branch.
  final bool isBranch;

  /// Whether a branch's children are shown. Ignored for leaves.
  final bool expanded;

  /// The row is part of the selection: a `layer-selected` fill.
  final bool selected;

  /// The row is the current one (the open file): a start bar and heavier
  /// label. It neither fills nor announces as selected; that is [selected].
  final bool active;

  /// Dimmed, unfocusable and inert.
  final bool disabled;

  /// False for rows that only occupy a line: not focusable, not hoverable,
  /// not announced as a tree item, and drawn in the normal text colour.
  final bool interactive;

  /// Icon slot after the chevron, `iconSize` square with the widget centred.
  final Widget? leading;

  /// Replaces the label text. [label] stays the accessible name; the content
  /// is hidden from semantics.
  final Widget? content;

  /// Marks at the end of the row (badges, counts). Not part of upstream
  /// (deviation CTV-trailing).
  final Widget? trailing;

  /// Shows [trailing] only while the pointer is over the row or it is the
  /// focused row; touch density always shows it. The space stays reserved so
  /// the label never reflows.
  final bool trailingOnHover;

  /// Overrides [label] as the accessible name.
  final String? semanticLabel;

  bool get focusable => interactive && !disabled;
}

/// A lazily built tree of [CarbonTreeNodeData] rows in a scroll view.
///
/// The host owns expansion and selection: [onToggle], [onSelect] and
/// [onActivate] report intent and the host answers by rebuilding with new row
/// data. The widget owns only keyboard focus, as a single tab stop that moves
/// between rows (the ARIA tree pattern).
///
/// * Tap or Enter on a row: [onSelect]; a branch also [onToggle]s and a leaf
///   also [onActivate]s.
/// * Space: [onSelect]; a leaf also [onActivate]s.
/// * Up/Down move, Home/End jump. Right opens a closed branch or enters an
///   open one; Left closes an open branch or goes to the parent.
/// * Printable keys jump to the next row whose label starts with what was
///   typed.
///
/// Every row has the same height, [rowExtent], so hosts can turn a row index
/// into a scroll offset. Use [CarbonTreeViewSliver] directly inside a
/// [CustomScrollView] to compose with other slivers.
class CarbonTreeView extends StatelessWidget {
  const CarbonTreeView({
    super.key,
    required this.itemCount,
    required this.itemBuilder,
    this.onToggle,
    this.onSelect,
    this.onActivate,
    this.size = CarbonTreeViewSize.sm,
    this.focusNode,
    this.controller,
    this.physics,
    this.shrinkWrap = false,
    this.padding,
    this.semanticLabel,
  });

  final int itemCount;

  /// Describes the row at an index. Called while building and, for keyboard
  /// navigation, for rows that are not on screen, so keep it cheap.
  final CarbonTreeNodeData Function(BuildContext context, int index)
  itemBuilder;
  final ValueChanged<Object>? onToggle;
  final ValueChanged<Object>? onSelect;
  final ValueChanged<Object>? onActivate;
  final CarbonTreeViewSize size;

  /// The tree's one focus node; the tree owns one when null.
  final FocusNode? focusNode;
  final ScrollController? controller;
  final ScrollPhysics? physics;
  final bool shrinkWrap;
  final EdgeInsetsGeometry? padding;

  /// The tree's accessible name.
  final String? semanticLabel;

  /// The height of every row for [theme] and [textScaler]: the size's height
  /// (the touch target under touch density), or the line height of the scaled
  /// label plus 2 above and below when that is taller.
  static double rowExtent(
    CarbonThemeData theme,
    TextScaler textScaler, {
    CarbonTreeViewSize size = CarbonTreeViewSize.sm,
  }) {
    final floor = theme.isTouch
        ? theme.minTarget
        : switch (size) {
            CarbonTreeViewSize.xs => 24.0,
            CarbonTreeViewSize.sm => 32.0,
          };
    final style = theme.typography.control;
    final fontSize = style.fontSize ?? 14;
    // The epsilon keeps 14 * 2 * (18 / 14) from ceiling to 37.
    final line =
        (textScaler.scale(fontSize) * (style.height ?? 1.2) - 1e-6)
            .ceilToDouble();
    return math.max(floor, line + 2 * CarbonSpacing.spacing01);
  }

  /// [rowExtent] for the theme and text scale in [context].
  static double rowExtentOf(
    BuildContext context, {
    CarbonTreeViewSize size = CarbonTreeViewSize.sm,
  }) => rowExtent(
    CarbonTheme.of(context),
    MediaQuery.textScalerOf(context),
    size: size,
  );

  @override
  Widget build(BuildContext context) {
    final label = semanticLabel;
    final scroll = CustomScrollView(
      controller: controller,
      physics: physics,
      shrinkWrap: shrinkWrap,
      slivers: <Widget>[
        SliverPadding(
          padding: padding ?? EdgeInsets.zero,
          sliver: CarbonTreeViewSliver(
            itemCount: itemCount,
            itemBuilder: itemBuilder,
            onToggle: onToggle,
            onSelect: onSelect,
            onActivate: onActivate,
            size: size,
            focusNode: focusNode,
          ),
        ),
      ],
    );
    if (label == null) return scroll;
    return Semantics(container: true, label: label, child: scroll);
  }
}

/// The rows of a [CarbonTreeView] as a sliver, for a [CustomScrollView] that
/// also holds other content. Takes the same row model and keyboard behaviour.
class CarbonTreeViewSliver extends StatefulWidget {
  const CarbonTreeViewSliver({
    super.key,
    required this.itemCount,
    required this.itemBuilder,
    this.onToggle,
    this.onSelect,
    this.onActivate,
    this.size = CarbonTreeViewSize.sm,
    this.focusNode,
  });

  final int itemCount;
  final CarbonTreeNodeData Function(BuildContext context, int index)
  itemBuilder;
  final ValueChanged<Object>? onToggle;
  final ValueChanged<Object>? onSelect;
  final ValueChanged<Object>? onActivate;
  final CarbonTreeViewSize size;
  final FocusNode? focusNode;

  @override
  State<CarbonTreeViewSliver> createState() => _CarbonTreeViewSliverState();
}

class _CarbonTreeViewSliverState extends State<CarbonTreeViewSliver> {
  FocusNode? _ownedNode;
  Object? _focusedId;
  int _focusedIndexHint = 0;

  // Set by a pointer press so a click never paints a keyboard ring; cleared
  // when focus leaves or a key moves it.
  bool _pointerFocus = false;
  String _typed = '';
  DateTime _typedAt = DateTime.fromMillisecondsSinceEpoch(0);

  static const Duration _typeaheadWindow = Duration(milliseconds: 500);

  FocusNode get _node => widget.focusNode ?? _ownedNode!;

  @override
  void initState() {
    super.initState();
    if (widget.focusNode == null) {
      _ownedNode = FocusNode(debugLabel: 'CarbonTreeView');
    }
  }

  @override
  void didUpdateWidget(CarbonTreeViewSliver oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.focusNode == null && _ownedNode == null) {
      _ownedNode = FocusNode(debugLabel: 'CarbonTreeView');
    }
  }

  @override
  void dispose() {
    _ownedNode?.dispose();
    super.dispose();
  }

  CarbonTreeNodeData _data(int index) => widget.itemBuilder(context, index);

  /// The focused row's index, re-finding it by id when the list shifted.
  int? _indexOfFocused() {
    final id = _focusedId;
    final count = widget.itemCount;
    if (id == null || count == 0) return null;
    final hint = _focusedIndexHint;
    if (hint < count && _data(hint).id == id) return hint;
    for (var i = 0; i < count; i++) {
      if (_data(i).id == id) return i;
    }
    return null;
  }

  /// Where focus lands when nothing valid holds it: the selected row, then
  /// the first focusable one.
  int? _fallbackIndex() {
    int? first;
    for (var i = 0; i < widget.itemCount; i++) {
      final row = _data(i);
      if (!row.focusable) continue;
      if (row.selected) return i;
      first ??= i;
    }
    return first;
  }

  int? _resolveIndex() => _indexOfFocused() ?? _fallbackIndex();

  void _setFocused(int index) {
    final row = _data(index);
    setState(() {
      _focusedId = row.id;
      _focusedIndexHint = index;
    });
    _reveal(index);
  }

  void _reveal(int index) {
    final position = Scrollable.maybeOf(context)?.position;
    final box = context.findRenderObject();
    if (position == null ||
        box is! RenderSliver ||
        !box.attached ||
        !position.hasContentDimensions) {
      return;
    }
    final extent = CarbonTreeView.rowExtentOf(context, size: widget.size);
    final top = box.constraints.precedingScrollExtent + index * extent;
    final bottom = top + extent;
    double? target;
    if (top < position.pixels) {
      target = top;
    } else if (bottom > position.pixels + position.viewportDimension) {
      target = bottom - position.viewportDimension;
    }
    if (target == null) return;
    position.jumpTo(
      target.clamp(position.minScrollExtent, position.maxScrollExtent),
    );
  }

  void _handleFocusChange(bool focused) {
    if (!focused) {
      setState(() => _pointerFocus = false);
      return;
    }
    if (_indexOfFocused() == null) {
      final fallback = _fallbackIndex();
      if (fallback != null) {
        _setFocused(fallback);
        return;
      }
    }
    setState(() {});
  }

  int? _step(int from, int delta) {
    for (var i = from + delta; i >= 0 && i < widget.itemCount; i += delta) {
      if (_data(i).focusable) return i;
    }
    return null;
  }

  int? _parentOf(int index) {
    final depth = _data(index).depth;
    for (var i = index - 1; i >= 0; i--) {
      final row = _data(i);
      if (row.depth < depth && row.focusable) return i;
    }
    return null;
  }

  void _select(CarbonTreeNodeData row) {
    widget.onSelect?.call(row.id);
  }

  /// Tap and Enter.
  void _primary(CarbonTreeNodeData row) {
    if (!row.focusable) return;
    _select(row);
    if (row.isBranch) {
      widget.onToggle?.call(row.id);
    } else {
      widget.onActivate?.call(row.id);
    }
  }

  /// Space: selects without toggling a branch.
  void _secondary(CarbonTreeNodeData row) {
    if (!row.focusable) return;
    _select(row);
    if (!row.isBranch) widget.onActivate?.call(row.id);
  }

  void _handleTap(int index) {
    final row = _data(index);
    if (!row.focusable) return;
    _pointerFocus = true;
    _node.requestFocus();
    _setFocused(index);
    _primary(row);
  }

  void _typeahead(String character, int from) {
    final now = DateTime.now();
    if (now.difference(_typedAt) > _typeaheadWindow) _typed = '';
    _typedAt = now;
    _typed += character.toLowerCase();
    final count = widget.itemCount;
    // A repeated single letter cycles through rows starting with it.
    final cycling = _typed.length > 1 && _typed.split('').toSet().length == 1;
    final needle = cycling ? _typed[0] : _typed;
    final start = _typed.length == 1 || cycling ? from + 1 : from;
    for (var n = 0; n < count; n++) {
      final i = (start + n) % count;
      final row = _data(i);
      if (row.focusable && row.label.toLowerCase().startsWith(needle)) {
        _setFocused(i);
        return;
      }
    }
  }

  KeyEventResult _onKey(FocusNode node, KeyEvent event) {
    if (event is KeyUpEvent) return KeyEventResult.ignored;
    final keyboard = HardwareKeyboard.instance;
    if (keyboard.isControlPressed ||
        keyboard.isAltPressed ||
        keyboard.isMetaPressed) {
      return KeyEventResult.ignored;
    }
    final key = event.logicalKey;
    final index = _resolveIndex();
    if (index == null) return KeyEventResult.ignored;
    final row = _data(index);
    final rtl = Directionality.of(context) == TextDirection.rtl;
    final open = rtl ? LogicalKeyboardKey.arrowLeft : LogicalKeyboardKey.arrowRight;
    final close = rtl ? LogicalKeyboardKey.arrowRight : LogicalKeyboardKey.arrowLeft;
    final repeat = event is KeyRepeatEvent;

    void focusIndex(int? target) {
      if (target != null) _setFocused(target);
    }

    if (key == LogicalKeyboardKey.arrowDown) {
      focusIndex(_step(index, 1));
    } else if (key == LogicalKeyboardKey.arrowUp) {
      focusIndex(_step(index, -1));
    } else if (key == LogicalKeyboardKey.home) {
      focusIndex(_step(-1, 1));
    } else if (key == LogicalKeyboardKey.end) {
      focusIndex(_step(widget.itemCount, -1));
    } else if (key == open) {
      if (row.isBranch && !row.expanded) {
        widget.onToggle?.call(row.id);
        _setFocused(index);
      } else if (row.isBranch && index + 1 < widget.itemCount) {
        final child = _data(index + 1);
        focusIndex(child.depth > row.depth && child.focusable ? index + 1 : null);
      }
    } else if (key == close) {
      if (row.isBranch && row.expanded) {
        widget.onToggle?.call(row.id);
        _setFocused(index);
      } else {
        focusIndex(_parentOf(index));
      }
    } else if (!repeat &&
        (key == LogicalKeyboardKey.enter ||
            key == LogicalKeyboardKey.numpadEnter)) {
      _setFocused(index);
      _primary(row);
    } else if (!repeat && key == LogicalKeyboardKey.space) {
      _setFocused(index);
      _secondary(row);
    } else {
      final character = event.character;
      if (character == null ||
          character.length != 1 ||
          character.trim().isEmpty) {
        return KeyEventResult.ignored;
      }
      _typeahead(character, index);
    }
    _pointerFocus = false;
    return KeyEventResult.handled;
  }

  Widget _buildRow(BuildContext context, int index, double extent) {
    final row = _data(index);
    final hasFocus = _node.hasFocus;
    final isFocusedRow = hasFocus && row.id == _focusedId;
    return _TreeRow(
      key: ValueKey<Object>(row.id),
      data: row,
      extent: extent,
      ringVisible: isFocusedRow && !_pointerFocus,
      focusedRow: isFocusedRow,
      onTap: row.focusable ? () => _handleTap(index) : null,
    );
  }

  @override
  Widget build(BuildContext context) {
    final extent = CarbonTreeView.rowExtentOf(context, size: widget.size);
    return Focus(
      focusNode: _node,
      includeSemantics: false,
      onKeyEvent: _onKey,
      onFocusChange: _handleFocusChange,
      child: SliverFixedExtentList(
        itemExtent: extent,
        delegate: SliverChildBuilderDelegate(
          (context, index) => _buildRow(context, index, extent),
          childCount: widget.itemCount,
          addAutomaticKeepAlives: false,
        ),
      ),
    );
  }
}

class _TreeRow extends StatefulWidget {
  const _TreeRow({
    super.key,
    required this.data,
    required this.extent,
    required this.ringVisible,
    required this.focusedRow,
    required this.onTap,
  });

  final CarbonTreeNodeData data;
  final double extent;
  final bool ringVisible;
  final bool focusedRow;
  final VoidCallback? onTap;

  @override
  State<_TreeRow> createState() => _TreeRowState();
}

class _TreeRowState extends State<_TreeRow> {
  bool _hovered = false;
  bool _pressed = false;

  void _set({bool? hovered, bool? pressed}) {
    final nextHovered = hovered ?? _hovered;
    final nextPressed = pressed ?? _pressed;
    if (nextHovered == _hovered && nextPressed == _pressed) return;
    setState(() {
      _hovered = nextHovered;
      _pressed = nextPressed;
    });
  }

  @override
  Widget build(BuildContext context) {
    final data = widget.data;
    final theme = CarbonTheme.of(context);
    final colors = theme.colors;
    final level = CarbonLayer.of(context);
    final enabled = widget.onTap != null;
    final hovered = _hovered && enabled;
    final pressed = _pressed && enabled;
    final highlighted = data.selected || data.active;

    final Color? fill = pressed
        ? theme.layerActive(level)
        : data.selected
        ? (hovered ? theme.layerSelectedHover(level) : theme.layerSelected(level))
        : hovered
        ? theme.layerHover(level)
        : null;
    final textColor = data.disabled
        ? colors.textDisabled
        : !data.interactive
        ? colors.textSecondary
        : (highlighted || hovered)
        ? colors.textPrimary
        : colors.textSecondary;
    final iconColor = data.disabled ? colors.iconDisabled : colors.iconSecondary;
    final rtl = Directionality.of(context) == TextDirection.rtl;
    final duration = CarbonMotion.resolve(context, CarbonMotion.fast02);
    final slot = theme.iconSize;
    final start =
        CarbonSpacing.spacing05 + data.depth * _depthStep;
    final showTrailing =
        data.trailing != null &&
        (!data.trailingOnHover ||
            theme.isTouch ||
            hovered ||
            widget.focusedRow);

    Widget iconSlot(Widget? child) => IconTheme(
      data: IconThemeData(color: iconColor, size: slot),
      child: SizedBox.square(dimension: slot, child: Center(child: child)),
    );

    final visual = SizedBox(
      height: widget.extent,
      child: DecoratedBox(
        position: DecorationPosition.foreground,
        decoration: BoxDecoration(
          border: data.active
              ? BorderDirectional(
                  start: BorderSide(
                    color: colors.borderInteractive,
                    width: _activeBarWidth,
                  ),
                )
              : null,
        ),
        child: CarbonFocusRing(
          visible: widget.ringVisible,
          child: ColoredBox(
            color: fill ?? const Color(0x00000000),
            child: Padding(
              padding: EdgeInsetsDirectional.only(
                start: start,
                end: CarbonSpacing.spacing03,
              ),
              child: Row(
                children: <Widget>[
                  ExcludeSemantics(
                    child: iconSlot(
                      data.isBranch
                          ? AnimatedRotation(
                              turns: data.expanded ? 0 : (rtl ? 0.25 : -0.25),
                              duration: duration,
                              child: const CarbonIcon(CarbonIcons.chevronDown),
                            )
                          : null,
                    ),
                  ),
                  if (data.leading != null) ...<Widget>[
                    const SizedBox(width: CarbonSpacing.spacing02),
                    ExcludeSemantics(child: iconSlot(data.leading)),
                  ],
                  const SizedBox(width: CarbonSpacing.spacing03),
                  Expanded(
                    child: ExcludeSemantics(
                      child: DefaultTextStyle(
                        style: theme.typography.control.copyWith(
                          color: textColor,
                          fontWeight: data.active ? FontWeight.w600 : null,
                        ),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        child: data.content ?? Text(data.label),
                      ),
                    ),
                  ),
                  if (data.trailing != null) ...<Widget>[
                    const SizedBox(width: CarbonSpacing.spacing03),
                    Visibility(
                      visible: showTrailing,
                      maintainState: true,
                      maintainAnimation: true,
                      maintainSize: true,
                      child: data.trailing!,
                    ),
                  ],
                ],
              ),
            ),
          ),
        ),
      ),
    );

    if (!data.interactive) {
      return Semantics(container: true, label: data.label, child: visual);
    }

    return Semantics(
      container: true,
      label: data.semanticLabel ?? data.label,
      selected: data.selected,
      expanded: data.isBranch ? data.expanded : null,
      enabled: !data.disabled,
      focused: widget.focusedRow,
      onTap: widget.onTap,
      child: MouseRegion(
        cursor: enabled ? SystemMouseCursors.click : SystemMouseCursors.basic,
        onEnter: (_) => _set(hovered: true),
        onExit: (_) => _set(hovered: false),
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          excludeFromSemantics: true,
          onTapDown: enabled ? (_) => _set(pressed: true) : null,
          onTapCancel: enabled ? () => _set(pressed: false) : null,
          onTapUp: enabled ? (_) => _set(pressed: false) : null,
          onTap: widget.onTap,
          child: visual,
        ),
      ),
    );
  }
}

// Upstream's active node paints a 4px bar on the label's start edge.
const double _activeBarWidth = 4;

// Upstream steps `depth + depth * 0.5` rem per level.
const double _depthStep = 24;
