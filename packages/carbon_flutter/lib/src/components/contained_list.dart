import 'package:flutter/widgets.dart';

import '../foundations/icons.dart';
import '../foundations/localizations.dart';
import '../foundations/theme.dart';
import '../foundations/tokens.dart';
import '../primitives/focus_ring.dart';
import '../primitives/interaction.dart';
import 'inline_loading.dart';

/// How a contained list sits in its surroundings.
enum CarbonContainedListVariant {
  /// A self-contained list on the page: header and rows are filled with the
  /// current layer.
  onPage,

  /// A list shown inside another container (a panel or popover): nothing is
  /// filled, only rules separate header and rows, so it takes the container's
  /// surface.
  disclosed,
}

/// What a contained list shows in place of its rows.
enum CarbonContainedListStatus {
  /// The rows, or the empty slot when there are none.
  content,

  /// The loading slot, while the host fetches.
  loading,

  /// The error slot.
  error,
}

class _ListScope extends InheritedWidget {
  const _ListScope({
    required this.variant,
    required this.inset,
    required super.child,
  });

  final CarbonContainedListVariant variant;
  final bool inset;

  static _ListScope? maybeOf(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<_ListScope>();

  @override
  bool updateShouldNotify(_ListScope old) =>
      old.variant != variant || old.inset != inset;
}

Color _baseFill(
  CarbonThemeData theme,
  int level,
  CarbonContainedListVariant variant,
) => variant == CarbonContainedListVariant.onPage
    ? theme.layer(level)
    : const Color(0x00000000);

Widget _header(
  BuildContext context, {
  required String label,
  required Widget? action,
  required CarbonContainedListVariant variant,
}) {
  final theme = CarbonTheme.of(context);
  final level = CarbonLayer.of(context);
  return DecoratedBox(
    decoration: BoxDecoration(
      color: _baseFill(theme, level, variant),
      border: Border(
        bottom: BorderSide(
          color: theme.borderSubtle(level),
          width: CarbonBorders.hairline,
        ),
      ),
    ),
    child: ConstrainedBox(
      constraints: BoxConstraints(minHeight: theme.minTarget),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: <Widget>[
          Expanded(
            child: Padding(
              padding: const EdgeInsetsDirectional.symmetric(
                horizontal: CarbonSpacing.spacing05,
                vertical: CarbonSpacing.spacing03,
              ),
              child: Semantics(
                header: true,
                child: Text(
                  label,
                  style: theme.typography.heading.copyWith(
                    color: theme.colors.textPrimary,
                  ),
                ),
              ),
            ),
          ),
          if (action != null)
            Padding(
              padding: const EdgeInsetsDirectional.only(
                end: CarbonSpacing.spacing03,
              ),
              child: action,
            ),
        ],
      ),
    ),
  );
}

/// The loading, error or empty content, or null when rows should show.
Widget? _slot(
  BuildContext context, {
  required CarbonContainedListStatus status,
  required bool isEmpty,
  required CarbonContainedListVariant variant,
  required Widget? loadingContent,
  required Widget? errorContent,
  required Widget? emptyContent,
}) {
  final theme = CarbonTheme.of(context);
  final level = CarbonLayer.of(context);
  final loc = CarbonLocalizations.of(context);
  final Widget content;
  switch (status) {
    case CarbonContainedListStatus.loading:
      content =
          loadingContent ??
          CarbonInlineLoading(
            status: CarbonInlineLoadingStatus.active,
            description: loc.loading,
          );
    case CarbonContainedListStatus.error:
      content = Semantics(
        liveRegion: true,
        child:
            errorContent ??
            Row(
              mainAxisSize: MainAxisSize.min,
              children: <Widget>[
                CarbonIcon(
                  CarbonIcons.errorFilled,
                  size: theme.iconSize,
                  color: theme.colors.supportError,
                ),
                const SizedBox(width: CarbonSpacing.spacing03),
                Flexible(
                  child: Text(
                    loc.error,
                    style: theme.typography.control.copyWith(
                      color: theme.colors.textPrimary,
                    ),
                  ),
                ),
              ],
            ),
      );
    case CarbonContainedListStatus.content:
      if (!isEmpty) return null;
      content =
          emptyContent ??
          Text(
            loc.noResults,
            style: theme.typography.control.copyWith(
              color: theme.colors.textSecondary,
            ),
          );
  }
  return DecoratedBox(
    decoration: BoxDecoration(color: _baseFill(theme, level, variant)),
    child: ConstrainedBox(
      constraints: BoxConstraints(minHeight: theme.minTarget),
      child: Align(
        alignment: AlignmentDirectional.centerStart,
        child: Padding(
          padding: const EdgeInsetsDirectional.symmetric(
            horizontal: CarbonSpacing.spacing05,
            vertical: CarbonSpacing.spacing03,
          ),
          child: content,
        ),
      ),
    ),
  );
}

