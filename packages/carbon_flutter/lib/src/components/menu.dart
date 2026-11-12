import 'dart:math' as math;

import 'package:flutter/gestures.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

import '../foundations/icons.dart';
import '../foundations/localizations.dart';
import '../foundations/theme.dart';
import '../foundations/tokens.dart';
import '../primitives/focus_ring.dart';
import '../primitives/interaction.dart';
import '../primitives/option.dart';
import '../primitives/popup.dart';

/// One row, group or rule in a [CarbonMenu].
///
/// The host owns every value: checked state and the selected radio value are
/// read from the entries and changes come back through callbacks, so the menu
/// never keeps a selection of its own.
@immutable
sealed class CarbonMenuEntry {
  const CarbonMenuEntry();

  void _flatten(List<_Flat> out);
}

/// The treatment of a [CarbonMenuItem].
enum CarbonMenuItemKind {
  /// An ordinary command.
  standard,

  /// A destructive command. It reads as an ordinary row until hover or
  /// keyboard focus fills it with the danger role, as Carbon does.
  danger,
}

/// A command. A null [onPressed] disables it: it is skipped by keyboard
/// traversal and does nothing when tapped.
class CarbonMenuItem extends CarbonMenuEntry {
  const CarbonMenuItem({
    required this.label,
    this.onPressed,
    this.icon,
    this.shortcut,
    this.kind = CarbonMenuItemKind.standard,
  });

  final String label;

  /// Called once, after the whole menu tree has closed and focus has returned
  /// to the trigger, so it may push a route.
  final VoidCallback? onPressed;

  /// A leading glyph, typically a `CarbonIcon`.
  final Widget? icon;

  /// A hint such as `Ctrl+C`. Display only: the menu does not bind it.
  final String? shortcut;

  final CarbonMenuItemKind kind;

  @override
  void _flatten(List<_Flat> out) => out.add(
    _Flat(
      kind: _FlatKind.item,
      label: label,
      icon: icon,
      shortcut: shortcut,
      danger: kind == CarbonMenuItemKind.danger,
      enabled: onPressed != null,
      activate: onPressed,
    ),
  );
}

/// An item that toggles one setting, announced as a checked menu item. Null
/// [onChanged] disables it.
class CarbonMenuCheckItem extends CarbonMenuEntry {
  const CarbonMenuCheckItem({
    required this.label,
    required this.checked,
    this.onChanged,
    this.icon,
    this.shortcut,
  });

  final String label;
  final bool checked;

  /// Receives the requested new value.
  final ValueChanged<bool>? onChanged;
  final Widget? icon;
  final String? shortcut;

  @override
  void _flatten(List<_Flat> out) {
    final changed = onChanged;
    out.add(
      _Flat(
        kind: _FlatKind.item,
        label: label,
        icon: icon,
        shortcut: shortcut,
        enabled: changed != null,
        checked: checked,
        toggle: true,
        activate: changed == null ? null : () => changed(!checked),
      ),
    );
  }
}

/// A mutually exclusive choice, announced as radio menu items under an
/// optional heading. Null [onChanged] disables the whole group.
class CarbonMenuRadioGroup<T> extends CarbonMenuEntry {
  const CarbonMenuRadioGroup({
    required this.value,
    required this.options,
    this.onChanged,
    this.label,
  });

  /// The selected option's value, or null for none.
  final T? value;
  final List<CarbonOption<T>> options;

  /// Receives the chosen option's value. Not called for the option that is
  /// already selected.
  final ValueChanged<T>? onChanged;

  /// A heading shown above the options.
  final String? label;

  @override
  void _flatten(List<_Flat> out) {
    final heading = label;
    if (heading != null) out.add(_Flat.header(heading));
    final changed = onChanged;
    for (final option in options) {
      final selected = option.value == value;
      out.add(
        _Flat(
          kind: _FlatKind.item,
          label: option.label,
          icon: option.icon,
          enabled: changed != null && option.enabled,
          checked: selected,
          radio: true,
          toggle: true,
          activate: changed == null || selected
              ? (changed == null ? null : _noop)
              : () => changed(option.value),
        ),
      );
    }
  }
}

void _noop() {}

/// Entries under an optional heading. A group adds no rule of its own; place a
/// [CarbonMenuDivider] where one is wanted.
class CarbonMenuGroup extends CarbonMenuEntry {
  const CarbonMenuGroup({this.label, required this.children});

