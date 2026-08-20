import 'dart:math' as math;
import 'dart:ui' show lerpDouble;

import 'package:flutter/widgets.dart';

import '../ab_tokens.dart';
import 'ab_icon.dart';

/// One cell of an [AbSwipeActions] tray.
class AbSwipeAction {
  const AbSwipeAction({
    required this.icon,
    required this.label,
    required this.color,
    required this.onInvoke,
    this.destructive = false,
  });

  final String icon;

  /// Painted beside the glyph, and the cell's accessible name. Always
  /// required: a revealed action the user cannot read is a guess.
  final String label;

  /// Tints the cell (16% fill) and colors its glyph and label.
  final Color color;

  final VoidCallback onInvoke;

  /// Excluded from the full-swipe shortcut. A gesture that runs to the end of
  /// the row is easy to produce by accident — the tray, and whatever
  /// confirmation the action itself raises, stay the only way to reach one.
  final bool destructive;
}

/// The single open tray, app-wide. Two open trays would mean two rows showing
/// actions with only one of them under the thumb; opening one closes the other,
/// the same rule every list with swipe actions follows.
final ValueNotifier<Object?> _openTray = ValueNotifier<Object?>(null);

/// Fraction of the tray that must be revealed for a release to open it rather
/// than snap back. Below it the gesture reads as a slip, not a reach.
const double _openFraction = 0.45;

/// The tray may never take more than this much of the row: what is left has to
/// keep saying which row the actions belong to. On a narrow pane the cells
/// shrink to honour it rather than the tray spilling across the whole row.
const double _maxTrayFraction = 0.5;

/// Fraction of the ROW a FINGER must travel for a release to run the first
/// action outright — measured on the raw drag, not the row's displacement,
/// which [_overshootResistance] deliberately holds back.
const double _fullSwipeFraction = 0.6;

/// …and never less than this multiple of the tray, so revealing the actions
/// can never by itself arm the shortcut. Without this floor a pane narrow
/// enough for the tray to approach [_fullSwipeFraction] of it turned every
/// open-the-tray swipe into "run the first action", which is precisely the
/// gesture that must not be guessable.
const double _fullSwipeTrayMultiple = 1.35;

/// Below this a cell shows its glyph alone: the label no longer fits without
/// being cut, and a half-word names an action worse than the icon does.
const double _labelFloor = 60;

/// A row that cannot separate the two gestures by at least this much of itself
/// gets no full-swipe shortcut at all — the tray still opens, and the action
/// is one tap away. Better no shortcut than a coin flip.
const double _fullSwipeHeadroom = 0.9;

/// Leftward velocity (px/s) that opens the tray regardless of distance — a
/// flick is as deliberate as a drag, and demanding both would punish a fast
/// user. Well above the speed a finger drifts at while scrolling.
const double _flingVelocity = 700;

/// Past the tray's own width the row keeps moving at this fraction of the
/// finger, so reaching the full-swipe threshold takes real travel rather than
/// momentum.
const double _overshootResistance = 0.5;

/// Wraps [child] in a row that reveals [actions] on a LEFTWARD swipe.
///
/// Leftward only, and that is not an oversight: a rightward swipe dismisses a
/// surface everywhere in this app (the mobile drawer, the agent page's back
/// fling, the touch tablet's sidebar), so a row may not claim it. Everything the
/// row offers therefore shares one direction, which is why this reveals a TRAY
/// of actions rather than binding one action per direction.
///
/// The interaction follows the platform convention on both phones: a partial
/// swipe reveals the tray and latches it open for a tap, and a swipe that runs
/// most of the row's width performs the FIRST action on release. Guards against
/// the accidental swipe, in the order they engage:
///
/// * The drag is a real gesture-arena competitor, so a mostly-vertical drag
///   goes to the enclosing scrollable and the row never moves.
/// * A release short of [_openFraction] of the tray snaps back and does
///   nothing, so a slip during a scroll costs nothing.
/// * The full-swipe threshold is measured on raw finger travel and floored
///   against the tray's own width ([_fullSwipeTrayMultiple]), so revealing the
///   actions can never itself arm the shortcut — and a row too narrow to keep
///   the two apart ([_fullSwipeHeadroom]) simply has no shortcut.
/// * A destructive action is never the full-swipe one (see
///   [AbSwipeAction.destructive]) — it can only be reached by tapping it in
///   the open tray.
/// * Only one tray is open at a time, an open tray absorbs the row's own tap
///   to close instead, and [closeAny] lets a host close it on scroll.
/// * While a tray is latched open it also owns the RIGHTWARD gesture, which is
///   how a tray is dismissed wherever this pattern exists.
class AbSwipeActions extends StatefulWidget {
  const AbSwipeActions({
    super.key,
    required this.actions,
    required this.child,
    this.enabled = true,
  });