/// A titled group of rows: a header with an optional action, then
/// [CarbonContainedListRow]s.
///
/// Build the rows yourself with [children], or use [CarbonContainedList.builder]
/// or [CarbonContainedListSliver] so large lists create rows lazily. The host
/// owns loading and failure: set [status] and supply the slots; the list never
/// fetches. With [CarbonContainedListStatus.content] and no rows the
/// [emptyContent] slot shows. Each slot has a localized default.
///
/// [inset] starts the separating rules one gutter in from the leading edge.
class CarbonContainedList extends StatelessWidget {
  /// A list whose rows are all built up front. Prefer [CarbonContainedList.builder]
  /// beyond a few dozen rows.
  const CarbonContainedList({
    super.key,
    required this.label,
    required List<Widget> this.children,
    this.action,
    this.variant = CarbonContainedListVariant.onPage,
    this.inset = false,
    this.status = CarbonContainedListStatus.content,
    this.loadingContent,
    this.errorContent,
    this.emptyContent,
  }) : itemCount = null,
       controller = null,
       itemBuilder = null;

  /// A list that builds rows on demand inside a scrollable region.
  ///
  /// The header stays pinned above the rows and the list scrolls beneath it,
  /// so the parent must give it a bounded height (put it in an `Expanded` or a
  /// `SizedBox`). For a list inside a larger scrolling page use
  /// [CarbonContainedListSliver].
  const CarbonContainedList.builder({
    super.key,
    required this.label,
    required int this.itemCount,
    required IndexedWidgetBuilder this.itemBuilder,
    this.action,
    this.variant = CarbonContainedListVariant.onPage,
    this.inset = false,
    this.status = CarbonContainedListStatus.content,
    this.loadingContent,
    this.errorContent,
    this.emptyContent,
    this.controller,
  }) : children = null;

  final String label;

  /// Shown at the trailing end of the header, typically a small ghost
  /// `CarbonButton`.
  final Widget? action;
  final CarbonContainedListVariant variant;
  final bool inset;
  final CarbonContainedListStatus status;
  final Widget? loadingContent;
  final Widget? errorContent;
  final Widget? emptyContent;
  final List<Widget>? children;
  final int? itemCount;
  final IndexedWidgetBuilder? itemBuilder;

  /// Scroll controller of the lazy list ([CarbonContainedList.builder] only).
  final ScrollController? controller;

  @override
  Widget build(BuildContext context) {
    final isEmpty = children?.isEmpty ?? itemCount == 0;
    final slot = _slot(
      context,
      status: status,
      isEmpty: isEmpty,
      variant: variant,
      loadingContent: loadingContent,
      errorContent: errorContent,
      emptyContent: emptyContent,
    );
    final header = _header(
      context,
      label: label,
      action: action,
      variant: variant,
    );
    final Widget body;
    if (slot != null) {
      body = slot;
    } else if (children != null) {
      body = Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: children!,
      );
    } else {
      body = ListView.builder(
        controller: controller,
        padding: EdgeInsets.zero,
        itemCount: itemCount,
        itemBuilder: itemBuilder!,
      );
    }
    return _ListScope(
      variant: variant,
      inset: inset,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          header,
          if (children == null && slot == null) Flexible(child: body) else body,
        ],
      ),
    );
  }
}