  final String? label;
  final List<CarbonMenuEntry> children;

  @override
  void _flatten(List<_Flat> out) {
    final heading = label;
    if (heading != null) out.add(_Flat.header(heading));
    for (final child in children) {
      child._flatten(out);
    }
  }
}

/// A 1px rule between entries.
class CarbonMenuDivider extends CarbonMenuEntry {
  const CarbonMenuDivider();

  @override
  void _flatten(List<_Flat> out) => out.add(const _Flat.divider());
}

/// An item that opens a nested menu. Tap, Enter, Space or the forward arrow
/// opens it and moves focus to its first item; the back arrow or Escape
/// closes it and returns focus to this item. Hover is never required.
class CarbonMenuSubmenu extends CarbonMenuEntry {
  const CarbonMenuSubmenu({
    required this.label,
    required this.entries,
    this.icon,
    this.enabled = true,
  });

  final String label;
  final List<CarbonMenuEntry> entries;
  final Widget? icon;
  final bool enabled;

  @override
  void _flatten(List<_Flat> out) => out.add(
    _Flat(
      kind: _FlatKind.submenu,
      label: label,
      icon: icon,
      enabled: enabled,
      children: entries,
    ),
  );
}

enum _FlatKind { header, divider, item, submenu }

@immutable
class _Flat {
  const _Flat({
    required this.kind,
    this.label = '',
    this.icon,
    this.shortcut,
    this.danger = false,
    this.enabled = true,
    this.checked,
    this.radio = false,
    this.toggle = false,
    this.activate,
    this.children = const <CarbonMenuEntry>[],
  });

  const _Flat.header(this.label)
    : kind = _FlatKind.header,
      icon = null,
      shortcut = null,
      danger = false,
      enabled = false,
      checked = null,
      radio = false,
      toggle = false,
      activate = null,
      children = const <CarbonMenuEntry>[];

  const _Flat.divider()
    : kind = _FlatKind.divider,
      label = '',
      icon = null,
      shortcut = null,
      danger = false,
      enabled = false,
      checked = null,
      radio = false,
      toggle = false,
      activate = null,
      children = const <CarbonMenuEntry>[];

  final _FlatKind kind;
  final String label;
  final Widget? icon;
  final String? shortcut;
  final bool danger;
  final bool enabled;
  final bool? checked;
  final bool radio;

  /// Checkable rows may keep the menu open; plain commands always close it.
  final bool toggle;
  final VoidCallback? activate;
  final List<CarbonMenuEntry> children;

  bool get focusable => (kind == _FlatKind.item || kind == _FlatKind.submenu) && enabled;
}

List<_Flat> _flatten(List<CarbonMenuEntry> entries) {
  final out = <_Flat>[];
  for (final entry in entries) {
    entry._flatten(out);
  }
  return out;
}

// What every panel of one menu tree shares: where outside taps are judged and
// how an activation closes the tree before it calls the host.
class _MenuHost {
  _MenuHost(this.root, this.tapGroup);

  final CarbonPopupController root;
  final Object tapGroup;
  bool closeOnToggle = true;
  double minWidth = 160;
  double maxWidth = 320;

  void closeAll() => root.close();

  void activate(_Flat flat) {
    final callback = flat.activate;
    if (flat.toggle && !closeOnToggle) {
      callback?.call();
      return;
    }
    // Closing first returns focus to the trigger, so a callback that pushes a
    // dialog leaves the trigger as that dialog's focus-restore target.
    closeAll();
    FocusManager.instance.applyFocusChangesIfNeeded();
    callback?.call();
  }
}

