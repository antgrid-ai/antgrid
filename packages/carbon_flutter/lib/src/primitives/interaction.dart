import 'package:flutter/scheduler.dart';
import 'package:flutter/semantics.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

/// The transient interaction state [CarbonInteraction] hands its builder.
///
/// Every flag is already resolved against [enabled]: a disabled control never
/// reports [hovered] or [pressed], so builders can pick colors without
/// re-checking.
@immutable
class CarbonInteractionState {
  const CarbonInteractionState({
    this.hovered = false,
    this.pressed = false,
    this.focused = false,
    this.focusVisible = false,
    this.enabled = true,
  });

  /// A pointer is over the control.
  final bool hovered;

  /// A pointer is down on the control and has not been cancelled.
  final bool pressed;

  /// The control holds keyboard focus, whatever input moved it there.
  final bool focused;

  /// [focused], and the platform is in keyboard highlight mode. Paint the
  /// focus ring from this, not from [focused], so a mouse click does not show
  /// a keyboard ring.
  final bool focusVisible;

  final bool enabled;

  @override
  bool operator ==(Object other) =>
      other is CarbonInteractionState &&
      other.hovered == hovered &&
      other.pressed == pressed &&
      other.focused == focused &&
      other.focusVisible == focusVisible &&
      other.enabled == enabled;

  @override
  int get hashCode =>
      Object.hash(hovered, pressed, focused, focusVisible, enabled);

  @override
  String toString() =>
      'CarbonInteractionState(hovered: $hovered, pressed: $pressed, '
      'focused: $focused, focusVisible: $focusVisible, enabled: $enabled)';
}

/// Builds a control's visuals from its [CarbonInteractionState]. [child] is
/// the invariant subtree passed to [CarbonInteraction.child].
typedef CarbonInteractionBuilder =
    Widget Function(
      BuildContext context,
      CarbonInteractionState state,
      Widget? child,
    );

/// The single focus, hover, press and activation core for Carbon controls.
///
/// Buttons, icon buttons, checkbox and toggle rows, tabs, content-switcher
/// items, menu items, list rows and tag remove buttons all build on this
/// rather than composing their own gesture and focus handling, so activation,
/// disabled behavior and semantics stay consistent across the library.
///
/// * Activation: a primary tap, or Enter / NumpadEnter / Space while focused,
///   calls [onPressed] once. Holding a key does not repeat. A pointer that is
///   cancelled (dragged away, or the gesture arena gives it to a scrollable)
///   never activates.
/// * Disabled: [onPressed] null. The control never activates, drops any held
///   hover and pressed state, shows the basic cursor and cannot take focus
///   unless [focusableWhenDisabled] is set.
/// * Focus: uses [focusNode] when supplied and never disposes it; otherwise
///   owns one for the life of the state.
/// * Semantics: one container node carrying the role flags given here. Use
///   [excludeChildSemantics] when [label] already names the control and the
///   visual child would announce it twice.
///
/// Presentation (padding, fills, minimum size, focus ring) belongs to the
/// [builder]; this widget paints nothing itself.
class CarbonInteraction extends StatefulWidget {
  const CarbonInteraction({
    super.key,
    required this.builder,
    this.child,
    this.onPressed,
    this.onLongPress,
    this.onSecondaryTap,
    this.focusNode,
    this.autofocus = false,
    this.focusableWhenDisabled = false,
    this.requestFocusOnTap = false,
    this.mouseCursor,
    this.onFocusChange,
    this.onHoverChange,
    this.hitTestBehavior = HitTestBehavior.opaque,
    this.button = true,
    this.role,
    this.label,
    this.hint,
    this.value,
    this.tooltip,
    this.selected,
    this.checked,
    this.mixed = false,
    this.toggled,
    this.expanded,
    this.inMutuallyExclusiveGroup,
    this.excludeChildSemantics = false,
  });

  final CarbonInteractionBuilder builder;

  /// Passed through to [builder] unchanged; put subtrees that do not depend
  /// on interaction state here so they are not rebuilt on hover or press.
  final Widget? child;

  /// Primary activation. Null disables the control.
  final VoidCallback? onPressed;

  /// Long press, e.g. a touch path to a context menu. Ignored when disabled.
  final VoidCallback? onLongPress;

  /// Secondary (right) click, for context menus. Ignored when disabled.
  final VoidCallback? onSecondaryTap;

  final FocusNode? focusNode;
  final bool autofocus;

  /// Keeps a disabled control in the focus order, for controls that go
  /// briefly unavailable (a busy button) and must not drop the user's focus.
  final bool focusableWhenDisabled;

  /// Moves focus to the control on a primary tap. Popup triggers set this so
  /// focus can return to them when the popup closes.
  final bool requestFocusOnTap;

  /// Defaults to [SystemMouseCursors.click] when enabled and
  /// [SystemMouseCursors.basic] when disabled.
  final MouseCursor? mouseCursor;

