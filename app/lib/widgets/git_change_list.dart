import 'dart:math' as math;
import 'dart:ui' show lerpDouble;

import 'package:carbon_flutter/carbon_flutter.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart'
    show RefreshIndicator, RefreshIndicatorStatus;
import 'package:flutter/widgets.dart';

import '../models/ab_message.dart' show GitFileStatusEntry;
import '../models/git_status_index.dart';
import '../util/detached.dart';
import 'carbon_diff_stat.dart';
import 'carbon_status_dot.dart';
import 'copy_path.dart';
import 'git_status_color.dart';

/// One changed path, split once rather than on every row build.
typedef _ChangeRow = ({String path, String name, String? folder});

/// Conflicts sort to the FRONT, so a top-down read reaches every one first.
/// The rest go case-insensitively by path, which keeps a folder's files
/// together now that no folder row groups them.
///
/// Each row's path is the change path VERBATIM: a row looks its entries up by
/// that string and every action hands it straight back to git, and git's own
/// `dir/` for an untracked directory it did not walk into would not survive
/// being rebuilt from segments.
List<_ChangeRow> _flattenChanges(
  Map<String, List<GitFileStatusEntry>> entriesByPath,
) {
  final conflicted = {
    for (final MapEntry(:key, :value) in entriesByPath.entries)
      if (value.any((e) => e.status == '!')) key,
  };
  final paths = entriesByPath.keys.toList()
    ..sort((a, b) {
      final byConflict =
          (conflicted.contains(a) ? 0 : 1) - (conflicted.contains(b) ? 0 : 1);
      if (byConflict != 0) return byConflict;
      final byName = a.toLowerCase().compareTo(b.toLowerCase());
      // Case-only twins: lowercase first, as the Files tab orders them, and
      // never arrival order — the sort is not stable.
      return byName != 0 ? byName : b.compareTo(a);
    });
  return [
    for (final path in paths)
      // Empty segments dropped: a leading slash, and the trailing one git puts
      // on an untracked directory it did not walk into.
      if (path.split('/').where((s) => s.isNotEmpty).toList() case [
        ...final dirs,
        final name,
      ])
        (
          path: path,
          name: name,
          folder: dirs.isEmpty ? null : dirs.join('/'),
        ),
  ];
}

/// Closes whichever row's swipe tray is open. The panel calls this when the
/// list scrolls: the row a tray belongs to slides away under the finger
/// otherwise.
void closeOpenGitSwipeTray() => _openTray.value = null;

/// A hairline between the panel's sections.
class GitSectionDivider extends StatelessWidget {
  const GitSectionDivider({super.key});

  @override
  Widget build(BuildContext context) {
    final theme = CarbonTheme.of(context);
    return SizedBox(
      height: CarbonBorders.hairline,
      child: ColoredBox(color: theme.borderSubtle(CarbonLayer.of(context))),
    );
  }
}

/// The header of a foldable section: a chevron, the name, an optional count
/// tag, then the section's bulk actions as ghost icon buttons on the right.
///
/// A null [onToggle] is a header that cannot fold: no chevron, and the name is
/// plain text.
class GitSectionHeader extends StatelessWidget {
  const GitSectionHeader({
    super.key,
    required this.label,
    required this.expanded,
    this.onToggle,
    this.count,
    this.actions = const <Widget>[],
  });

  final String label;
  final bool expanded;
  final VoidCallback? onToggle;

  /// Rendered verbatim, so a paginated list can say `50+`.
  final String? count;
  final List<Widget> actions;

