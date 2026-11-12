import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

import '../foundations/theme.dart';

/// Why a [CarbonAnchoredPopup] closed itself. Closes requested through
/// [CarbonPopupController.close] are the host's own and are not reported.
enum CarbonPopupDismissReason {
  /// A pointer went down outside both the popup and its anchor.
  outsideTap,

  /// Escape was pressed while focus was in the anchor or the popup.
  escape,

  /// The system back gesture or button, through the enclosing route.
  back,

  /// The anchor scrolled out of view or was removed from the tree.
  anchorLost,
}

/// Which anchor edge the popup lines up with, resolved against the ambient
/// text direction.
enum CarbonPopupAlignment {
  /// The popup's start edge meets the anchor's start edge (left in LTR).
  start,

  /// The popup's end edge meets the anchor's end edge (right in LTR).
  end,
}

/// Opens and closes a [CarbonAnchoredPopup], and reports whether it is open.
///
/// Host-owned: create it in `initState`, dispose it in `dispose`. Listeners are
/// notified whenever [isOpen] changes, including when the popup dismisses
/// itself; notifications that would land mid-frame are delivered after the
/// frame so a listener may call `setState`.
///
/// [open] before the popup is mounted is remembered and applied on mount.
/// Disposing the controller while its popup is open closes the popup.
class CarbonPopupController extends ChangeNotifier {
  _CarbonAnchoredPopupState? _popup;
  bool _open = false;
  bool _disposed = false;

  bool get isOpen => _open;

  void open() {
    final popup = _popup;
    if (popup == null) {
      _setOpen(true);
    } else {
      popup._afterBuild(popup._show);
    }
  }

  /// Closes the popup. Idempotent; focus returns to the trigger if it was in
  /// the popup.
  void close() {
    final popup = _popup;
    if (popup == null) {
      _setOpen(false);
    } else {
      popup._afterBuild(popup._hide);
    }
  }

  void toggle() => isOpen ? close() : open();

  // The most recently mounted popup wins: a replacement can mount in the same
  // frame before the popup it replaces is disposed.
  void _attach(_CarbonAnchoredPopupState popup) => _popup = popup;

  /// Detaches [popup] and reports whether it was the attached one, so a
  /// superseded popup cannot overwrite its successor's open state.
  bool _detach(_CarbonAnchoredPopupState popup) {
    if (!identical(_popup, popup)) return false;
    _popup = null;
    return true;
  }

  void _setOpen(bool value) {
    if (_open == value) return;
    _open = value;
    if (_disposed) return;
    if (SchedulerBinding.instance.schedulerPhase ==
        SchedulerPhase.persistentCallbacks) {
      SchedulerBinding.instance.addPostFrameCallback((_) {
        if (!_disposed) notifyListeners();
      });
    } else {
      notifyListeners();
    }
  }

  @override
  void dispose() {
    _disposed = true;
    final popup = _popup;
    _popup = null;
    popup?._controllerDisposed(this);
    super.dispose();
  }
}

/// Builds popup content. [available] is the space the popup may occupy: width
/// already resolved from the anchor and viewport, height capped by
/// `maxHeight` and by the larger of the space above and below the anchor.
/// Content taller than [available] must scroll.
typedef CarbonPopupBuilder =
    Widget Function(BuildContext context, BoxConstraints available);

