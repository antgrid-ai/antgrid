import 'dart:async';

import 'package:flutter/material.dart';

import '../ab_colors.dart';
import '../ab_icons.dart';
import '../ab_tokens.dart';
import '../widgets/ab_cross_fade.dart';
import '../widgets/ab_icon.dart';
import '../widgets/ab_icon_button.dart';
import '../../utils/platform_utils.dart';

class AbToast extends StatelessWidget {
  const AbToast({
    super.key,
    required this.icon,
    required this.title,
    this.description,
    this.iconColor,
    this.actionLabel,
    this.onAction,
    this.onTap,
    this.onClose,
    this.hovered = false,
  });

  final String icon;
  final String title;
  final String? description;

  /// Overrides the icon dot color. Defaults to [AbColors.statusRunning].
  final Color? iconColor;
  final String? actionLabel;
  final VoidCallback? onAction;

  /// Makes the whole card the target, for a toast whose only sensible action
  /// is "go there" — a chip would just be a smaller copy of the card.
  final VoidCallback? onTap;

  /// Renders a trailing dismiss button when given; the stack wires one into
  /// every toast it shows.
  final VoidCallback? onClose;

  /// Reveals the close button. Tracked by the stack's card, which already
  /// watches the pointer to hold the auto-dismiss timer.
  final bool hovered;

  @override
  Widget build(BuildContext context) {
    final p = context.antgrid;
    final hasAction = actionLabel != null;
    // The close button is a HOVER affordance, and hover only exists with a
    // mouse — touch has no equivalent event, and a toast there is dismissed
    // by swiping it away instead (see _DismissingToast's drag handling), so a
    // touch card never reserves layout space for a button it can't reveal.
    final hasClose = onClose != null && !isMobilePlatform;
    final hasDescription = description != null && description!.isNotEmpty;
    final textColumn = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(
          title,
          // The title carries an unbounded program-chosen string for a plain
          // [showAbToast] call (a URL, an exception's toString()) — capped so
          // one long message can't grow the card past the host's width cap
          // (see _ToastStackView's ConstrainedBox) into an unreadable wall.
          maxLines: 3,
          overflow: TextOverflow.ellipsis,
          style: TextStyle(
            fontSize: AbTokens.fontMd,
            fontWeight: FontWeight.w500,
            color: p.textPrimary,
          ),
        ),
        if (hasDescription) ...[
          const SizedBox(height: 1),
          Text(
            description!,
            maxLines: 3,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(fontSize: AbTokens.fontXs, color: p.textMuted),
          ),
        ],
      ],
    );
    final card = Container(
      constraints: const BoxConstraints(minWidth: 280),
      padding: const EdgeInsets.fromLTRB(12, 10, 14, 10),
      decoration: BoxDecoration(
        color: p.bgRaised,
        borderRadius: AbTokens.borderRadius8,
        border: Border.all(color: p.borderStrong),
        boxShadow: [
          BoxShadow(
            color: const Color(0xB3000000),
            blurRadius: 48,
            offset: const Offset(0, 24),
          ),
        ],
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 22,
            height: 22,
            alignment: Alignment.center,
            decoration: BoxDecoration(
              color: (iconColor ?? p.statusRunning).withValues(
                alpha: 0.15,
              ),
              borderRadius: AbTokens.borderRadiusFull,
            ),
            child: AbIcon(
              icon,
              size: 12,
              color: iconColor ?? p.statusRunning,
            ),
          ),
          const SizedBox(width: 10),
          // Both flex so long text WRAPS under the host's width cap instead
          // of overflowing the Row. Expanded (tight) pins the action/close
          // to the trailing edge; loose Flexible keeps a bare toast
          // shrink-wrapped below the cap. Either way the host must bound the
          // Row's width — see _ToastStackView's ConstrainedBox.
          if (hasAction || hasClose)
            Expanded(child: textColumn)
          else
            Flexible(child: textColumn),
          if (hasAction) ...[
            const SizedBox(width: 12),
            GestureDetector(
              onTap: onAction,
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                decoration: BoxDecoration(
                  color: p.bgHover,
                  border: Border.all(color: p.borderDefault),
                  borderRadius: AbTokens.borderRadius3,
                ),
                child: Text(
                  actionLabel!,
                  style: TextStyle(
                    fontSize: AbTokens.fontSm,
                    fontWeight: FontWeight.w500,
                    color: p.textPrimary,
                  ),
                ),
              ),
            ),
          ],
          if (hasClose) ...[
            SizedBox(width: hasAction ? 4 : 8),
            // Present but invisible/untappable at rest — faded and
            // IgnorePointer'd rather than left out of the tree, so hovering
            // doesn't reflow the text column next to it. Stays focusable, and
            // focus reveals it. Tab never reaches it: the host sits outside
            // the Navigator, whose focus scope route traversal stays within.
            // Focus.of tracks focus anywhere below the wrapping Focus, which
            // Focus.onFocusChange (primary focus only) does not.
            Builder(
              builder: (ctx) {
                final revealed = hovered || Focus.of(ctx).hasFocus;
                return AbCrossFade(
                  visible: revealed,
                  duration: AbTokens.motionSnap,
                  child: IgnorePointer(
                    ignoring: !hovered,
                    child: ExcludeSemantics(
                      excluding: !revealed,
                      child: AbIconButton(
                        icon: AbIcons.close,
                        tone: AbIconButtonTone.muted,
                        tooltip: 'Dismiss',
                        boxSize: 20,
                        glyphSize: 11,
                        onTap: onClose,
                      ),
                    ),
                  ),
                );
              },
            ),
          ],
        ],
      ),
    );
    final target = onTap == null
        ? card
        : MouseRegion(
            cursor: SystemMouseCursors.click,
            child: GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: onTap,
              child: card,
            ),
          );
    final announced = Semantics(
      liveRegion: true,
      container: true,
      button: onTap != null,
      child: target,
    );
    if (!hasClose) return announced;
    return Focus(canRequestFocus: false, skipTraversal: true, child: announced);
  }
}