  @override
  Widget build(BuildContext context) {
    final theme = CarbonTheme.of(context);
    final colors = theme.colors;
    final count = this.count;
    final title = Flexible(
      child: Text(
        label,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: theme.typography.control.copyWith(
          color: colors.textPrimary,
          fontWeight: FontWeight.w600,
        ),
      ),
    );
    final tag = count == null
        ? null
        : Padding(
            padding: const EdgeInsets.only(left: CarbonSpacing.spacing03),
            child: CarbonTag(label: count, size: CarbonTagSize.small),
          );
    final Widget toggle;
    if (onToggle == null) {
      toggle = ConstrainedBox(
        constraints: BoxConstraints(minHeight: theme.minTarget),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: CarbonSpacing.spacing05),
          child: Row(children: [title, ?tag]),
        ),
      );
    } else {
      toggle = CarbonInteraction(
        onPressed: onToggle,
        button: true,
        label: label,
        excludeChildSemantics: true,
        builder: (context, state, _) => CarbonFocusRing(
          visible: state.focusVisible,
          child: ColoredBox(
            color: state.pressed
                ? theme.layerActive(CarbonLayer.of(context))
                : state.hovered
                ? theme.layerHover(CarbonLayer.of(context))
                : colors.background.withValues(alpha: 0),
            child: ConstrainedBox(
              constraints: BoxConstraints(minHeight: theme.minTarget),
              child: Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: CarbonSpacing.spacing05,
                ),
                child: Row(
                  children: [
                    CarbonIcon(
                      expanded
                          ? CarbonIcons.chevronDown
                          : CarbonIcons.chevronRight,
                      color: colors.iconSecondary,
                    ),
                    const SizedBox(width: CarbonSpacing.spacing03),
                    title,
                    ?tag,
                  ],
                ),
              ),
            ),
          ),
        ),
      );
    }
    return Semantics(
      expanded: onToggle == null ? null : expanded,
      container: true,
      child: Row(
        children: [
          Expanded(child: toggle),
          for (final action in actions) action,
          if (actions.isNotEmpty)
            const SizedBox(width: CarbonSpacing.spacing02),
        ],
      ),
    );
  }
}

/// A ghost icon button for a section header or row.
class GitIconAction extends StatelessWidget {
  const GitIconAction({
    super.key,
    required this.icon,
    required this.label,
    required this.onPressed,
  });

  final CarbonIcons icon;
  final String label;
  final VoidCallback? onPressed;

  @override
  Widget build(BuildContext context) {
    return CarbonButton.iconOnly(
      icon: CarbonIcon(icon),
      semanticLabel: label,
      onPressed: onPressed,
      size: CarbonButtonSize.small,
    );
  }
}

/// The rows of one change group (Staged Changes or Changes) as a headless
/// contained list, so the panel's own header sits above it and the whole
/// column scrolls as one sliver list.
class GitChangeGroupSliver extends StatelessWidget {
  const GitChangeGroupSliver({
    super.key,
    required this.index,
    required this.selectedPath,
    required this.onOpen,
    required this.onStage,
    required this.onUnstage,
    required this.onDiscard,
    required this.onResolve,
  });

  /// This group's half of the status — see [GitStatusIndex.staged].
  final GitStatusIndex index;
  final String? selectedPath;
  final ValueChanged<String> onOpen;
  final ValueChanged<String> onStage;
  final ValueChanged<String> onUnstage;
  final ValueChanged<String> onDiscard;
  final ValueChanged<String> onResolve;

  @override
  Widget build(BuildContext context) {
    final rows = _flattenChanges(index.byPath);
    return CarbonContainedListSliver(
      label: null,
      variant: CarbonContainedListVariant.disclosed,
      itemCount: rows.length,
      itemBuilder: (context, i) {
        final row = rows[i];
        return _GitChangeRow(
          key: ValueKey(row.path),
          path: row.path,
          name: row.name,
          folder: row.folder,
          entries: index.byPath[row.path] ?? const [],
          selected: row.path == selectedPath,
          onOpen: onOpen,
          onStage: onStage,
          onUnstage: onUnstage,
          onDiscard: onDiscard,
          onResolve: onResolve,
        );
      },
    );
  }
}

class _GitChangeRow extends StatelessWidget {
  const _GitChangeRow({
    super.key,
    required this.path,
    required this.name,
    required this.folder,
    required this.entries,
    required this.selected,
    required this.onOpen,
    required this.onStage,
    required this.onUnstage,
    required this.onDiscard,
    required this.onResolve,
  });

  final String path;
  final String name;
  final String? folder;
  final List<GitFileStatusEntry> entries;
  final bool selected;
  final ValueChanged<String> onOpen;
  final ValueChanged<String> onStage;
  final ValueChanged<String> onUnstage;
  final ValueChanged<String> onDiscard;
  final ValueChanged<String> onResolve;