/// Shows content anchored below (or above) its [child], in the nearest
/// [Overlay].
///
/// The shared anchoring infrastructure behind Select, Dropdown, Menu and
/// Tooltip. It positions, clamps and dismisses; it paints no surface and owns
/// no keyboard semantics. Consumers paint their own Carbon surface in
/// [popupBuilder] and handle arrow keys, selection and focus inside it.
///
/// Placement: below the anchor, flipping above when the content does not fit
/// below and fits (or has more room) above; [preferAbove] reverses the
/// preference. Horizontally aligned to the anchor's start or end edge per
/// [alignment] and text direction, then clamped into the overlay minus the
/// safe-area padding and keyboard inset of the anchor's [MediaQuery].
/// Placement follows the anchor every frame while open.
///
/// Inheritance: the content builds beneath this widget, so it sees the
/// anchor's live [CarbonTheme], localizations and direction; theme changes
/// reach an open popup without remounting it. Unless [raiseLayer] is false
/// the content sits one [CarbonLayer] above the anchor, as Carbon popovers do.
///
/// Dismissal ([onDismissed] reports the reason): a pointer down outside the
/// popup and anchor, Escape while focus is in either, system back via the
/// enclosing [ModalRoute], the anchor scrolling out of its scrollables'
/// viewports, or the anchor leaving the tree. Each can be turned off, e.g.
/// tooltips ignore back. When focus was inside the popup as it closes, focus
/// returns to [restoreFocus] if it is still in the tree.
class CarbonAnchoredPopup extends StatefulWidget {
  const CarbonAnchoredPopup({
    super.key,
    required this.controller,
    required this.popupBuilder,
    required this.child,
    this.matchAnchorWidth = false,
    this.minWidth = 0,
    this.maxWidth,
    this.maxHeight,
    this.gap = 0,
    this.preferAbove = false,
    this.alignment = CarbonPopupAlignment.start,
    this.onDismissed,
    this.restoreFocus,
    this.raiseLayer = true,
    this.dismissOnOutsideTap = true,
    this.dismissOnEscape = true,
    this.dismissOnBack = true,
  });

  final CarbonPopupController controller;
  final CarbonPopupBuilder popupBuilder;

  /// The anchor. Taps on it count as inside the popup, so a trigger that
  /// toggles the controller is not closed and reopened by the same tap.
  final Widget child;

  /// Makes the popup exactly as wide as the anchor (within [minWidth] and the
  /// viewport), as Carbon's select and dropdown lists are.
  final bool matchAnchorWidth;

  final double minWidth;
  final double? maxWidth;

  /// Caps the popup height; it is always capped by the viewport too.
  final double? maxHeight;

  /// Space between the anchor and the popup.
  final double gap;

  final bool preferAbove;
  final CarbonPopupAlignment alignment;

  /// Called after the popup closed itself, with the reason. Not called for
  /// [CarbonPopupController.close]. For [CarbonPopupDismissReason.anchorLost]
  /// caused by removal it arrives after the frame, when the host may itself
  /// be gone.
  final ValueChanged<CarbonPopupDismissReason>? onDismissed;

  /// Where focus goes when the popup closes with focus inside it. Defaults to
  /// whatever held primary focus when the popup opened.
  final FocusNode? restoreFocus;

  final bool raiseLayer;
  final bool dismissOnOutsideTap;
  final bool dismissOnEscape;
  final bool dismissOnBack;

  @override
  State<CarbonAnchoredPopup> createState() => _CarbonAnchoredPopupState();
}

class _CarbonAnchoredPopupState extends State<CarbonAnchoredPopup> {
  final OverlayPortalController _portal = OverlayPortalController(
    debugLabel: 'CarbonAnchoredPopup',
  );
  final FocusNode _popupFocus = FocusNode(
    debugLabel: 'CarbonAnchoredPopup content',
    canRequestFocus: false,
    skipTraversal: true,
  );
  late final _PopupPopEntry _popEntry = _PopupPopEntry(this);
  late final Map<Type, Action<Intent>> _actions = <Type, Action<Intent>>{
    DismissIntent: _DismissPopupAction(this),
  };

  ModalRoute<Object?>? _route;
  bool _popRegistered = false;
  List<ScrollPosition> _positions = const <ScrollPosition>[];
  List<ScrollableState> _scrollables = const <ScrollableState>[];
  FocusNode? _openedFocus;
  bool _visibilityCheckPending = false;

  // Tracked separately from the portal controller, which forgets its state
  // when the OverlayPortal below is disposed ahead of this state.
  bool _isOpen = false;

  static const Map<ShortcutActivator, Intent> _shortcuts =
      <ShortcutActivator, Intent>{
        SingleActivator(LogicalKeyboardKey.escape): DismissIntent(),
      };

  // Escape is bound, and the dismiss action registered, only while it can
  // dismiss. Shortcut dispatch stops at the nearest action for an intent even
  // when that action is disabled, so a standing binding on a closed popup
  // would swallow Escape meant for an enclosing dialog or outer popup.
  bool get _handlesEscape => _isOpen && widget.dismissOnEscape;