/// The lazy, sliver form of [CarbonContainedList] for use in a
/// `CustomScrollView`. Rows are created only as they scroll into view, so the
/// list may be arbitrarily long.
class CarbonContainedListSliver extends StatelessWidget {
  const CarbonContainedListSliver({
    super.key,
    required this.label,
    required this.itemCount,
    required this.itemBuilder,
    this.action,
    this.variant = CarbonContainedListVariant.onPage,
    this.inset = false,
    this.status = CarbonContainedListStatus.content,
    this.loadingContent,
    this.errorContent,
    this.emptyContent,
  });

  final String label;
  final int itemCount;
  final IndexedWidgetBuilder itemBuilder;
  final Widget? action;
  final CarbonContainedListVariant variant;
  final bool inset;
  final CarbonContainedListStatus status;
  final Widget? loadingContent;
  final Widget? errorContent;
  final Widget? emptyContent;

  @override
  Widget build(BuildContext context) {
    final slot = _slot(
      context,
      status: status,
      isEmpty: itemCount == 0,
      variant: variant,
      loadingContent: loadingContent,
      errorContent: errorContent,
      emptyContent: emptyContent,
    );
    return _ListScope(
      variant: variant,
      inset: inset,
      child: SliverMainAxisGroup(
        slivers: <Widget>[
          SliverToBoxAdapter(
            child: _header(
              context,
              label: label,
              action: action,
              variant: variant,
            ),
          ),
          if (slot != null)
            SliverToBoxAdapter(child: slot)
          else
            SliverList.builder(itemCount: itemCount, itemBuilder: itemBuilder),
        ],
      ),
    );
  }
}

/// One row of a [CarbonContainedList].
///
/// The row's own target (leading content, [title], [secondary]) and each of
/// the trailing [actions] are separate targets: activating an action never
/// activates the row, and keyboard focus visits the row first, then each
/// action in order.
///
/// A row with neither [onPressed] nor [onSelectedChanged] is static: not
/// focusable and not announced as a button. [onSelectedChanged] makes the row
/// a selection toggle that reports the opposite of [selected]; otherwise
/// [onPressed] runs and [selected] only styles the row, which suits
/// single-selection lists the host manages itself. Pass [selected] on every
/// row of such a list, false included, so each row announces its selected
/// state; leave it null for rows that are not part of a selection.
///
/// The row is at least 32 (compact) or 48 (touch) tall and grows with its
/// text, which wraps. With [revealActionsOnHover] the actions of a compact row
/// show only while the pointer is over the row or focus is inside it; touch
/// density always shows them, because there is no hover to reveal them.
class CarbonContainedListRow extends StatefulWidget {
  const CarbonContainedListRow({
    super.key,
    required this.title,
    this.secondary,
    this.leading,
    this.actions = const <Widget>[],
    this.onPressed,
    this.onSelectedChanged,
    this.selected,
    this.revealActionsOnHover = false,
    this.focusNode,
  });

  final String title;

  /// A second line of supporting text; wraps.
  final String? secondary;

  /// A glyph or avatar before the text. Keep it decorative: the row's name
  /// comes from [title].
  final Widget? leading;

  /// Trailing controls, typically `CarbonButton.iconOnly`.
  final List<Widget> actions;

  final VoidCallback? onPressed;
  final ValueChanged<bool>? onSelectedChanged;
  final bool? selected;
  final bool revealActionsOnHover;
  final FocusNode? focusNode;

  @override
  State<CarbonContainedListRow> createState() => _CarbonContainedListRowState();
}

class _CarbonContainedListRowState extends State<CarbonContainedListRow> {
  bool _hovered = false;
  bool _focusWithin = false;

  VoidCallback? get _activate {
    final toggle = widget.onSelectedChanged;
    if (toggle != null) return () => toggle(!(widget.selected ?? false));
    return widget.onPressed;
  }

  void _setHover(bool value) {
    if (_hovered != value) setState(() => _hovered = value);
  }

  void _setFocusWithin(bool value) {
    if (_focusWithin != value) setState(() => _focusWithin = value);
  }