  Widget _trailing(CarbonThemeData theme, GitFileStatusEntry entry) {
    final colors = theme.colors;
    if (entry.status == '!') {
      return CarbonStatusDot(
        color: colors.supportError,
        size: theme.iconSize / 2,
      );
    }
    if (entry.additions == 0 && entry.deletions == 0) {
      // A pure rename or a mode-only change: nothing to count in lines.
      return CarbonStatusDot(
        color: colors.supportWarning,
        size: theme.iconSize / 2,
      );
    }
    return CarbonDiffStat(
      additions: entry.additions,
      deletions: entry.deletions,
      size: theme.isTouch
          ? CarbonDiffStatSize.medium
          : CarbonDiffStatSize.small,
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = CarbonTheme.of(context);
    final colors = theme.colors;
    final type = theme.typography;
    final touch = theme.isTouch;
    final isConflict = entries.any((e) => e.status == '!');
    final isStaged = entries.any((e) => e.staged);
    final isUnstaged = entries.any((e) => !e.staged);

    // A conflict has nothing safe to stage/unstage/discard — resolving it
    // isn't a "restore to HEAD".
    final onStagePath = (isUnstaged && !isConflict)
        ? () => onStage(path)
        : null;
    final onUnstagePath = isStaged ? () => onUnstage(path) : null;
    // Offered on a STAGED-only row too: Discard means "back to HEAD", and a
    // file whose only change sits in the index is exactly the case where
    // making the user unstage first buys nothing.
    final onDiscardPath = ((isUnstaged || isStaged) && !isConflict)
        ? () => onDiscard(path)
        : null;
    // The only action a conflicted row offers, and the only path out of the
    // state: without it the panel can show a conflict but never clear one.
    final onResolvePath = isConflict ? () => onResolve(path) : null;

    final entry = entries.isEmpty ? null : entries.first;
    final status = entry?.status ?? '';
    final nameStyle = type.code.copyWith(
      color: colors.textPrimary,
      decoration: status == 'D' ? TextDecoration.lineThrough : null,
    );
    final title = Text.rich(
      TextSpan(
        text: name,
        style: nameStyle,
        children: [
          if (folder != null)
            TextSpan(
              text: '  $folder',
              style: type.code.copyWith(color: colors.textSecondary),
            ),
        ],
      ),
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
    );
    // Touch has no hover, and its long-press already opens the menu.
    final content = touch ? title : CarbonTooltip(message: path, child: title);

    // Touch rows carry no action buttons at all: the swipe tray is the whole
    // affordance there, and a row of always-visible targets (there is no hover
    // to hide them behind) would crowd out the diff stat the row exists to
    // show on the narrowest pane in the app.
    final actions = touch
        ? const <Widget>[]
        : [
            if (onResolvePath != null)
              GitIconAction(
                icon: CarbonIcons.checkmark,
                label: 'Mark Resolved',
                onPressed: onResolvePath,
              ),
            if (onStagePath != null)
              GitIconAction(
                icon: CarbonIcons.add,
                label: 'Stage Changes',
                onPressed: onStagePath,
              ),
            if (onUnstagePath != null)
              GitIconAction(
                icon: CarbonIcons.subtract,
                label: 'Unstage Changes',
                onPressed: onUnstagePath,
              ),
            if (onDiscardPath != null)
              GitIconAction(
                icon: CarbonIcons.undo,
                label: 'Discard Changes',
                onPressed: onDiscardPath,
              ),
          ];

    Widget row = CarbonContainedListRow(
      title: name,
      selected: selected,
      revealActionsOnHover: true,
      onPressed: () {
        closeOpenGitSwipeTray();
        onOpen(path);
      },
      leading: SizedBox(
        width: theme.iconSize,
        child: Text(
          status,
          textAlign: TextAlign.center,
          style: type.code.copyWith(
            color: gitStatusColor(colors, status),
            fontWeight: FontWeight.w600,
          ),
        ),
      ),
      content: content,
      actions: actions,
      // In the row's trailing slot, not the content: hidden hover actions
      // keep their width, so a mark in the content would sit further in on
      // every row offering more actions.
      trailing: entry == null ? null : _trailing(theme, entry),
    );

    if (touch) {
      final stageAction = onStagePath ?? onUnstagePath;
      row = _SwipeTray(
        actions: [
          // First is the trailing-edge cell and the full-swipe action — the
          // reversible one, never Discard. A conflicted row has only Resolve to
          // put there, and it is NOT reversible from this app: `git reset` on a
          // resolved path leaves a plain " M", it does not restore the unmerged
          // index stages. That is why it confirms before firing.
          if (onResolvePath != null)
            _TrayAction(
              icon: CarbonIcons.checkmark,
              label: 'Resolve',
              color: colors.buttonPrimary,
              onInvoke: onResolvePath,
            ),
          if (stageAction != null)
            _TrayAction(
              icon: onStagePath != null ? CarbonIcons.add : CarbonIcons.subtract,
              label: onStagePath != null ? 'Stage' : 'Unstage',
              color: colors.buttonPrimary,
              onInvoke: stageAction,
            ),
          if (onDiscardPath != null)
            _TrayAction(
              icon: CarbonIcons.undo,
              label: 'Discard',
              color: colors.supportError,
              onInvoke: onDiscardPath,
              destructive: true,
            ),
        ],
        child: row,
      );
    }

    return CarbonContextMenu(
      entries: [
        if (onResolvePath != null)
          CarbonMenuItem(
            label: 'Mark Resolved',
            icon: const CarbonIcon(CarbonIcons.checkmark),
            onPressed: onResolvePath,
          ),
        if (onStagePath != null)
          CarbonMenuItem(
            label: 'Stage Changes',
            icon: const CarbonIcon(CarbonIcons.add),
            onPressed: onStagePath,
          ),
        if (onUnstagePath != null)
          CarbonMenuItem(
            label: 'Unstage Changes',
            icon: const CarbonIcon(CarbonIcons.subtract),
            onPressed: onUnstagePath,
          ),
        if (onDiscardPath != null)
          CarbonMenuItem(
            label: 'Discard Changes',
            icon: const CarbonIcon(CarbonIcons.undo),
            kind: CarbonMenuItemKind.danger,
            onPressed: onDiscardPath,
          ),
        if (onResolvePath != null ||
            onStagePath != null ||
            onUnstagePath != null ||
            onDiscardPath != null)
          const CarbonMenuDivider(),
        CarbonMenuItem(
          label: 'Copy path',
          icon: const CarbonIcon(CarbonIcons.copy),
          // The path is project-relative — what an agent prompt or a terminal
          // in the checkout wants, and the one form a remote project can
          // answer too. A void callback discards the future it starts.
          onPressed: () => detached('GitChangeRow', 'copy path failed', () async {
            if (!context.mounted) return;
            await copyPathWithToast(context, path);
          }),
        ),
      ],
      child: row,
    );
  }
}

/// A pull-to-refresh whose indicator is a Carbon spinner. The gesture and
/// refresh bookkeeping stay [RefreshIndicator]'s; only its painted spinner is
/// replaced.
class CarbonPullToRefresh extends StatefulWidget {
  const CarbonPullToRefresh({
    super.key,
    required this.onRefresh,
    required this.child,
  });