class _ActiveToast {
  _ActiveToast(this.toast, this.duration);
  final AbToast toast;
  final Duration duration;

  bool isRepeatOf(AbToast other) =>
      toast.actionLabel == null &&
      other.actionLabel == null &&
      toast.onTap == null &&
      other.onTap == null &&
      toast.title == other.title &&
      toast.description == other.description &&
      toast.icon == other.icon &&
      toast.iconColor == other.iconColor;
}

/// A burst (a held key auto-repeating) must not fill the screen; the oldest
/// toast is dropped first since the newest is closest to the trigger. Only
/// distinct toasts count: an identical repeat replaces its card.
const int _kMaxStackedToasts = 4;

const Duration _kDefaultToastDuration = Duration(seconds: 4);

/// The toasts an [AbToastHost] is showing.
///
/// A plain object rather than something read off a widget, so a caller whose
/// widget may be gone by the time its answer lands (a tap that disposes its
/// own row, a reply after a long await) captures it BEFORE the first await
/// and needs no live context afterwards.
class AbToaster extends ChangeNotifier {
  final List<_ActiveToast> _active = [];
  bool _disposed = false;

  /// The toaster of the nearest [AbToastHost], or null outside one. Registers
  /// no dependency, so it is safe to call from a callback.
  static AbToaster? maybeOf(BuildContext context) =>
      context.getInheritedWidgetOfExactType<_AbToastScope>()?.toaster;

  /// Shows [toast], auto-dismissing after [duration].
  ///
  /// A toast with the same title, description and icon as one already showing,
  /// and no action or tap target on either, replaces that card: one card, with
  /// a full timer, in the newest position. A toast with a callback never
  /// replaces another, since each carries its own.
  void show(AbToast toast, {Duration duration = _kDefaultToastDuration}) {
    // A captured toaster can outlive its owner — a reply landing after the
    // app, or a test's container, has been torn down.
    if (_disposed) return;
    // A repeat REPLACES its card rather than updating it: the fresh entry gets
    // a fresh widget state and so a fresh timer, while the old card's pending
    // timer or swipe-out lands on an entry no longer in the stack and does
    // nothing (see [_dismiss]).
    _active.removeWhere((existing) => existing.isRepeatOf(toast));
    _active.add(_ActiveToast(toast, duration));
    while (_active.length > _kMaxStackedToasts) {
      _active.removeAt(0);
    }
    notifyListeners();
  }

  /// The single plain-text toast: [message] as the title, no description and
  /// a neutral icon, so a one-line notice carries no per-call styling
  /// decision. [clearPrevious] dismisses every toast showing first instead of
  /// stacking above them.
  void showMessage(
    String message, {
    Duration? duration,
    bool clearPrevious = false,
  }) {
    if (clearPrevious) clear();
    show(
      AbToast(icon: AbIcons.info, title: message),
      duration: duration ?? _kDefaultToastDuration,
    );
  }

  /// Immediately dismisses every toast showing, ahead of its own timer.
  void clear() {
    if (_disposed || _active.isEmpty) return;
    _active.clear();
    notifyListeners();
  }

  /// A no-op if [active] is already gone: the close button and the timer can
  /// each fire first, and whichever loses does nothing.
  void _dismiss(_ActiveToast active) {
    if (_disposed || !_active.remove(active)) return;
    notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    super.dispose();
  }
}