  @override
  Widget build(BuildContext context) {
    final theme = CarbonTheme.of(context);
    final colors = theme.colors;
    final level = CarbonLayer.of(context);
    final scope = _ListScope.maybeOf(context);
    final variant = scope?.variant ?? CarbonContainedListVariant.onPage;
    final inset = scope?.inset ?? false;
    final activate = _activate;
    final interactive = activate != null;
    final selected = widget.selected ?? false;
    final selectable =
        widget.onSelectedChanged != null || widget.selected != null;
    final secondary = widget.secondary;

    final Color fill;
    if (selected) {
      fill = _hovered && interactive
          ? theme.layerSelectedHover(level)
          : theme.layerSelected(level);
    } else if (_hovered && interactive) {
      fill = theme.layerHover(level);
    } else {
      fill = _baseFill(theme, level, variant);
    }

    final text = Padding(
      padding: EdgeInsetsDirectional.only(
        start: CarbonSpacing.spacing05,
        end: CarbonSpacing.spacing03,
        top: secondary == null ? CarbonSpacing.spacing02 : CarbonSpacing.spacing03,
        bottom: secondary == null ? CarbonSpacing.spacing02 : CarbonSpacing.spacing03,
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: <Widget>[
          if (widget.leading != null) ...<Widget>[
            IconTheme(
              data: IconThemeData(
                color: colors.iconPrimary,
                size: theme.iconSize,
              ),
              child: widget.leading!,
            ),
            const SizedBox(width: CarbonSpacing.spacing04),
          ],
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: <Widget>[
                Text(
                  widget.title,
                  style: theme.typography.control.copyWith(
                    color: colors.textPrimary,
                  ),
                ),
                if (secondary != null)
                  Text(
                    secondary,
                    style: theme.typography.helper.copyWith(
                      color: colors.textSecondary,
                    ),
                  ),
              ],
            ),
          ),
        ],
      ),
    );

    Widget target;
    if (interactive) {
      target = CarbonInteraction(
        onPressed: activate,
        focusNode: widget.focusNode,
        button: widget.onSelectedChanged == null,
        label: secondary == null ? widget.title : '${widget.title}\n$secondary',
        selected: selectable ? selected : null,
        excludeChildSemantics: true,
        builder: (context, state, _) => CarbonFocusRing(
          visible: state.focusVisible,
          child: ColoredBox(
            color: state.pressed ? theme.layerActive(level) : const Color(0x00000000),
            child: ConstrainedBox(
              constraints: BoxConstraints(minHeight: theme.minTarget),
              child: Align(
                alignment: AlignmentDirectional.centerStart,
                child: text,
              ),
            ),
          ),
        ),
      );
    } else {
      target = MergeSemantics(
        child: ConstrainedBox(
          constraints: BoxConstraints(minHeight: theme.minTarget),
          child: Align(
            alignment: AlignmentDirectional.centerStart,
            child: text,
          ),
        ),
      );
    }

    final showActions =
        !widget.revealActionsOnHover ||
        theme.isTouch ||
        _hovered ||
        _focusWithin;

    final row = DecoratedBox(
      decoration: BoxDecoration(
        color: fill,
        border: selected
            ? BorderDirectional(
                start: BorderSide(
                  color: colors.borderInteractive,
                  width: CarbonBorders.indicator,
                ),
              )
            : null,
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: <Widget>[
          Expanded(child: target),
          if (widget.actions.isNotEmpty)
            Visibility(
              visible: showActions,
              maintainState: true,
              maintainAnimation: true,
              maintainSize: true,
              maintainSemantics: true,
              maintainFocusability: true,
              child: Padding(
                padding: const EdgeInsetsDirectional.only(
                  end: CarbonSpacing.spacing03,
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: <Widget>[
                    for (var i = 0; i < widget.actions.length; i++) ...<Widget>[
                      if (i > 0) const SizedBox(width: CarbonSpacing.spacing02),
                      widget.actions[i],
                    ],
                  ],
                ),
              ),
            ),
        ],
      ),
    );

    return MouseRegion(
        onEnter: (_) => _setHover(true),
        onExit: (_) => _setHover(false),
        child: Focus(
          canRequestFocus: false,
          skipTraversal: true,
          onFocusChange: _setFocusWithin,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              row,
              Padding(
                padding: EdgeInsetsDirectional.only(
                  start: inset ? CarbonSpacing.spacing05 : 0,
                ),
                child: SizedBox(
                  height: CarbonBorders.hairline,
                  child: ColoredBox(color: theme.borderSubtle(level)),
                ),
              ),
            ],
          ),
        ),
    );
  }
}