  final ValueChanged<bool>? onFocusChange;
  final ValueChanged<bool>? onHoverChange;

  final HitTestBehavior hitTestBehavior;

  /// Announces the control as a button. Clear it for rows and items whose
  /// role comes from [role] or from flags such as [checked].
  final bool button;

  final SemanticsRole? role;
  final String? label;
  final String? hint;
  final String? value;
  final String? tooltip;
  final bool? selected;

  /// Checked state for checkable controls; null for controls that are not.
  final bool? checked;

  /// Indeterminate checked state. Takes precedence over [checked], which is
  /// then announced as false as Flutter's semantics model requires.
  final bool mixed;

  final bool? toggled;
  final bool? expanded;
  final bool? inMutuallyExclusiveGroup;

  /// Drops the visual child's own semantics so only this node's [label]
  /// announces.
  final bool excludeChildSemantics;

  bool get enabled => onPressed != null;

  @override
  State<CarbonInteraction> createState() => _CarbonInteractionState();
}

class _CarbonInteractionState extends State<CarbonInteraction> {
  FocusNode? _ownedNode;
  bool _hovered = false;
  bool _pressed = false;
  bool _focused = false;
  bool _highlightTraditional = false;

  // What the host was last told through onHoverChange / onFocusChange. Kept
  // apart from the live flags because changes found during build are
  // reported after the frame, and a later live change may already have
  // delivered the same value.
  bool _reportedHover = false;
  bool _reportedFocus = false;

  FocusNode get _node => widget.focusNode ?? _ownedNode!;

  static const Map<ShortcutActivator, Intent> _shortcuts =
      <ShortcutActivator, Intent>{
        SingleActivator(LogicalKeyboardKey.enter, includeRepeats: false):
            ActivateIntent(),
        SingleActivator(LogicalKeyboardKey.numpadEnter, includeRepeats: false):
            ActivateIntent(),
        SingleActivator(LogicalKeyboardKey.space, includeRepeats: false):
            ButtonActivateIntent(),
        // Listed after the activators above so only repeats reach them. Held
        // keys must not fall through to an ancestor's repeating ActivateIntent
        // binding (WidgetsApp has one), which would re-activate this control.
        SingleActivator(LogicalKeyboardKey.enter): _SwallowRepeatIntent(),
        SingleActivator(LogicalKeyboardKey.numpadEnter): _SwallowRepeatIntent(),
        SingleActivator(LogicalKeyboardKey.space): _SwallowRepeatIntent(),
      };

  late final Map<Type, Action<Intent>> _actions = <Type, Action<Intent>>{
    ActivateIntent: _ActivateAction<ActivateIntent>(this),
    ButtonActivateIntent: _ActivateAction<ButtonActivateIntent>(this),
    _SwallowRepeatIntent: DoNothingAction(),
  };

  @override
  void initState() {
    super.initState();
    if (widget.focusNode == null) {
      _ownedNode = FocusNode(debugLabel: 'CarbonInteraction');
    }
    // Focus is read from the node itself rather than from the detector's
    // onFocusChange, which caches the last value and so misses a swap to a
    // node that takes focus while the old one held it.
    _node.addListener(_handleNodeChange);
    _focused = _node.hasFocus;
    _reportedFocus = _focused;
    _highlightTraditional = _isTraditional(FocusManager.instance.highlightMode);
    FocusManager.instance.addHighlightModeListener(_handleHighlightMode);
  }

  @override
  void didUpdateWidget(CarbonInteraction oldWidget) {
    super.didUpdateWidget(oldWidget);
    final oldNode = oldWidget.focusNode ?? _ownedNode!;
    // The owned node lives as long as the state, so switching to a supplied
    // node and back never disposes a node the Focus widget still holds.
    if (widget.focusNode == null && _ownedNode == null) {
      _ownedNode = FocusNode(debugLabel: 'CarbonInteraction');
    }
    if (!identical(oldNode, _node)) {
      oldNode.removeListener(_handleNodeChange);
      _node.addListener(_handleNodeChange);
      if (_focused != _node.hasFocus) {
        _focused = _node.hasFocus;
        _reportAfterFrame();
      }
    }
    if (!widget.enabled) {
      _pressed = false;
      if (_hovered) {
        _hovered = false;
        _reportAfterFrame();
      }
    }
    if (widget.enabled != oldWidget.enabled) {
      for (final action
          in _actions.values.whereType<_ActivateAction<Intent>>()) {
        action.notifyEnabledChanged();
      }
    }
  }

  @override
  void dispose() {
    FocusManager.instance.removeHighlightModeListener(_handleHighlightMode);
    _node.removeListener(_handleNodeChange);
    _ownedNode?.dispose();
    super.dispose();
  }

  static bool _isTraditional(FocusHighlightMode mode) =>
      mode == FocusHighlightMode.traditional;