/// Renders [toaster]'s toasts above [child]. Mounted once, around the app's
/// Navigator, so a toast outlives its route and sits above every dialog. It
/// brings its own [Overlay] because none of the Navigator's encloses it, and a
/// card's tooltip needs one.
class AbToastHost extends StatefulWidget {
  const AbToastHost({super.key, this.toaster, required this.child});

  /// Fixed for the host's lifetime; the host owns one itself when null.
  final AbToaster? toaster;
  final Widget child;

  @override
  State<AbToastHost> createState() => _AbToastHostState();
}

class _AbToastHostState extends State<AbToastHost> {
  AbToaster? _owned;
  late final OverlayEntry _entry = OverlayEntry(
    builder: (_) => ListenableBuilder(
      listenable: _toaster,
      builder: (_, _) => _ToastStackView(toaster: _toaster),
    ),
  );

  AbToaster get _toaster => widget.toaster ?? (_owned ??= AbToaster());

  @override
  void didUpdateWidget(AbToastHost oldWidget) {
    super.didUpdateWidget(oldWidget);
    assert(widget.toaster == oldWidget.toaster, 'AbToastHost.toaster is fixed');
  }

  @override
  void dispose() {
    _entry
      ..remove()
      ..dispose();
    _owned?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return _AbToastScope(
      toaster: _toaster,
      // Empty space in the toast Overlay hits nothing, so a tap anywhere but
      // on a card falls through to [child].
      child: Stack(
        fit: StackFit.expand,
        children: [
          widget.child,
          Overlay(initialEntries: [_entry]),
        ],
      ),
    );
  }
}

class _AbToastScope extends InheritedWidget {
  const _AbToastScope({required this.toaster, required super.child});

  final AbToaster toaster;

  @override
  bool updateShouldNotify(_AbToastScope oldWidget) =>
      toaster != oldWidget.toaster;
}

/// [AbToaster.showMessage] on the toaster of [context]'s [AbToastHost]. A
/// no-op outside one.
void showAbToast(
  BuildContext context,
  String message, {
  Duration? duration,
  bool clearPrevious = false,
}) => AbToaster.maybeOf(context)?.showMessage(
  message,
  duration: duration,
  clearPrevious: clearPrevious,
);

/// [AbToaster.show] on the toaster of [context]'s [AbToastHost]. A no-op
/// outside one.
void showAbToastOverlay(
  BuildContext context, {
  required AbToast toast,
  Duration duration = _kDefaultToastDuration,
}) => AbToaster.maybeOf(context)?.show(toast, duration: duration);

/// [AbToaster.clear] on the toaster of [context]'s [AbToastHost].
void clearAbToasts(BuildContext context) => AbToaster.maybeOf(context)?.clear();

class _ToastStackView extends StatelessWidget {
  const _ToastStackView({required this.toaster});

  final AbToaster toaster;

  @override
  Widget build(BuildContext context) {
    // Bottom, not top: the top-right corner holds the window's caption buttons
    // and the context panel's tab bar on desktop. padding excludes whatever
    // the keyboard already covers, so padding + viewInsets is the larger of
    // the system inset and the keyboard rather than their sum.
    final bottom =
        MediaQuery.paddingOf(context).bottom +
        MediaQuery.viewInsetsOf(context).bottom +
        AbTokens.space16;
    final touch = isMobilePlatform;
    // The overlay theater hands a bottom/right-only Positioned unbounded
    // width, and the toast's flex children assert without a finite max —
    // cap it, screen-fitted on narrow phones. The clamp also floors at 0:
    // a window dragged below the margins would otherwise produce negative
    // (invalid) constraints.
    final column = ConstrainedBox(
      constraints: BoxConstraints(
        maxWidth: (MediaQuery.sizeOf(context).width - AbTokens.space16 * 2)
            .clamp(0.0, 360.0),
      ),
      child: Material(
        color: Colors.transparent,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: touch
              ? CrossAxisAlignment.center
              : CrossAxisAlignment.end,
          // Oldest first so the newest sits nearest the anchor edge, closest
          // to where the trigger happened; older toasts get pushed up rather
          // than replaced so a burst of failures (e.g. a held key
          // auto-repeating) is visible as a stack instead of overlapping
          // illegibly.
          children: [
            for (final a in toaster._active)
              Padding(
                key: ObjectKey(a),
                padding: const EdgeInsets.only(top: AbTokens.space8),
                child: _DismissingToast(
                  active: a,
                  onExpire: () => toaster._dismiss(a),
                ),
              ),
          ],
        ),
      ),
    );
    if (touch) {
      return Positioned(
        left: 0,
        right: 0,
        bottom: bottom,
        child: Align(
          alignment: Alignment.bottomCenter,
          heightFactor: 1,
          child: column,
        ),
      );
    }
    return Positioned(bottom: bottom, right: AbTokens.space16, child: column);
  }
}