  @override
  void initState() {
    super.initState();
    widget.controller._attach(this);
    if (widget.controller.isOpen) {
      _isOpen = true;
      _portal.show();
    }
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final route = ModalRoute.of(context);
    // Registers the dependency so a changed scroll ancestor re-runs this.
    Scrollable.maybeOf(context);
    if (route != _route) {
      _unregisterPop();
      _route = route;
    }
    if (_isOpen) {
      _openedFocus ??= FocusManager.instance.primaryFocus;
      _registerPop();
      _listenToScrolling();
    }
  }

  @override
  void didUpdateWidget(CarbonAnchoredPopup oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.controller != oldWidget.controller) {
      if (oldWidget.controller._detach(this)) {
        oldWidget.controller._setOpen(false);
      }
      widget.controller._attach(this);
      if (widget.controller.isOpen && !_isOpen) {
        _afterBuild(_show);
      } else {
        widget.controller._setOpen(_isOpen);
      }
    }
    if (widget.dismissOnBack != oldWidget.dismissOnBack && _isOpen) {
      if (widget.dismissOnBack) {
        _registerPop();
      } else {
        _unregisterPop();
      }
    }
  }

  @override
  void dispose() {
    final wasOpen = _isOpen;
    final restore = _restoreTarget();
    final hadFocus = _popupFocus.hasFocus;
    // A replacement that mounted in the same frame has taken over the open
    // controller; the popup is still showing, so nothing was dismissed.
    final superseded =
        widget.controller._popup != null &&
        !identical(widget.controller._popup, this);
    _unregisterPop();
    _stopListeningToScrolling();
    if (widget.controller._detach(this)) widget.controller._setOpen(false);
    _popupFocus.dispose();
    _popEntry.dispose();
    if (wasOpen && !superseded) {
      final onDismissed = widget.onDismissed;
      SchedulerBinding.instance.addPostFrameCallback((_) {
        if (hadFocus) _requestFocusIfAlive(restore);
        onDismissed?.call(CarbonPopupDismissReason.anchorLost);
      });
    }
    super.dispose();
  }

  // Overlay and controller state cannot change while the tree is being built
  // or laid out; requests arriving then are applied after the frame.
  void _afterBuild(VoidCallback action) {
    if (SchedulerBinding.instance.schedulerPhase ==
        SchedulerPhase.persistentCallbacks) {
      SchedulerBinding.instance.addPostFrameCallback((_) {
        if (mounted) action();
      });
      SchedulerBinding.instance.ensureVisualUpdate();
    } else {
      action();
    }
  }

  void _show() {
    if (!mounted || _isOpen) return;
    // A trigger usually requests focus in the same event that opens the
    // popup, and that request only lands in a later microtask; apply it first
    // so the trigger, not whatever it took focus from, is restored on close.
    FocusManager.instance.applyFocusChangesIfNeeded();
    _openedFocus = FocusManager.instance.primaryFocus;
    setState(() => _isOpen = true);
    _portal.show();
    _registerPop();
    _listenToScrolling();
    _reportOpen(true);
  }

  void _hide([CarbonPopupDismissReason? reason]) {
    if (!mounted || !_isOpen) return;
    final hadFocus = _popupFocus.hasFocus;
    final restore = _restoreTarget();
    setState(() => _isOpen = false);
    _portal.hide();
    // Back dismissal arrives while the route iterates its pop entries, so
    // leave the set alone until that loop has finished.
    scheduleMicrotask(() {
      if (!_isOpen) _unregisterPop();
    });
    _stopListeningToScrolling();
    _openedFocus = null;
    _reportOpen(false);
    if (hadFocus) _requestFocusIfAlive(restore);
    if (reason != null) widget.onDismissed?.call(reason);
  }

  void _reportOpen(bool open) {
    if (identical(widget.controller._popup, this)) {
      widget.controller._setOpen(open);
    }
  }

  void _dismiss(CarbonPopupDismissReason reason) {
    if (!_isOpen) return;
    _afterBuild(() => _hide(reason));
  }

  void _controllerDisposed(CarbonPopupController controller) {
    if (!identical(controller, widget.controller)) return;
    _afterBuild(_hide);
  }

  FocusNode? _restoreTarget() => widget.restoreFocus ?? _openedFocus;

  static void _requestFocusIfAlive(FocusNode? node) {
    if (node == null) return;
    final nodeContext = node.context;
    if (nodeContext == null || !nodeContext.mounted) return;
    if (!node.canRequestFocus) return;
    node.requestFocus();
  }

  void _registerPop() {
    final route = _route;
    if (_popRegistered || route == null || !widget.dismissOnBack) return;
    route.registerPopEntry(_popEntry);
    _popRegistered = true;
  }

  void _unregisterPop() {
    if (!_popRegistered) return;
    _route?.unregisterPopEntry(_popEntry);
    _popRegistered = false;
  }

  void _listenToScrolling() {
    _stopListeningToScrolling();
    final scrollables = <ScrollableState>[];
    context.visitAncestorElements((element) {
      if (element is StatefulElement && element.state is ScrollableState) {
        scrollables.add(element.state as ScrollableState);
      }
      return true;
    });
    _scrollables = scrollables;
    _positions = <ScrollPosition>[
      for (final scrollable in scrollables) scrollable.position,
    ];
    for (final position in _positions) {
      position.addListener(_handleScroll);
    }
  }

  void _stopListeningToScrolling() {
    for (final position in _positions) {
      position.removeListener(_handleScroll);
    }
    _positions = const <ScrollPosition>[];
    _scrollables = const <ScrollableState>[];
  }

  void _handleScroll() {
    if (_visibilityCheckPending) return;
    _visibilityCheckPending = true;
    // Scroll offsets change before layout; judge visibility on the laid-out
    // frame.
    SchedulerBinding.instance.addPostFrameCallback((_) {
      _visibilityCheckPending = false;
      _checkAnchorVisible();
    });
    SchedulerBinding.instance.ensureVisualUpdate();
  }

  void _checkAnchorVisible() {
    if (!mounted || !_isOpen) return;
    final anchor = _globalRect(context.findRenderObject());
    if (anchor == null) return;
    for (final scrollable in _scrollables) {
      if (!scrollable.mounted) continue;
      final viewport = _globalRect(scrollable.context.findRenderObject());
      if (viewport != null && !viewport.overlaps(anchor)) {
        _hide(CarbonPopupDismissReason.anchorLost);
        return;
      }
    }
  }

  static Rect? _globalRect(RenderObject? object) {
    if (object is! RenderBox || !object.attached || !object.hasSize) {
      return null;
    }
    return MatrixUtils.transformRect(
      object.getTransformTo(null),
      Offset.zero & object.size,
    );
  }

  Widget _buildOverlay(BuildContext context, OverlayChildLayoutInfo info) {
    final anchor = MatrixUtils.transformRect(
      info.childPaintTransform,
      Offset.zero & info.childSize,
    );
    final padding = MediaQuery.maybePaddingOf(context) ?? EdgeInsets.zero;
    final insets = MediaQuery.maybeViewInsetsOf(context) ?? EdgeInsets.zero;
    final overlay = Offset.zero & info.overlaySize;
    final bounds = Rect.fromLTRB(
      overlay.left + math.max(padding.left, insets.left),
      overlay.top + math.max(padding.top, insets.top),
      math.max(
        overlay.left,
        overlay.right - math.max(padding.right, insets.right),
      ),
      math.max(
        overlay.top,
        overlay.bottom - math.max(padding.bottom, insets.bottom),
      ),
    );

    final gap = widget.gap;
    final spaceBelow = math.max(0.0, bounds.bottom - anchor.bottom - gap);
    final spaceAbove = math.max(0.0, anchor.top - gap - bounds.top);
    final maxWidth = math.max(
      0.0,
      math.min(widget.maxWidth ?? double.infinity, bounds.width),
    );
    final minWidth = math.min(widget.minWidth, maxWidth);
    final maxHeight = math.min(
      widget.maxHeight ?? double.infinity,
      math.max(spaceBelow, spaceAbove),
    );
    final BoxConstraints available;
    if (widget.matchAnchorWidth) {
      final width = anchor.width.clamp(minWidth, maxWidth);
      available = BoxConstraints(
        minWidth: width,
        maxWidth: width,
        maxHeight: maxHeight,
      );
    } else {
      available = BoxConstraints(
        minWidth: minWidth,
        maxWidth: maxWidth,
        maxHeight: maxHeight,
      );
    }

    Widget content = widget.popupBuilder(context, available);
    if (widget.raiseLayer) {
      content = CarbonLayer(
        level: math.min(CarbonLayer.of(context) + 1, 3),
        child: content,
      );
    }

    return CustomSingleChildLayout(
      delegate: _PopupLayoutDelegate(
        anchor: anchor,
        bounds: bounds,
        available: available,
        gap: gap,
        preferAbove: widget.preferAbove,
        alignEnd: widget.alignment == CarbonPopupAlignment.end,
        rtl: Directionality.maybeOf(context) == TextDirection.rtl,
      ),
      child: TapRegion(
        groupId: this,
        onTapOutside: widget.dismissOnOutsideTap
            ? (_) => _dismiss(CarbonPopupDismissReason.outsideTap)
            : null,
        child: Focus(
          focusNode: _popupFocus,
          canRequestFocus: false,
          skipTraversal: true,
          includeSemantics: false,
          child: content,
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final handlesEscape = _handlesEscape;
    return Shortcuts(
      shortcuts: handlesEscape ? _shortcuts : const <ShortcutActivator, Intent>{},
      includeSemantics: false,
      child: Actions(
        actions: handlesEscape ? _actions : const <Type, Action<Intent>>{},
        child: TapRegion(
          groupId: this,
          child: OverlayPortal.overlayChildLayoutBuilder(
            controller: _portal,
            overlayChildBuilder: _buildOverlay,
            child: widget.child,
          ),
        ),
      ),
    );
  }
}

class _PopupLayoutDelegate extends SingleChildLayoutDelegate {
  const _PopupLayoutDelegate({
    required this.anchor,
    required this.bounds,
    required this.available,
    required this.gap,
    required this.preferAbove,
    required this.alignEnd,
    required this.rtl,
  });

  final Rect anchor;
  final Rect bounds;
  final BoxConstraints available;
  final double gap;
  final bool preferAbove;
  final bool alignEnd;
  final bool rtl;

  @override
  BoxConstraints getConstraintsForChild(BoxConstraints constraints) =>
      available;

  @override
  Offset getPositionForChild(Size size, Size childSize) {
    final spaceBelow = bounds.bottom - anchor.bottom - gap;
    final spaceAbove = anchor.top - gap - bounds.top;
    final fitsBelow = childSize.height <= spaceBelow;
    final fitsAbove = childSize.height <= spaceAbove;
    final bool above;
    if (preferAbove) {
      above = fitsAbove || (!fitsBelow && spaceAbove >= spaceBelow);
    } else {
      above = !fitsBelow && (fitsAbove || spaceAbove > spaceBelow);
    }
    var y = above ? anchor.top - gap - childSize.height : anchor.bottom + gap;
    y = _clamp(y, bounds.top, bounds.bottom - childSize.height);

    // Start alignment meets the anchor's leading edge, which is its right
    // edge in RTL.
    final alignRight = alignEnd != rtl;
    var x = alignRight ? anchor.right - childSize.width : anchor.left;
    x = _clamp(x, bounds.left, bounds.right - childSize.width);
    return Offset(x, y);
  }

  // Like num.clamp, but a popup larger than the bounds pins to the start edge
  // instead of throwing.
  static double _clamp(double value, double min, double max) =>
      max < min ? min : value.clamp(min, max);

  @override
  bool shouldRelayout(_PopupLayoutDelegate old) =>
      old.anchor != anchor ||
      old.bounds != bounds ||
      old.available != available ||
      old.gap != gap ||
      old.preferAbove != preferAbove ||
      old.alignEnd != alignEnd ||
      old.rtl != rtl;
}

class _PopupPopEntry extends PopEntry<Object?> {
  _PopupPopEntry(this._owner);

  final _CarbonAnchoredPopupState _owner;

  // Always false while registered: an open popup takes the back gesture
  // instead of its route.
  final ValueNotifier<bool> _canPop = ValueNotifier<bool>(false);

  @override
  ValueListenable<bool> get canPopNotifier => _canPop;

  @override
  void onPopInvokedWithResult(bool didPop, Object? result) {
    if (!didPop) _owner._dismiss(CarbonPopupDismissReason.back);
  }

  void dispose() => _canPop.dispose();
}

class _DismissPopupAction extends Action<DismissIntent> {
  _DismissPopupAction(this._owner);

  final _CarbonAnchoredPopupState _owner;

  @override
  bool isEnabled(DismissIntent intent) => _owner.mounted && _owner._handlesEscape;

  @override
  Object? invoke(DismissIntent intent) {
    _owner._dismiss(CarbonPopupDismissReason.escape);
    return null;
  }
}