  final Future<void> Function() onRefresh;
  final Widget child;

  @override
  State<CarbonPullToRefresh> createState() => _CarbonPullToRefreshState();
}

class _CarbonPullToRefreshState extends State<CarbonPullToRefresh> {
  RefreshIndicatorStatus? _status;

  bool get _showing =>
      _status == RefreshIndicatorStatus.armed ||
      _status == RefreshIndicatorStatus.snap ||
      _status == RefreshIndicatorStatus.refresh;

  @override
  Widget build(BuildContext context) {
    return Stack(
      children: [
        RefreshIndicator.noSpinner(
          onRefresh: widget.onRefresh,
          onStatusChange: (status) {
            if (mounted) setState(() => _status = status);
          },
          child: widget.child,
        ),
        if (_showing)
          Positioned(
            top: CarbonSpacing.spacing04,
            left: 0,
            right: 0,
            child: IgnorePointer(
              child: Center(
                child: CarbonSpinner(semanticLabel: 'Refreshing'),
              ),
            ),
          ),
      ],
    );
  }
}

/// One cell of the swipe tray.
class _TrayAction {
  const _TrayAction({
    required this.icon,
    required this.label,
    required this.color,
    required this.onInvoke,
    this.destructive = false,
  });

  final CarbonIcons icon;