/// A collection of commands in an anchored popup.
///
/// [child] is the anchor, usually the trigger; drive the menu through
/// [controller]. Use `CarbonMenuButton`, `CarbonOverflowMenu` or
/// `CarbonSplitButton` for the usual triggers, and [CarbonContextMenu] for a
/// menu at a pointer position.
///
/// Keyboard, within the open menu only (nothing outside it is intercepted):
/// Up and Down move with wrap-around and skip disabled items, Home and End
/// jump, Enter and Space activate, the forward arrow (Right in LTR, Left in
/// RTL) opens a submenu and focuses its first item, the back arrow or Escape
/// closes the submenu and returns focus to its parent item, Escape on the
/// root closes the menu and restores focus to the trigger, Tab closes the
/// menu and moves on to the control after the trigger (Shift+Tab, the one
/// before it), and typing letters jumps to a matching item; repeating a
/// letter cycles through the items it starts.
///
/// Activating an item closes the whole tree first, then calls its callback.
/// Submenus belong to their menu: they close with it. Checkable items close
/// the menu too unless [closeOnToggle] is false, in which case the host must
/// rebuild with the new values.
///
/// Touch density gives rows a [CarbonThemeData.touchTarget] minimum; compact gives 32px. Rows grow with
/// text rather than clip.
class CarbonMenu extends StatefulWidget {
  const CarbonMenu({
    super.key,
    required this.controller,
    required this.entries,
    required this.child,
    this.alignment = CarbonPopupAlignment.start,
    this.minWidth = 160,
    this.maxWidth = 320,
    this.gap = 0,
    this.closeOnToggle = true,
    this.restoreFocus,
    this.onDismissed,
    this.semanticLabel,
    this.semanticIdentifier,
  });

  final CarbonPopupController controller;
  final List<CarbonMenuEntry> entries;

  /// The anchor. Pointer taps on it count as inside the menu.
  final Widget child;
  final CarbonPopupAlignment alignment;
  final double minWidth;
  final double maxWidth;
  final double gap;
  final bool closeOnToggle;

  /// Where focus returns when the menu closes with focus inside it. Defaults
  /// to whatever held focus when the menu opened.
  final FocusNode? restoreFocus;

  /// Called when the menu closed itself (outside tap, Escape, back, anchor
  /// lost), not for [CarbonPopupController.close] or an activation.
  final ValueChanged<CarbonPopupDismissReason>? onDismissed;

  /// Overrides the localized "Menu" name announced for the menu.
  final String? semanticLabel;

  /// An identifier for the menu's semantics node, so a trigger can name it in
  /// its controlled nodes.
  final String? semanticIdentifier;

  @override
  State<CarbonMenu> createState() => _CarbonMenuState();
}

class _CarbonMenuState extends State<CarbonMenu> {
  late _MenuHost _host = _MenuHost(widget.controller, this);

  @override
  void didUpdateWidget(CarbonMenu oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(oldWidget.controller, widget.controller)) {
      _host = _MenuHost(widget.controller, this);
    }
  }

  void _outsideTap() {
    if (widget.controller.isOpen) {
      widget.controller.close();
      widget.onDismissed?.call(CarbonPopupDismissReason.outsideTap);
    }
  }

  @override
  Widget build(BuildContext context) {
    _host.closeOnToggle = widget.closeOnToggle;
    _host.minWidth = widget.minWidth;
    _host.maxWidth = widget.maxWidth;
    final host = _host;
    // Outside taps are judged here rather than by the popup because a submenu
    // is a second popup: a tap inside it is outside the root popup's own
    // region, and would close the whole tree.
    return TapRegion(
      groupId: host.tapGroup,
      onTapOutside: (_) => _outsideTap(),
      child: CarbonAnchoredPopup(
        controller: widget.controller,
        alignment: widget.alignment,
        minWidth: widget.minWidth,
        maxWidth: widget.maxWidth,
        gap: widget.gap,
        raiseLayer: false,
        dismissOnOutsideTap: false,
        restoreFocus: widget.restoreFocus,
        onDismissed: widget.onDismissed,
        popupBuilder: (context, available) => TapRegion(
          groupId: host.tapGroup,
          child: _MenuPanel(
            entries: widget.entries,
            host: host,
            semanticLabel: widget.semanticLabel,
            semanticIdentifier: widget.semanticIdentifier,
          ),
        ),
        child: widget.child,
      ),
    );
  }
}

class _MenuPanel extends StatefulWidget {
  const _MenuPanel({
    required this.entries,
    required this.host,
    this.semanticLabel,
    this.semanticIdentifier,
    this.closeSelf,
  });

  final List<CarbonMenuEntry> entries;
  final _MenuHost host;
  final String? semanticLabel;
  final String? semanticIdentifier;

  /// Closes this panel alone; set on submenus.
  final VoidCallback? closeSelf;

  @override
  State<_MenuPanel> createState() => _MenuPanelState();
}

class _MenuPanelState extends State<_MenuPanel> {
  // Keyed by row identity, not position, so focus and open submenus stay with
  // their item when the host's entries change while the menu is open.
  final Map<String, FocusNode> _nodes = <String, FocusNode>{};
  final Map<String, CarbonPopupController> _subs =
      <String, CarbonPopupController>{};
  final Set<String> _flipped = <String>{};
  final ScrollController _scroll = ScrollController();
  final GlobalKey _viewportKey = GlobalKey();
  List<_Flat> _flat = const <_Flat>[];
  List<String> _ids = const <String>[];
  String _typed = '';
  Duration _lastTyped = Duration.zero;