  /// In priority order. The first is rendered at the trailing edge — the one
  /// the swipe reveals first, and the one a full swipe runs.
  final List<AbSwipeAction> actions;

  final Widget child;

  /// False renders [child] untouched, with no gesture attached at all.
  final bool enabled;

  /// Closes whichever tray is open. Hosts call this when the list scrolls: the
  /// row a tray belongs to slides away under the finger otherwise.
  static void closeAny() => _openTray.value = null;

  @override
  State<AbSwipeActions> createState() => _AbSwipeActionsState();
}

class _AbSwipeActionsState extends State<AbSwipeActions>
    with SingleTickerProviderStateMixin {
  /// Identity in [_openTray] — the state object itself would work, but a plain
  /// token cannot be mistaken for something to call back into.
  final Object _id = Object();

  /// Built in [initState], never lazily: a `late final` initializer would run
  /// for the first time inside [dispose] on a row that was never swiped, and
  /// creating a ticker there looks up a deactivated widget's ancestor.
  late final AnimationController _settle;

  /// Pixels the row is displaced to the left. Never negative: the row does not
  /// travel rightward past its resting place.
  double _offset = 0;
  double _settleFrom = 0;
  double _settleTo = 0;

  /// Raw leftward finger travel for the gesture in flight — what the
  /// full-swipe threshold is judged on, since [_offset] is deliberately held
  /// back past the tray and would never reach it.
  double _travel = 0;

  /// Latched open, as opposed to merely displaced mid-drag — the two differ
  /// while the tray is still animating into place, where [_offset] has not
  /// reached the tray yet.
  bool _latchedOpen = false;

  bool get _isOpen => _offset > 0;

  /// Cells shrink so the tray never takes more than [_maxTrayFraction] of the
  /// row — the git pane is a quarter of a tablet, and a fixed-width tray ate
  /// the filename there and collided with the full-swipe threshold.
  double _cellWidth(double rowWidth) => math.min(
    AbTokens.swipeActionWidth,
    rowWidth * _maxTrayFraction / widget.actions.length,
  );

  double _trayExtent(double rowWidth) =>
      _cellWidth(rowWidth) * widget.actions.length;

  /// Finger travel that arms the full-swipe shortcut, or null where the row is
  /// too narrow to hold it clear of the tray.
  double? _fullSwipeAt(double rowWidth) {
    if (widget.actions.first.destructive) return null;
    final at = math.max(
      rowWidth * _fullSwipeFraction,
      _trayExtent(rowWidth) * _fullSwipeTrayMultiple,
    );
    return at <= rowWidth * _fullSwipeHeadroom ? at : null;
  }

  @override
  void initState() {
    super.initState();
    _settle = AnimationController(vsync: this, duration: AbTokens.motionDefault)
      ..addListener(_onSettleTick);
    _openTray.addListener(_onOpenTrayChanged);
  }

  @override
  void dispose() {
    _openTray.removeListener(_onOpenTrayChanged);
    // A row torn down mid-gesture (its file staged out of the changed list, the
    // pane closed under it) never gets the pointer-up that would release these.
    if (_openTray.value == _id) _openTray.value = null;
    _setLatchedOpen(false);
    _settle.dispose();
    super.dispose();
  }

  /// [build] returns the bare child the moment a row has nothing left to swipe
  /// to, which takes the tray's own close gestures with it — so a tray still
  /// latched at that moment could never be closed again, and [closeAny] would
  /// go on answering for a row that is no longer on screen. The row's actions
  /// CAN empty under an open tray: a file turning conflicted drops
  /// stage/unstage/discard while its [ValueKey] keeps this State alive.
  @override
  void didUpdateWidget(AbSwipeActions oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.enabled && widget.actions.isNotEmpty) return;
    if (!_isOpen && !_latchedOpen) return;
    if (_openTray.value == _id) _openTray.value = null;
    _setLatchedOpen(false);
    // Snapped, not animated: there is nothing on screen to animate — this
    // build paints [widget.child] alone.
    _settle.stop();
    _offset = 0;
    _travel = 0;
  }

  void _setLatchedOpen(bool open) {
    if (_latchedOpen == open) return;
    _latchedOpen = open;
  }

  void _onSettleTick() {
    final t = Curves.easeOutCubic.transform(_settle.value);
    setState(() => _offset = lerpDouble(_settleFrom, _settleTo, t)!);
  }

  void _onOpenTrayChanged() {
    if (_openTray.value == _id) return;
    // Same path a local close takes: the latch — and with it the host's
    // arbitration — has to drop here too, not just the displacement.
    if (_isOpen || _latchedOpen) {
      _setLatchedOpen(false);
      _animateTo(0);
    }
  }

  void _animateTo(double target) {
    _settleFrom = _offset;
    _settleTo = target;
    if (MediaQuery.disableAnimationsOf(context)) {
      _settle.stop();
      setState(() => _offset = target);
      return;
    }
    _settle.forward(from: 0);
  }

  void _close() {
    if (_openTray.value == _id) _openTray.value = null;
    _setLatchedOpen(false);
    _animateTo(0);
  }

  void _open(double rowWidth) {
    _openTray.value = _id;
    _setLatchedOpen(true);
    _animateTo(_trayExtent(rowWidth));
  }

  void _invoke(AbSwipeAction action) {
    _close();
    action.onInvoke();
  }

  void _onDragStart(DragStartDetails _) {
    _settle.stop();
    _travel = _offset;
    // Another row's tray is a stale affordance the moment this row is grabbed.
    if (_openTray.value != _id) _openTray.value = null;
  }

  void _onDragUpdate(DragUpdateDetails details, double rowWidth) {
    final delta = -details.primaryDelta!;
    final tray = _trayExtent(rowWidth);
    final next = _offset > tray && delta > 0
        ? _offset + delta * _overshootResistance
        : _offset + delta;
    setState(() {
      _travel = (_travel + delta).clamp(0.0, rowWidth);
      _offset = next.clamp(0.0, rowWidth);
    });
  }

  void _onDragEnd(DragEndDetails details, double rowWidth) {
    final velocity = -(details.primaryVelocity ?? 0);
    final fullSwipeAt = _fullSwipeAt(rowWidth);
    if (fullSwipeAt != null && _travel >= fullSwipeAt) {
      _invoke(widget.actions.first);
      return;
    }
    if (_offset >= _trayExtent(rowWidth) * _openFraction ||
        velocity >= _flingVelocity) {
      _open(rowWidth);
      return;
    }
    _close();
  }

  @override
  Widget build(BuildContext context) {
    if (!widget.enabled || widget.actions.isEmpty) return widget.child;

    return LayoutBuilder(
      builder: (context, constraints) {
        final rowWidth = constraints.maxWidth;
        final cellWidth = _cellWidth(rowWidth);
        final fullSwipeAt = _fullSwipeAt(rowWidth);
        // Armed, so the tray collapses into that one cell — the row has to say
        // which of the two things it is about to do before the finger lifts,
        // not after.
        final fullSwipeArmed = fullSwipeAt != null && _travel >= fullSwipeAt;

        return GestureDetector(
          onHorizontalDragStart: _onDragStart,
          onHorizontalDragUpdate: (d) => _onDragUpdate(d, rowWidth),
          onHorizontalDragEnd: (d) => _onDragEnd(d, rowWidth),
          onHorizontalDragCancel: _close,
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
                      maxWidth: fullSwipeArmed
                          ? _offset
                          : _trayExtent(rowWidth),
                      child: Row(
                        children: [
                          for (final action
                              in fullSwipeArmed
                                  ? [widget.actions.first]
                                  : widget.actions.reversed)
                            _SwipeCell(
                              action: action,
                              width: fullSwipeArmed ? _offset : cellWidth,
                              onTap: () => _invoke(action),
                            ),
                        ],
                      ),
                    ),
                  ),
                ),
              Transform.translate(
                offset: Offset(-_offset, 0),
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
            ],
          ),
        );
      },
    );
  }
}

class _SwipeCell extends StatelessWidget {
  const _SwipeCell({
    required this.action,
    required this.width,
    required this.onTap,
  });

  final AbSwipeAction action;
  final double width;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    // A cell squeezed by a narrow pane drops to the glyph alone rather than
    // painting a word cut in half — the tooltip-less equivalent of an
    // ellipsised label is no label at all. Semantics keeps the name either way.
    final showLabel = width >= _labelFloor;
    return Semantics(
      button: true,
      label: action.label,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: onTap,
        child: Container(
          width: width,
          color: action.color.withValues(alpha: 0.16),
          alignment: Alignment.center,
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              AbIcon(
                action.icon,
                size: AbTokens.iconButtonGlyph,
                color: action.color,
              ),
              if (showLabel) ...[
                const SizedBox(width: AbTokens.space6),
                Flexible(
                  child: Text(
                    action.label,
                    overflow: TextOverflow.ellipsis,
                    style: AbTokens.sansStyle(
                      fontSize: AbTokens.fontXs,
                      fontWeight: FontWeight.w600,
                      color: action.color,
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