  /// Painted beside the glyph, and the cell's accessible name. Always
  /// required: a revealed action the user cannot read is a guess.
  final String label;
  final Color color;
  final VoidCallback onInvoke;

  /// Excluded from the full-swipe shortcut. A gesture that runs to the end of
  /// the row is easy to produce by accident — the tray, and whatever
  /// confirmation the action itself raises, stay the only way to reach one.
  final bool destructive;
}

/// The single open tray, app-wide. Two open trays would mean two rows showing
/// actions with only one of them under the thumb.
final ValueNotifier<Object?> _openTray = ValueNotifier<Object?>(null);

/// Fraction of the tray that must be revealed for a release to open it rather
/// than snap back; below it the gesture reads as a slip, not a reach.
const double _openFraction = 0.3;

/// The tray may never take more than this much of the row: what is left has to
/// keep saying which row the actions belong to.
const double _maxTrayFraction = 0.5;

/// Fraction of the ROW a finger must travel for a release to run the first
/// action outright — measured on the raw drag, not the row's displacement,
/// which [_overshootResistance] deliberately holds back.
const double _fullSwipeFraction = 0.6;

/// …and never less than this multiple of the tray, so revealing the actions
/// can never by itself arm the shortcut.
const double _fullSwipeTrayMultiple = 1.35;

/// A row that cannot separate the two gestures by at least this much of itself
/// gets no full-swipe shortcut at all.
const double _fullSwipeHeadroom = 0.9;

/// Leftward velocity (px/s) that opens the tray regardless of distance.
const double _flingVelocity = 700;

/// Past the tray's own width the row keeps moving at this fraction of the
/// finger, so reaching the full-swipe threshold takes real travel.
const double _overshootResistance = 0.5;

/// Reveals [actions] on a LEFTWARD swipe, and only leftward: a rightward swipe
/// dismisses a surface everywhere in this app (the mobile drawer, the agent
/// page's back fling), so a row may not claim it.
///
/// A partial swipe latches the tray open for a tap; a swipe that runs most of
/// the row performs the first action. A release short of [_openFraction]
/// snaps back, a destructive first action never gets the full-swipe shortcut,
/// and an open tray owns the rightward gesture so it can be dismissed.
class _SwipeTray extends StatefulWidget {
  const _SwipeTray({required this.actions, required this.child});

  /// In priority order. The first is rendered at the trailing edge.
  final List<_TrayAction> actions;
  final Widget child;

  @override
  State<_SwipeTray> createState() => _SwipeTrayState();
}

class _SwipeTrayState extends State<_SwipeTray>
    with SingleTickerProviderStateMixin {
  final Object _id = Object();

  // Built in initState, never lazily: a `late final` initializer would run for
  // the first time inside dispose() on a row that was never swiped.
  late final AnimationController _settle;

  /// Pixels the row is displaced to the left; never negative.
  double _offset = 0;
  double _settleFrom = 0;
  double _settleTo = 0;

  /// Raw leftward finger travel for the gesture in flight, which the
  /// full-swipe threshold is judged on since [_offset] is held back past the
  /// tray.
  double _travel = 0;

  bool get _isOpen => _offset > 0;

  double _cellWidth(double rowWidth, double nominal) => math.min(
    nominal,
    rowWidth * _maxTrayFraction / widget.actions.length,
  );

  double _trayExtent(double rowWidth, double nominal) =>
      _cellWidth(rowWidth, nominal) * widget.actions.length;

  /// Finger travel that arms the full-swipe shortcut, or null where the row is
  /// too narrow to hold it clear of the tray.
  double? _fullSwipeAt(double rowWidth, double nominal) {
    if (widget.actions.first.destructive) return null;
    final at = math.max(
      rowWidth * _fullSwipeFraction,
      _trayExtent(rowWidth, nominal) * _fullSwipeTrayMultiple,
    );
    return at <= rowWidth * _fullSwipeHeadroom ? at : null;
  }

  @override
  void initState() {
    super.initState();
    _settle = AnimationController(
      vsync: this,
      duration: CarbonMotion.moderate01,
    )..addListener(_onSettleTick);
    _openTray.addListener(_onOpenTrayChanged);
  }

  @override
  void dispose() {
    _openTray.removeListener(_onOpenTrayChanged);
    // A row torn down mid-gesture never gets the pointer-up that would release
    // these.
    if (_openTray.value == _id) _openTray.value = null;
    _settle.dispose();
    super.dispose();
  }

  // The row's actions can empty under an open tray (a file turning conflicted
  // drops stage/unstage/discard while its key keeps this State alive); the bare
  // child then has no gesture to close it.
  @override
  void didUpdateWidget(_SwipeTray oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.actions.isNotEmpty || !_isOpen) return;
    if (_openTray.value == _id) _openTray.value = null;
    _settle.stop();
    _offset = 0;
    _travel = 0;
  }