  // Host callbacks may call setState on ancestors, which the framework
  // forbids while this subtree is building.
  void _reportAfterFrame() {
    SchedulerBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      _reportHover();
      _reportFocus();
    });
  }

  void _reportHover() {
    if (_reportedHover == _hovered) return;
    _reportedHover = _hovered;
    widget.onHoverChange?.call(_hovered);
  }

  void _reportFocus() {
    if (_reportedFocus == _focused) return;
    _reportedFocus = _focused;
    widget.onFocusChange?.call(_focused);
  }

  void _handleNodeChange() {
    final focused = _node.hasFocus;
    if (_focused == focused) return;
    setState(() => _focused = focused);
    _reportFocus();
  }

  void _handleHighlightMode(FocusHighlightMode mode) {
    final traditional = _isTraditional(mode);
    if (!mounted || _highlightTraditional == traditional) return;
    setState(() => _highlightTraditional = traditional);
  }

  void _activate() {
    if (!widget.enabled) return;
    widget.onPressed!();
  }

  void _setPressed(bool value) {
    if (_pressed == value || !mounted) return;
    setState(() => _pressed = value);
  }

  void _handleHover(bool value) {
    if (!widget.enabled) value = false;
    if (_hovered == value) return;
    setState(() => _hovered = value);
    _reportHover();
  }

  // Pointer taps and screen-reader taps both come here, so a popup trigger
  // takes focus either way and focus can return to it when the popup closes.
  void _handleTap() {
    _setPressed(false);
    if (!widget.enabled) return;
    if (widget.requestFocusOnTap && _node.canRequestFocus) {
      _node.requestFocus();
    }
    _activate();
  }

  @override
  Widget build(BuildContext context) {
    final enabled = widget.enabled;
    final state = CarbonInteractionState(
      hovered: enabled && _hovered,
      pressed: enabled && _pressed,
      focused: _focused,
      focusVisible: _focused && _highlightTraditional,
      enabled: enabled,
    );
    // Excluded below the focus detector so its focusable and focused flags
    // still merge into this control's node.
    final visual = widget.builder(context, state, widget.child);
    final cursor =
        widget.mouseCursor ??
        (enabled ? SystemMouseCursors.click : SystemMouseCursors.basic);

    // Shortcuts and actions sit outside FocusableActionDetector, which would
    // otherwise add and remove its Shortcuts wrapper whenever enabled flips,
    // reparenting the subtree out from under a Focus scope it depends on.
    return Semantics(
      container: true,
      button: widget.button ? true : null,
      role: widget.role,
      enabled: enabled,
      label: widget.label,
      hint: widget.hint,
      value: widget.value,
      tooltip: widget.tooltip,
      selected: widget.selected,
      checked: widget.mixed ? false : widget.checked,
      mixed: widget.mixed ? true : null,
      toggled: widget.toggled,
      expanded: widget.expanded,
      inMutuallyExclusiveGroup: widget.inMutuallyExclusiveGroup,
      onTap: enabled ? _handleTap : null,
      onLongPress: enabled ? widget.onLongPress : null,
      child: Shortcuts(
        shortcuts: _shortcuts,
        // Its focusable:false node would merge into this control's node and
        // mask the detector's focusable flag.
        includeSemantics: false,
        child: Actions(
          actions: _actions,
          child: FocusableActionDetector(
            enabled: enabled || widget.focusableWhenDisabled,
            focusNode: _node,
            autofocus: widget.autofocus,
            mouseCursor: cursor,
            // Tracked here rather than through the detector's hover
            // highlight, which only reports in keyboard highlight mode.
            child: MouseRegion(
              onEnter: (_) => _handleHover(true),
              onExit: (_) => _handleHover(false),
              child: GestureDetector(
                behavior: widget.hitTestBehavior,
                excludeFromSemantics: true,
                onTapDown: enabled ? (_) => _setPressed(true) : null,
                onTapCancel: enabled ? () => _setPressed(false) : null,
                onTap: enabled ? _handleTap : null,
                onLongPress: enabled && widget.onLongPress != null
                    ? () {
                        _setPressed(false);
                        widget.onLongPress!();
                      }
                    : null,
                onSecondaryTap: enabled ? widget.onSecondaryTap : null,
                child: widget.excludeChildSemantics
                    ? ExcludeSemantics(child: visual)
                    : visual,
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _SwallowRepeatIntent extends Intent {
  const _SwallowRepeatIntent();
}

// An action that reports disabled while the control is disabled, so a
// focusable-while-disabled control lets Enter and Space fall through to
// ancestors instead of swallowing them.
class _ActivateAction<T extends Intent> extends Action<T> {
  _ActivateAction(this._owner);

  final _CarbonInteractionState _owner;

  @override
  bool isEnabled(T intent) => _owner.widget.enabled;

  void notifyEnabledChanged() => notifyActionListeners();

  @override
  Object? invoke(T intent) {
    _owner._activate();
    return null;
  }
}