/// Owns the one auto-dismiss [Timer] for [active], started in [initState] and
/// cancelled in [dispose] — bound to the toast's OWN widget lifecycle rather
/// than tracked externally, so a toast that is inserted but never actually
/// built (a test that triggers one and ends without a further `pump`) never
/// starts a timer to leak in the first place, and one that IS built has its
/// timer cancelled the moment the toast leaves the tree, however that
/// happens: it expires, its close button is tapped, [AbToaster.clear] wipes the
/// stack, or the host itself is torn down.
class _DismissingToast extends StatefulWidget {
  const _DismissingToast({required this.active, required this.onExpire});

  final _ActiveToast active;
  final VoidCallback onExpire;

  @override
  State<_DismissingToast> createState() => _DismissingToastState();
}

class _DismissingToastState extends State<_DismissingToast> {
  Timer? _timer;
  bool _hovered = false;

  // Touch's dismiss gesture (see AbToast's hasClose). Tracked here rather
  // than in AbToast because dismissing is a STACK concern.
  double _dragExtent = 0;
  bool _dragging = false;

  static const _kSwipeDismissDistance = 80.0;
  static const _kSwipeFlingVelocity = 600.0;
  static const _kSwipeExitDistance = 400.0;

  @override
  void initState() {
    super.initState();
    _startTimer();
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  void _startTimer() {
    _timer?.cancel();
    _timer = Timer(widget.active.duration, widget.onExpire);
  }

  void _setHovered(bool hovered) {
    // Leaving restarts the full duration rather than the remainder: the user
    // just showed attention, so a fresh window beats a sliver.
    hovered ? _timer?.cancel() : _startTimer();
    setState(() => _hovered = hovered);
  }

  void _dismissNow() {
    _timer?.cancel();
    widget.onExpire();
  }

  void _onDragStart(DragStartDetails _) => setState(() => _dragging = true);

  void _onDragUpdate(DragUpdateDetails details) =>
      setState(() => _dragExtent += details.delta.dx);

  void _onDragEnd(DragEndDetails details) {
    final velocity = details.velocity.pixelsPerSecond.dx;
    final committed =
        _dragExtent.abs() > _kSwipeDismissDistance ||
        velocity.abs() > _kSwipeFlingVelocity;
    if (!committed) {
      setState(() {
        _dragging = false;
        _dragExtent = 0;
      });
      return;
    }
    // Stop the auto-dismiss timer now — we're committed to closing this card
    // — but let the exit animation (driven by the AnimatedContainer below)
    // finish before actually removing it from the stack.
    _timer?.cancel();
    final direction = _dragExtent != 0
        ? _dragExtent.sign
        : (velocity < 0 ? -1.0 : 1.0);
    setState(() {
      _dragging = false;
      _dragExtent = direction * _kSwipeExitDistance;
    });
    Future.delayed(const Duration(milliseconds: 180), () {
      if (mounted) widget.onExpire();
    });
  }

  @override
  Widget build(BuildContext context) {
    final toast = widget.active.toast;
    // Rebuilt with onClose wired to THIS active entry rather than stored on
    // it: the caller's AbToast never has to know it's being shown through
    // the stack at all. The boundary keeps a swipe or a stack change from
    // repainting the card's blurred shadow every frame.
    final card = RepaintBoundary(
      child: AbToast(
        icon: toast.icon,
        title: toast.title,
        description: toast.description,
        iconColor: toast.iconColor,
        actionLabel: toast.actionLabel,
        onAction: toast.onAction == null
            ? null
            : () {
                _dismissNow();
                toast.onAction!();
              },
        onTap: toast.onTap == null
            ? null
            : () {
                _dismissNow();
                toast.onTap!();
              },
        onClose: _dismissNow,
        hovered: _hovered,
      ),
    );
    if (!isMobilePlatform) {
      return MouseRegion(
        onEnter: (_) => _setHovered(true),
        onExit: (_) => _setHovered(false),
        child: card,
      );
    }
    return GestureDetector(
      onHorizontalDragStart: _onDragStart,
      onHorizontalDragUpdate: _onDragUpdate,
      onHorizontalDragEnd: _onDragEnd,
      // Zero duration WHILE dragging makes this track the finger 1:1 (every
      // frame "animates" instantly to the new value); a real duration once
      // released is what animates the spring-back or the fling-away.
      child: AnimatedContainer(
        duration: _dragging ? Duration.zero : const Duration(milliseconds: 180),
        curve: Curves.easeOut,
        transform: Matrix4.translationValues(_dragExtent, 0, 0),
        child: card,
      ),
    );
  }
}