  void _onSettleTick() {
    final t = Curves.easeOutCubic.transform(_settle.value);
    setState(() => _offset = lerpDouble(_settleFrom, _settleTo, t)!);
  }

  void _onOpenTrayChanged() {
    if (_openTray.value == _id) return;
    if (_isOpen) _animateTo(0);
  }

  void _animateTo(double target) {
    _settleFrom = _offset;
    _settleTo = target;
    if (CarbonMotion.reduced(context)) {
      _settle.stop();
      setState(() => _offset = target);
      return;
    }
    _settle.forward(from: 0);
  }

  void _close() {
    if (_openTray.value == _id) _openTray.value = null;
    _animateTo(0);
  }

  void _open(double extent) {
    _openTray.value = _id;
    _animateTo(extent);
  }

  void _invoke(_TrayAction action) {
    _close();
    action.onInvoke();
  }

  void _onDragStart(DragStartDetails _) {
    _settle.stop();
    _travel = _offset;
    // Another row's tray is a stale affordance the moment this row is grabbed.
    if (_openTray.value != _id) _openTray.value = null;
  }

  void _onDragUpdate(DragUpdateDetails details, double rowWidth, double cell) {
    final delta = -details.primaryDelta!;
    final tray = _trayExtent(rowWidth, cell);
    final next = _offset > tray && delta > 0
        ? _offset + delta * _overshootResistance
        : _offset + delta;
    setState(() {
      _travel = (_travel + delta).clamp(0.0, rowWidth);
      _offset = next.clamp(0.0, rowWidth);
    });
  }

  void _onDragEnd(DragEndDetails details, double rowWidth, double cell) {
    final velocity = -(details.primaryVelocity ?? 0);
    final fullSwipeAt = _fullSwipeAt(rowWidth, cell);
    if (fullSwipeAt != null && _travel >= fullSwipeAt) {
      _invoke(widget.actions.first);
      return;
    }
    final extent = _trayExtent(rowWidth, cell);
    if (_offset >= extent * _openFraction || velocity >= _flingVelocity) {
      _open(extent);
      return;
    }
    _close();
  }