  static const Duration _typeaheadWindow = Duration(milliseconds: 700);

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final first = _flat.indexWhere((e) => e.focusable);
      if (first >= 0) _nodes[_ids[first]]?.requestFocus();
    });
  }

  @override
  void dispose() {
    for (final node in _nodes.values) {
      node.dispose();
    }
    for (final controller in _subs.values) {
      controller.dispose();
    }
    _scroll.dispose();
    super.dispose();
  }

  FocusNode _node(int index) => _nodes.putIfAbsent(
    _ids[index],
    () => FocusNode(debugLabel: 'CarbonMenu item ${_ids[index]}'),
  );

  CarbonPopupController _sub(int index) =>
      _subs.putIfAbsent(_ids[index], CarbonPopupController.new);

  // Rows that left the list are disposed after the frame, once the widgets
  // that held their nodes have been rebuilt without them.
  void _trim() {
    final live = _ids.toSet();
    final stale = <String>{
      ..._nodes.keys.where((id) => !live.contains(id)),
      ..._subs.keys.where((id) => !live.contains(id)),
    };
    if (stale.isEmpty) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final current = _ids.toSet();
      for (final id in stale) {
        if (current.contains(id)) continue;
        _nodes.remove(id)?.dispose();
        _subs.remove(id)?.dispose();
        _flipped.remove(id);
      }
    });
  }

  // A label plus its occurrence among same-labelled rows of the same kind.
  static List<String> _identify(List<_Flat> flat) {
    final seen = <String, int>{};
    return <String>[
      for (final row in flat)
        () {
          final base = '${row.kind.name}|${row.label}';
          final n = seen.update(base, (v) => v + 1, ifAbsent: () => 0);
          return '$base#$n';
        }(),
    ];
  }

  int get _focusedIndex {
    for (var i = 0; i < _flat.length; i++) {
      if (_nodes[_ids[i]]?.hasPrimaryFocus ?? false) return i;
    }
    return -1;
  }

  List<int> get _focusable => <int>[
    for (var i = 0; i < _flat.length; i++)
      if (_flat[i].focusable) i,
  ];

  void _closeSubmenus({int? except}) {
    final keep = except == null ? null : _ids[except];
    for (final entry in _subs.entries) {
      if (entry.key != keep) entry.value.close();
    }
  }

  void _focusRow(int index) {
    _closeSubmenus();
    final node = _nodes[_ids[index]];
    if (node == null) return;
    node.requestFocus();
    _reveal(node);
  }

  void _reveal(FocusNode node) {
    final box = node.context?.findRenderObject();
    final viewport = _viewportKey.currentContext?.findRenderObject();
    if (box is! RenderBox ||
        viewport is! RenderBox ||
        !box.attached ||
        !_scroll.hasClients) {
      return;
    }
    final top = box.localToGlobal(Offset.zero, ancestor: viewport).dy;
    final bottom = top + box.size.height;
    final position = _scroll.position;
    if (top < 0) {
      position.jumpTo(
        (position.pixels + top).clamp(0.0, position.maxScrollExtent),
      );
    } else if (bottom > viewport.size.height) {
      position.jumpTo(
        (position.pixels + bottom - viewport.size.height).clamp(
          0.0,
          position.maxScrollExtent,
        ),
      );
    }
  }

  void _move(int delta) {
    final order = _focusable;
    if (order.isEmpty) return;
    final current = order.indexOf(_focusedIndex);
    final int next;
    if (current < 0) {
      next = delta > 0 ? 0 : order.length - 1;
    } else {
      next = (current + delta) % order.length;
    }
    _focusRow(order[next]);
  }

  void _openSubmenu(int index, {bool toggle = false}) {
    final controller = _sub(index);
    if (controller.isOpen) {
      if (toggle) controller.close();
      return;
    }
    _closeSubmenus(except: index);
    if (_opensTowardLeadingEdge(index)) {
      _flipped.add(_ids[index]);
    } else {
      _flipped.remove(_ids[index]);
    }
    controller.open();
  }

  // The popup primitive only clamps horizontally, so a submenu without room on
  // the trailing side would land on top of its parent. The submenu's width is
  // unknown until it is laid out; the parent's is the best proxy for it.
  bool _opensTowardLeadingEdge(int index) {
    final box = _nodes[_ids[index]]?.context?.findRenderObject();
    if (box is! RenderBox || !box.attached || !box.hasSize) return false;
    final rect = box.localToGlobal(Offset.zero) & box.size;
    final screen = MediaQuery.sizeOf(context).width;
    final rtl = Directionality.of(context) == TextDirection.rtl;
    final trailing = rtl ? rect.left : screen - rect.right;
    final leading = rtl ? screen - rect.right : rect.left;
    final needed = math.max(widget.host.minWidth, rect.width);
    return trailing < needed && leading > trailing;
  }

  int get _openSubmenuIndex {
    for (var i = 0; i < _flat.length; i++) {
      if (_subs[_ids[i]]?.isOpen ?? false) return i;
    }
    return -1;
  }

  KeyEventResult _onKey(FocusNode node, KeyEvent event) {
    if (event is KeyUpEvent) return KeyEventResult.ignored;
    final key = event.logicalKey;
    final isDown = event is KeyDownEvent;
    final rtl = Directionality.of(context) == TextDirection.rtl;
    final forward = rtl ? LogicalKeyboardKey.arrowLeft : LogicalKeyboardKey.arrowRight;
    final backward = rtl ? LogicalKeyboardKey.arrowRight : LogicalKeyboardKey.arrowLeft;

    if (key == LogicalKeyboardKey.arrowDown) {
      _move(1);
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.arrowUp) {
      _move(-1);
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.home || key == LogicalKeyboardKey.end) {
      final order = _focusable;
      if (order.isNotEmpty) {
        _focusRow(key == LogicalKeyboardKey.home ? order.first : order.last);
      }
      return KeyEventResult.handled;
    }
    if (key == forward) {
      final index = _focusedIndex;
      if (isDown && index >= 0 && _flat[index].kind == _FlatKind.submenu) {
        _openSubmenu(index);
      }
      return KeyEventResult.handled;
    }
    if (key == backward) {
      if (isDown) widget.closeSelf?.call();
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.escape && isDown) {
      final open = _openSubmenuIndex;
      if (open >= 0) {
        // Focus is on the parent row here; a submenu holding focus has already
        // handled Escape itself.
        _subs[_ids[open]]!.close();
        _nodes[_ids[open]]?.requestFocus();
        return KeyEventResult.handled;
      }
      return KeyEventResult.ignored;
    }
    if (key == LogicalKeyboardKey.tab) {
      if (!isDown) return KeyEventResult.handled;
      final backwards = HardwareKeyboard.instance.isShiftPressed;
      widget.host.closeAll();
      FocusManager.instance.applyFocusChangesIfNeeded();
      // Traversal has to wait for the overlay to unmount: while its rows are
      // still in the tree the next stop after the trigger is usually one of
      // them.
      WidgetsBinding.instance.addPostFrameCallback((_) {
        final focus = FocusManager.instance.primaryFocus;
        if (backwards) {
          focus?.previousFocus();
        } else {
          focus?.nextFocus();
        }
      });
      return KeyEventResult.handled;
    }
    return _typeahead(event);
  }

  KeyEventResult _typeahead(KeyEvent event) {
    final keyboard = HardwareKeyboard.instance;
    final character = event.character;
    if (character == null ||
        character.trim().isEmpty ||
        keyboard.isControlPressed ||
        keyboard.isAltPressed ||
        keyboard.isMetaPressed) {
      return KeyEventResult.ignored;
    }
    if (event.timeStamp - _lastTyped > _typeaheadWindow) _typed = '';
    _lastTyped = event.timeStamp;
    _typed += character.toLowerCase();
    final order = _focusable;
    if (order.isEmpty) return KeyEventResult.handled;
    final current = order.indexOf(_focusedIndex);
    // The same letter repeated, typed or held, cycles through its matches
    // instead of growing a prefix nothing matches.
    final repeated = _typed.split('').every((c) => c == _typed[0]);
    final prefix = repeated ? _typed[0] : _typed;
    final start = repeated ? current + 1 : math.max(current, 0);
    for (var step = 0; step < order.length; step++) {
      final index = order[(start + step) % order.length];
      if (_flat[index].label.toLowerCase().startsWith(prefix)) {
        _focusRow(index);
        break;
      }
    }
    return KeyEventResult.handled;
  }

  @override
  Widget build(BuildContext context) {
    final theme = CarbonTheme.of(context);
    final loc = CarbonLocalizations.of(context);
    final level = CarbonLayer.of(context);
    _flat = _flatten(widget.entries);
    _ids = _identify(_flat);
    _trim();
    final hasCheck = _flat.any((e) => e.checked != null);
    final hasIcon = _flat.any((e) => e.icon != null);

    return Focus(
      canRequestFocus: false,
      skipTraversal: true,
      includeSemantics: false,
      onKeyEvent: _onKey,
      child: Semantics(
        container: true,
        explicitChildNodes: true,
        role: SemanticsRole.menu,
        label: widget.semanticLabel ?? loc.menu,
        identifier: widget.semanticIdentifier,
        child: DecoratedBox(
          decoration: BoxDecoration(
            color: theme.layer(level),
            border: Border.all(color: theme.borderSubtle(level)),
            boxShadow: <BoxShadow>[
              BoxShadow(
                color: theme.colors.shadow,
                blurRadius: 6,
                offset: const Offset(0, 2),
              ),
            ],
          ),
          child: SingleChildScrollView(
            key: _viewportKey,
            controller: _scroll,
            child: IntrinsicWidth(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: <Widget>[
                  for (var i = 0; i < _flat.length; i++)
                    _buildRow(context, theme, level, i, hasCheck, hasIcon),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildRow(
    BuildContext context,
    CarbonThemeData theme,
    int level,
    int index,
    bool hasCheck,
    bool hasIcon,
  ) {
    final flat = _flat[index];
    switch (flat.kind) {
      case _FlatKind.divider:
        return Padding(
          padding: const EdgeInsets.symmetric(vertical: CarbonSpacing.spacing02),
          child: SizedBox(
            height: CarbonBorders.hairline,
            child: ColoredBox(color: theme.borderSubtle(level)),
          ),
        );
      case _FlatKind.header:
        return Semantics(
          header: true,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(
              CarbonSpacing.spacing05,
              CarbonSpacing.spacing03,
              CarbonSpacing.spacing05,
              CarbonSpacing.spacing02,
            ),
            child: Text(
              flat.label,
              style: theme.typography.label.copyWith(
                color: theme.colors.textSecondary,
              ),
            ),
          ),
        );
      case _FlatKind.item:
        return _MenuRow(
          key: ValueKey<String>(_ids[index]),
          flat: flat,
          node: _node(index),
          hasCheck: hasCheck,
          hasIcon: hasIcon,
          onPressed: flat.enabled ? () => widget.host.activate(flat) : null,
          onFocused: () => _reveal(_node(index)),
        );
      case _FlatKind.submenu:
        final controller = _sub(index);
        final node = _node(index);
        final id = _ids[index];
        return ListenableBuilder(
          key: ValueKey<String>(_ids[index]),
          listenable: controller,
          builder: (context, _) {
            final flipped = _flipped.contains(id);
            return _MenuRow(
              flat: flat,
              node: node,
              hasCheck: hasCheck,
              hasIcon: hasIcon,
              submenuOpen: controller.isOpen,
              submenuFlipped: flipped,
              onPressed: flat.enabled
                  ? () => _openSubmenu(index, toggle: true)
                  : null,
              onFocused: () => _reveal(node),
              submenuAnchor: CarbonAnchoredPopup(
                controller: controller,
                gap: -1,
                minWidth: widget.host.minWidth,
                maxWidth: widget.host.maxWidth,
                alignment: flipped
                    ? CarbonPopupAlignment.end
                    : CarbonPopupAlignment.start,
                raiseLayer: false,
                dismissOnOutsideTap: false,
                dismissOnBack: false,
                restoreFocus: node,
                popupBuilder: (context, available) => TapRegion(
                  groupId: widget.host.tapGroup,
                  child: _MenuPanel(
                    entries: flat.children,
                    host: widget.host,
                    closeSelf: controller.close,
                  ),
                ),
                // A 1px box on the row's trailing edge (leading when flipped):
                // the popup opens beside the row, level with its top, rather
                // than below it.
                child: const SizedBox(width: 1, height: 1),
              ),
            );
          },
        );
    }
  }
}

class _MenuRow extends StatelessWidget {
  const _MenuRow({
    super.key,
    required this.flat,
    required this.node,
    required this.hasCheck,
    required this.hasIcon,
    required this.onPressed,
    required this.onFocused,
    this.submenuOpen = false,
    this.submenuFlipped = false,
    this.submenuAnchor,
  });

  final _Flat flat;
  final FocusNode node;
  final bool hasCheck;
  final bool hasIcon;
  final VoidCallback? onPressed;
  final VoidCallback onFocused;
  final bool submenuOpen;
  final bool submenuFlipped;
  final Widget? submenuAnchor;

  @override
  Widget build(BuildContext context) {
    final theme = CarbonTheme.of(context);
    final level = CarbonLayer.of(context);
    final isSubmenu = flat.kind == _FlatKind.submenu;
    final enabled = onPressed != null;

    final SemanticsRole role = flat.radio
        ? SemanticsRole.menuItemRadio
        : (flat.checked != null
              ? SemanticsRole.menuItemCheckbox
              : SemanticsRole.menuItem);

    final interaction = CarbonInteraction(
      focusNode: node,
      onPressed: onPressed,
      requestFocusOnTap: true,
      button: false,
      role: role,
      label: flat.label,
      hint: flat.shortcut,
      checked: flat.checked,
      inMutuallyExclusiveGroup: flat.radio ? true : null,
      expanded: isSubmenu ? submenuOpen : null,
      excludeChildSemantics: true,
      onFocusChange: (focused) {
        if (focused) onFocused();
      },
      builder: (context, state, _) {
        final colors = theme.colors;
        final danger = flat.danger && enabled;
        final filledDanger = danger && (state.hovered || state.focusVisible);
        final Color background;
        if (filledDanger) {
          background = colors.buttonDangerPrimary;
        } else if (state.pressed) {
          background = theme.layerActive(level);
        } else if (state.hovered || submenuOpen) {
          background = theme.layerHover(level);
        } else {
          background = const Color(0x00000000);
        }
        final emphasised = state.hovered || submenuOpen;
        final Color foreground = !enabled
            ? colors.textDisabled
            : filledDanger
            ? colors.textOnColor
            : emphasised
            ? colors.textPrimary
            : colors.textSecondary;
        final Color secondary = !enabled
            ? colors.textDisabled
            : filledDanger
            ? colors.textOnColor
            : colors.textSecondary;
        final Color iconColor = !enabled
            ? colors.iconDisabled
            : filledDanger
            ? colors.iconOnColor
            : emphasised
            ? colors.iconPrimary
            : colors.iconSecondary;
        final style = theme.typography.control;
        final iconSize = theme.iconSize;

        Widget slot(Widget? child) => SizedBox(
          width: iconSize,
          height: iconSize,
          child: child == null
              ? null
              : IconTheme(
                  data: IconThemeData(color: iconColor, size: iconSize),
                  child: child,
                ),
        );

        return CarbonFocusRing(
          visible: state.focusVisible,
          onColor: filledDanger,
          child: ColoredBox(
            color: background,
            child: ConstrainedBox(
              constraints: BoxConstraints(minHeight: theme.controlHeight),
              child: Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: CarbonSpacing.spacing05,
                  vertical: CarbonSpacing.spacing02,
                ),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.center,
                  children: <Widget>[
                    if (hasCheck) ...<Widget>[
                      slot(
                        flat.checked == true
                            ? const CarbonIcon(CarbonIcons.checkmark)
                            : null,
                      ),
                      const SizedBox(width: CarbonSpacing.spacing03),
                    ],
                    if (hasIcon) ...<Widget>[
                      slot(flat.icon),
                      const SizedBox(width: CarbonSpacing.spacing03),
                    ],
                    Expanded(
                      child: Text(
                        flat.label,
                        style: style.copyWith(color: foreground),
                      ),
                    ),
                    if (flat.shortcut != null) ...<Widget>[
                      const SizedBox(width: CarbonSpacing.spacing06),
                      Flexible(
                        child: Text(
                          flat.shortcut!,
                          style: style.copyWith(color: secondary),
                        ),
                      ),
                    ],
                    if (isSubmenu) ...<Widget>[
                      const SizedBox(width: CarbonSpacing.spacing05),
                      slot(const CarbonIcon(CarbonIcons.chevronRight)),
                    ],
                  ],
                ),
              ),
            ),
          ),
        );
      },
    );

    final anchor = submenuAnchor;
    if (anchor == null) return interaction;
    return Stack(
      fit: StackFit.passthrough,
      children: <Widget>[
        interaction,
        PositionedDirectional(
          start: submenuFlipped ? 0 : null,
          end: submenuFlipped ? null : 0,
          top: 0,
          width: 1,
          height: 1,
          child: anchor,
        ),
      ],
    );
  }
}

/// A [CarbonMenu] that opens where the user right-clicks or long-presses
/// [child], as a context menu does.
///
/// Right-click is read from the raw pointer, so it works even over a child
/// that handles its own taps. Long press is recognized for touch and stylus
/// only, and competes with child gesture recognizers in the usual way: a child
/// with its own long-press handler wins. While focus is inside [child], the
/// Menu key or Shift+F10 opens the menu beside the focused widget.
class CarbonContextMenu extends StatefulWidget {
  const CarbonContextMenu({
    super.key,
    required this.entries,
    required this.child,
    this.enabled = true,
    this.onDismissed,
    this.semanticLabel,
  });

  final List<CarbonMenuEntry> entries;
  final Widget child;

  /// When false no gesture opens the menu, and an open one closes.
  final bool enabled;
  final ValueChanged<CarbonPopupDismissReason>? onDismissed;
  final String? semanticLabel;

  @override
  State<CarbonContextMenu> createState() => _CarbonContextMenuState();
}

class _CarbonContextMenuState extends State<CarbonContextMenu> {
  final CarbonPopupController _controller = CarbonPopupController();
  Offset _position = Offset.zero;

  @override
  void didUpdateWidget(CarbonContextMenu oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!widget.enabled && _controller.isOpen) _controller.close();
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _openAt(Offset local) {
    if (!widget.enabled) return;
    setState(() => _position = local);
    // The pointer-down that opens the menu also reaches the outside-tap
    // handler of a menu that is already open; opening after the frame lets
    // that close land first so a second right-click reopens at the new spot.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && widget.enabled && !_controller.isOpen) {
        _controller.open();
      }
    });
    WidgetsBinding.instance.ensureVisualUpdate();
  }

  // Keyboard users have no pointer position, so the menu opens at the bottom
  // start of whatever holds focus inside the region.
  void _openAtFocus() {
    final box = context.findRenderObject();
    if (box is! RenderBox || !box.attached) return;
    var local = Offset.zero;
    final focusBox = FocusManager.instance.primaryFocus?.context
        ?.findRenderObject();
    if (focusBox is RenderBox && focusBox.attached && focusBox.hasSize) {
      final rtl = Directionality.of(context) == TextDirection.rtl;
      final corner = rtl
          ? focusBox.size.bottomRight(Offset.zero)
          : focusBox.size.bottomLeft(Offset.zero);
      local = box.globalToLocal(focusBox.localToGlobal(corner));
    }
    _openAt(local);
  }

  @override
  Widget build(BuildContext context) {
    return Listener(
      behavior: HitTestBehavior.translucent,
      onPointerDown: (event) {
        if (event.kind == PointerDeviceKind.mouse &&
            event.buttons == kSecondaryMouseButton) {
          _openAt(event.localPosition);
        }
      },
      child: RawGestureDetector(
        behavior: HitTestBehavior.translucent,
        gestures: <Type, GestureRecognizerFactory>{
          LongPressGestureRecognizer:
              GestureRecognizerFactoryWithHandlers<LongPressGestureRecognizer>(
                () => LongPressGestureRecognizer(
                  supportedDevices: const <PointerDeviceKind>{
                    PointerDeviceKind.touch,
                    PointerDeviceKind.stylus,
                  },
                ),
                (recognizer) => recognizer.onLongPressStart = (details) =>
                    _openAt(details.localPosition),
              ),
        },
        child: Stack(
          fit: StackFit.passthrough,
          clipBehavior: Clip.none,
          children: <Widget>[
            CallbackShortcuts(
              bindings: <ShortcutActivator, VoidCallback>{
                const SingleActivator(LogicalKeyboardKey.contextMenu):
                    _openAtFocus,
                const SingleActivator(LogicalKeyboardKey.f10, shift: true):
                    _openAtFocus,
              },
              child: widget.child,
            ),
            Positioned(
              left: _position.dx,
              top: _position.dy,
              width: 1,
              height: 1,
              child: CarbonMenu(
                controller: _controller,
                entries: widget.entries,
                gap: -1,
                onDismissed: widget.onDismissed,
                semanticLabel: widget.semanticLabel,
                child: const SizedBox(width: 1, height: 1),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