  @override
  Widget build(BuildContext context) {
    if (widget.actions.isEmpty) return widget.child;
    final theme = CarbonTheme.of(context);
    final nominal = theme.minTarget * 2;

    return LayoutBuilder(
      builder: (context, constraints) {
        final rowWidth = constraints.maxWidth;
        final cellWidth = _cellWidth(rowWidth, nominal);
        final extent = _trayExtent(rowWidth, nominal);
        final fullSwipeAt = _fullSwipeAt(rowWidth, nominal);
        // Armed, so the tray collapses into that one cell: the row has to say
        // which of the two things it is about to do before the finger lifts.
        final fullSwipeArmed = fullSwipeAt != null && _travel >= fullSwipeAt;

        return RawGestureDetector(
          gestures: {
            _LeftwardDragRecognizer:
                GestureRecognizerFactoryWithHandlers<_LeftwardDragRecognizer>(
                  _LeftwardDragRecognizer.new,
                  (r) => r
                    // The device's slop, as GestureDetector and the PageView's
                    // Scrollable both read it. Without it this row waits out
                    // the framework's 18px default while the page accepts at
                    // the device's, so every leftward swipe became a page drag.
                    ..gestureSettings = MediaQuery.maybeGestureSettingsOf(
                      context,
                    )
                    // From the touch, not from where the slop was crossed, so
                    // the row follows the whole of the finger's travel.
                    ..dragStartBehavior = DragStartBehavior.down
                    ..claimsRightward = (() => _isOpen)
                    ..onStart = _onDragStart
                    ..onUpdate = ((d) => _onDragUpdate(d, rowWidth, nominal))
                    ..onEnd = ((d) => _onDragEnd(d, rowWidth, nominal))
                    ..onCancel = _close,
                ),
          },
          child: Stack(
            children: [
              if (_offset > 0)
                Positioned(
                  top: 0,
                  bottom: 0,
                  right: 0,
                  width: _offset,
                  child: ClipRect(
                    child: OverflowBox(
                      alignment: Alignment.centerRight,
                      minWidth: 0,
                      maxWidth: fullSwipeArmed ? _offset : extent,
                      child: Row(
                        children: [
                          for (final action
                              in fullSwipeArmed
                                  ? [widget.actions.first]
                                  : widget.actions.reversed)
                            _TrayCell(
                              action: action,
                              width: fullSwipeArmed ? _offset : cellWidth,
                              onTap: () => _invoke(action),
                            ),
                        ],
                      ),
                    ),
                  ),
                ),
              // The tray narrows the row rather than pushing it: a row's name
              // leads it, so sliding the row by a tray that may take half its
              // width pushed the name off screen and left the actions saying
              // nothing about which file they act on. Only past the tray, where
              // a full swipe is committing, does the row itself travel.
              Transform.translate(
                offset: Offset(-math.max(0.0, _offset - extent), 0),
                child: Padding(
                  padding: EdgeInsets.only(right: math.min(_offset, extent)),
                  child: Stack(
                    children: [
                      widget.child,
                      // An open tray takes the row's own tap: the first tap
                      // after a swipe means "never mind", not "open this file".
                      if (_isOpen)
                        Positioned.fill(
                          child: GestureDetector(
                            behavior: HitTestBehavior.opaque,
                            onTap: _close,
                          ),
                        ),
                    ],
                  ),
                ),
              ),
            ],
          ),
        );
      },
    );
  }
}

/// A horizontal drag that walks away from a RIGHTWARD start instead of winning
/// it. A plain drag recognizer claims both directions, so a rightward swipe
/// that began on a row was swallowed by a tray that can only open leftward, and
/// the pane swipe that should have taken it never saw it.
class _LeftwardDragRecognizer extends HorizontalDragGestureRecognizer {
  /// Whether a rightward drag is this row's: true only while its tray is open,
  /// where rightward is how the tray is dismissed.
  bool Function() claimsRightward = () => false;

  final Map<int, double> _downX = {};

  @override
  void addAllowedPointer(PointerDownEvent event) {
    _downX[event.pointer] = event.position.dx;
    super.addAllowedPointer(event);
  }

  @override
  void handleEvent(PointerEvent event) {
    if (event is PointerMoveEvent && !claimsRightward()) {
      final startX = _downX[event.pointer];
      // Under the touch slop, so the row gives way before it could ever accept.
      final giveWayAt = computeHitSlop(event.kind, gestureSettings) / 2;
      if (startX != null && event.position.dx - startX > giveWayAt) {
        _downX.remove(event.pointer);
        resolvePointer(event.pointer, GestureDisposition.rejected);
        return;
      }
    }
    super.handleEvent(event);
  }

  @override
  void didStopTrackingLastPointer(int pointer) {
    _downX.clear();
    super.didStopTrackingLastPointer(pointer);
  }
}

class _TrayCell extends StatelessWidget {
  const _TrayCell({
    required this.action,
    required this.width,
    required this.onTap,
  });

  final _TrayAction action;
  final double width;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = CarbonTheme.of(context);
    final colors = theme.colors;
    // A cell squeezed by a narrow pane drops to the glyph alone rather than
    // painting a word cut in half. Semantics keeps the name either way.
    final showLabel = width >= theme.minTarget * 1.5;
    return Semantics(
      button: true,
      label: action.label,
      excludeSemantics: true,
      onTap: onTap,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: onTap,
        child: Container(
          width: width,
          color: action.color,
          alignment: Alignment.center,
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              CarbonIcon(action.icon, color: colors.textOnColor),
              if (showLabel) ...[
                const SizedBox(width: CarbonSpacing.spacing02),
                Flexible(
                  child: Text(
                    action.label,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: theme.typography.label.copyWith(
                      color: colors.textOnColor,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}
