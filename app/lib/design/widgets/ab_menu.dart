import 'dart:ui' show ImageFilter, lerpDouble;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../ab_colors.dart';
import '../ab_tokens.dart';
import '../widgets/ab_chip.dart';
import '../widgets/ab_icon.dart';
import '../widgets/ab_snack_bar.dart';
import '../widgets/ab_tooltip.dart';

abstract class AbMenuEntry {
  const AbMenuEntry();
}

class AbMenuItem extends AbMenuEntry {
  const AbMenuItem({
    this.key,
    required this.label,
    this.onTap,
    this.value,
    this.icon,
    this.shortcut,
    this.danger = false,
    this.badge,
    this.badgeColor,
    this.enabled = true,
    this.disabledReason,
  }) : assert(
         onTap != null || value != null,
         'AbMenuItem needs onTap (inline action) or value (returned by showAbMenu)',
       );

  /// Key applied to the rendered row — the only handle a caller has on an
  /// entry that is data, not a widget.
  final Key? key;

  final String label;
  final String? icon;
  final String? shortcut;
  final bool danger;

  /// Trailing system chip (e.g. `ALPHA`) qualifying the row's maturity or
  /// tier. Never the place for prose — it renders mono-uppercase and tiny.
  final String? badge;

  final Color? badgeColor;

  /// False greys the row and blocks selection. The row still hit-tests so
  /// [disabledReason] can surface (tooltip + snack bar) — a greyed option
  /// raises the more urgent question of WHY, same contract as `AbSegmented`.
  final bool enabled;

  final String? disabledReason;

  /// Inline tap handler. Used when the menu is rendered directly (no
  /// [showAbMenu] route). Optional when [value] is provided — the
  /// helper will pop the route with [value] instead.
  final VoidCallback? onTap;

  /// Value returned by [showAbMenu] when this item is selected. Lets
  /// callers `await` the helper and `switch` on the result, mirroring
  /// the ergonomics of Material's `showMenu`/`PopupMenuButton`.
  final Object? value;
}

class AbMenuDivider extends AbMenuEntry {
  const AbMenuDivider();
}

class AbMenu extends StatelessWidget {
  const AbMenu({super.key, required this.items, this.header, this.width = 240});

  final String? header;
  final List<AbMenuEntry> items;
  final double width;

  @override
  Widget build(BuildContext context) {
    final p = context.antgrid;
    // First non-divider item gets `autofocus: true` so keyboard users
    // land on an interactive row immediately when the menu opens.
    var didAutofocus = false;
    // `width` is the intended/target width — under the route's loose
    // viewport constraints the menu lays out exactly `width` wide, but
    // on narrow displays (split-screen, foldables) it shrinks to fit
    // rather than overflowing the viewport. Item labels are inside an
    // Expanded → ellipsify on extreme squeeze instead of clipping the
    // whole surface off-screen.
    return Material(
      type: MaterialType.transparency,
      child: Container(
        constraints: BoxConstraints(maxWidth: width, minWidth: 0),
        padding: const EdgeInsets.all(5),
        decoration: _popupDecoration(p),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          mainAxisSize: MainAxisSize.min,
          children: [
            if (header != null)
              Padding(
                padding: const EdgeInsets.fromLTRB(10, 8, 10, 6),
                child: Text(
                  header!.toUpperCase(),
                  // Antgrid spec: menu header is mono — the slot is usually
                  // a session/branch/ref identifier ("SESSION · refactor-…").
                  style: AbTokens.monoStyle(
                    fontSize: AbTokens.fontXs,
                    letterSpacing: 0.66,
                    color: p.textMuted,
                  ),
                ),
              ),
            // `FocusTraversalGroup` keeps Tab/Shift-Tab cycling inside the
            // menu rather than escaping to the page beneath while the
            // popup route is on top.
            FocusTraversalGroup(
              policy: OrderedTraversalPolicy(),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                mainAxisSize: MainAxisSize.min,
                children: [
                  for (final entry in items)
                    if (entry is AbMenuDivider)
                      Container(
                        margin: const EdgeInsets.symmetric(
                          vertical: 4,
                          horizontal: 2,
                        ),
                        height: 1,
                        color: p.borderSubtle,
                      )
                    else if (entry is AbMenuItem)
                      Builder(
                        builder: (_) {
                          // Skip disabled rows: landing the keyboard on one that
                          // can only answer with its reason costs the user an
                          // arrow press before anything is pickable.
                          final autofocus = !didAutofocus && entry.enabled;
                          didAutofocus |= autofocus;
                          return _MenuItemTile(
                            key: entry.key,
                            item: entry,
                            autofocus: autofocus,
                          );
                        },
                      ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// How far a fully receded popup lets its ground through — see
/// [AbPopupSurface.quiet]. Kept above the point where the transcript underneath
/// starts competing with the popup's own labels for the eye.
const double _quietSurfaceAlpha = 0.84;

/// Blur applied behind a fully receded popup. Its job is to turn the text below
/// into ground rather than a second layer of figure; without it a translucent
/// popup over a live transcript is unreadable in both directions.
const double _quietBlurSigma = 10;

/// Antgrid `--elev-overlay`'s shadow colour. Named so the fade below scales the
/// alpha this already carries rather than restating it — a second literal there
/// silently shifts the shadow of every popup in the app the first time the two
/// disagree.
const Color _popupShadowColor = Color(0xB3000000);

/// Shared popup chrome for [AbMenu] and [showAbPanel]: raised surface,
/// strong border, contracted overlay shadow — one popup look across
/// menus and live-widget panels.
///
/// [quiet] recedes that chrome for a popup the user has not reached for yet;
/// 0 is the full popup and every caller but the workspace rail passes it.
BoxDecoration _popupDecoration(AbColors p, {double quiet = 0}) {
  return BoxDecoration(
    color: p.bgRaised.withValues(
      alpha: lerpDouble(1, _quietSurfaceAlpha, quiet),
    ),
    borderRadius: AbTokens.borderRadius8,
    // A receded popup drops to the ordinary 1px separator the rest of the app
    // divides with, which is what stops it reading as a raised thing at rest.
    border: Border.all(
      color: Color.lerp(p.borderStrong, p.borderDefault, quiet)!,
    ),
    // Antgrid `--elev-overlay`: a deep, contracted drop shadow
    // (negative spread = inset corners, lifted center) plus the
    // 1px borderStrong ring above. Without the negative spread the
    // shadow bleeds wide and reads "Material card" instead of "popup".
    // Dropped outright once fully receded rather than faded to transparent: a
    // transparent BoxShadow still costs its blur pass every frame.
    boxShadow: quiet >= 1
        ? null
        : [
            BoxShadow(
              color: _popupShadowColor.withValues(
                alpha: _popupShadowColor.a * (1 - quiet),
              ),
              blurRadius: 48,
              spreadRadius: -12,
              offset: const Offset(0, 24),
            ),
          ],
  );
}

/// [showAbPanel]'s chrome without its route — the popup surface as a plain
/// widget, for anchored popups that own their own overlay.
///
/// A [PopupRoute] closes on the first click outside it, which is right for a
/// menu you pick from and wrong for one the user pins open; those mount this in
/// an [OverlayPortal] instead and still read as the same popup.
class AbPopupSurface extends StatelessWidget {
  const AbPopupSurface({
    super.key,
    required this.child,
    this.width = 280,
    this.quiet = 0,
  });

  final Widget child;
  final double width;

  /// How far the popup has receded from the reader, 0 (full popup: opaque,
  /// strong border, lifted) to 1 (translucent over a blur, plain border, flat),
  /// and any point between for an animated approach or withdrawal.
  ///
  /// For a PINNED popup only — one that stays up under content the user is
  /// reading, where sitting at full strength the whole time would be a claim on
  /// attention it hasn't earned. A popup that opens on demand is already the
  /// thing being looked at and leaves this at 0. See `workspace_menu_button.dart`.
  final double quiet;

  @override
  Widget build(BuildContext context) {
    return Material(
      type: MaterialType.transparency,
      // The blur is a SIBLING painted behind the surface, never a wrapper
      // around it, for two reasons a wrapper gets wrong. Its clip would eat the
      // drop shadow, which `_popupDecoration` paints entirely outside the
      // popup's own rect — invisible for every quiet above 0, then snapping in
      // whole at 0. And a wrapper that comes and goes as quiet crosses 0
      // changes the tree's SHAPE mid-animation: `Widget.canUpdate` fails at
      // that slot, so everything below — row state, focus nodes, icons — is
      // discarded and re-inflated on the last frame of every reveal.
      //
      // `Clip.none` because the shadow is exactly the overflow a Stack would
      // otherwise be entitled to clip.
      child: Stack(
        clipBehavior: Clip.none,
        children: [
          if (quiet > 0)
            Positioned.fill(
              // The blur is what buys the translucency: see [_quietBlurSigma].
              // Clipped to the popup's own radius, or it blurs a rectangle out
              // past the corners.
              child: ClipRRect(
                borderRadius: AbTokens.borderRadius8,
                child: BackdropFilter(
                  filter: ImageFilter.blur(
                    sigmaX: _quietBlurSigma * quiet,
                    sigmaY: _quietBlurSigma * quiet,
                  ),
                  child: const SizedBox.expand(),
                ),
              ),
            ),
          Container(
            // Keyed so the surface — and every State beneath it — keeps its
            // identity as the blur appears and disappears beside it.
            key: const ValueKey('ab-popup-surface'),
            constraints: BoxConstraints(maxWidth: width, minWidth: 0),
            padding: const EdgeInsets.all(5),
            decoration: _popupDecoration(context.antgrid, quiet: quiet),
            child: child,
          ),
        ],
      ),
    );
  }
}

/// Whether [showAbMenu] should open above or below the anchor first.
/// If the preferred side has no room, the delegate flips to the other.
enum AbMenuPlacement { below, above }

/// Show a [AbMenu] anchored to [anchorRect] (in overlay coordinates).
///
/// The menu opens on the [preferred] side of the anchor (gap of [gap]
/// pixels between menu edge and anchor edge). If that side doesn't fit,
/// it flips to the other side; if neither fits, it picks the side with
/// more room and clamps.
///
/// [bounds] (overlay coordinates) optionally restricts the area the
/// menu may occupy — useful when the anchor lives inside a drawer or
/// other sub-region that the popup shouldn't visually escape. When
/// null, the menu is clamped only by the overlay's [SafeArea] insets.
/// Pass `MenuBoundsScope.maybeOf(context)` to auto-pick up the nearest
/// scope.
///
/// Returns the [AbMenuItem.value] of the picked entry, or `null` if
/// the user dismissed (tap-outside / Esc). Items may also carry an
/// [AbMenuItem.onTap] which runs before the route pops; use `value`
/// for return-style menus and `onTap` for fire-and-forget.
///
/// Replacement for Material's `showMenu` — keeps the Antgrid chrome
/// (no Material elevation, ripple, or theming leakage).
Future<T?> showAbMenu<T>({
  required BuildContext context,
  required Rect anchorRect,
  required List<AbMenuEntry> entries,
  AbMenuPlacement preferred = AbMenuPlacement.below,
  String? header,
  double width = 240,
  double gap = 4.0,
  Rect? bounds,
}) {
  final navigator = Navigator.of(context);
  return navigator.push<T>(
    _AbMenuRoute<T>(
      anchorRect: anchorRect,
      preferred: preferred,
      gap: gap,
      entries: entries,
      header: header,
      width: width,
      bounds: bounds,
      capturedThemes: InheritedTheme.capture(
        from: context,
        to: navigator.context,
      ),
    ),
  );
}

/// Anchor rect of [context]'s render box in overlay coordinates — the shape
/// [showAbMenu] takes. Null when the box or overlay hasn't been laid out yet;
/// callers bail rather than anchoring a menu to nothing.
Rect? abMenuAnchorRect(BuildContext context) {
  final box = context.findRenderObject() as RenderBox?;
  if (box == null || !box.hasSize) return null;
  final overlay = Overlay.of(context).context.findRenderObject() as RenderBox?;
  if (overlay == null) return null;
  return box.localToGlobal(Offset.zero, ancestor: overlay) & box.size;
}

/// Show an arbitrary LIVE widget in the AbMenu popup chrome, anchored like
/// [showAbMenu]. Unlike showAbMenu's static entries, [builder] runs inside the
/// route, so a ConsumerWidget child keeps watching providers while open
/// (needed when panel rows stream in — e.g. a machine's project advert).
/// Content pops itself with `Navigator.of(context).pop<T>(value)`; tap-outside
/// and Esc dismiss with null.
Future<T?> showAbPanel<T>({
  required BuildContext context,
  required Rect anchorRect,
  required WidgetBuilder builder,
  double width = 280,
  AbMenuPlacement preferred = AbMenuPlacement.below,
  Rect? bounds,
  double gap = 4.0,
}) {
  final navigator = Navigator.of(context);
  return navigator.push<T>(
    _AbPanelRoute<T>(
      anchorRect: anchorRect,
      preferred: preferred,
      gap: gap,
      builder: builder,
      width: width,
      bounds: bounds,
      capturedThemes: InheritedTheme.capture(
        from: context,
        to: navigator.context,
      ),
    ),
  );
}

class _AbPanelRoute<T> extends PopupRoute<T> {
  _AbPanelRoute({
    required this.anchorRect,
    required this.preferred,
    required this.gap,
    required this.builder,
    required this.capturedThemes,
    required this.width,
    this.bounds,
  });

  final Rect anchorRect;
  final AbMenuPlacement preferred;
  final double gap;
  final WidgetBuilder builder;
  final CapturedThemes capturedThemes;
  final double width;
  final Rect? bounds;

  @override
  Color? get barrierColor => null;
  @override
  bool get barrierDismissible => true;
  @override
  String? get barrierLabel => 'Dismiss';
  @override
  Duration get transitionDuration => AbTokens.motionSnap;

  @override
  Widget buildPage(
    BuildContext context,
    Animation<double> animation,
    Animation<double> secondaryAnimation,
  ) {
    final panel = Builder(
      builder: (ctx) => AbPopupSurface(width: width, child: builder(ctx)),
    );
    // Esc dismisses; Tab/Shift-Tab traverse the panel's focusable content
    // (e.g. PanelRow rows, gear-popover fields), kept inside the popup by the
    // FocusTraversalGroup. Unlike `_AbMenuRoute`, arrow keys are deliberately
    // NOT bound to DirectionalFocusIntent here: a panel can hold text fields
    // (the gear popover), and rebinding arrows at the route would hijack caret
    // movement inside them. Rows-only menus have no such conflict.
    final keyboard = Shortcuts(
      shortcuts: const {
        SingleActivator(LogicalKeyboardKey.escape): DismissIntent(),
      },
      child: Actions(
        actions: {
          DismissIntent: CallbackAction<DismissIntent>(
            onInvoke: (_) {
              navigator?.pop<T?>(null);
              return null;
            },
          ),
        },
        child: FocusTraversalGroup(
          policy: OrderedTraversalPolicy(),
          child: panel,
        ),
      ),
    );
    return SafeArea(
      child: CustomSingleChildLayout(
        delegate: _AbMenuLayoutDelegate(
          anchorRect: anchorRect,
          preferred: preferred,
          gap: gap,
          bounds: bounds,
        ),
        child: capturedThemes.wrap(
          FadeTransition(opacity: animation, child: keyboard),
        ),
      ),
    );
  }
}

/// Marks a sub-region of the screen as the bounding box for any
/// [showAbMenu] call whose caller looks it up via
/// [MenuBoundsScope.maybeOf]. The popup will clamp horizontally and
/// vertically into the scope's rect instead of the full overlay.
///
/// Wrap a drawer/panel with this so menus opened from its rows don't
/// spill out into the adjacent content area.
class MenuBoundsScope extends StatefulWidget {
  const MenuBoundsScope({super.key, required this.child});
  final Widget child;

  /// Returns the scope's rect in overlay coordinates, or `null` if no
  /// ancestor scope is in the tree (or the render tree isn't laid out
  /// yet). Safe to call from a button's `onPressed` — the scope and
  /// overlay are guaranteed to have rendered by then.
  static Rect? maybeOf(BuildContext context) {
    final inh = context
        .getElementForInheritedWidgetOfExactType<_MenuBoundsInherited>()
        ?.widget;
    if (inh is! _MenuBoundsInherited) return null;
    return inh.state._resolveBounds(context);
  }

  @override
  State<MenuBoundsScope> createState() => _MenuBoundsScopeState();
}

class _MenuBoundsScopeState extends State<MenuBoundsScope> {
  final GlobalKey _key = GlobalKey();

  Rect? _resolveBounds(BuildContext lookupContext) {
    final box = _key.currentContext?.findRenderObject() as RenderBox?;
    final overlay =
        Overlay.maybeOf(lookupContext)?.context.findRenderObject()
            as RenderBox?;
    if (box == null || overlay == null || !box.hasSize) return null;
    final topLeft = box.localToGlobal(Offset.zero, ancestor: overlay);
    return topLeft & box.size;
  }

  @override
  Widget build(BuildContext context) {
    return _MenuBoundsInherited(
      state: this,
      child: KeyedSubtree(key: _key, child: widget.child),
    );
  }
}

class _MenuBoundsInherited extends InheritedWidget {
  const _MenuBoundsInherited({required this.state, required super.child});
  final _MenuBoundsScopeState state;
  @override
  bool updateShouldNotify(_MenuBoundsInherited oldWidget) => false;
}

class _AbMenuRoute<T> extends PopupRoute<T> {
  _AbMenuRoute({
    required this.anchorRect,
    required this.preferred,
    required this.gap,
    required this.entries,
    required this.capturedThemes,
    this.header,
    this.width = 240,
    this.bounds,
  });

  final Rect anchorRect;
  final AbMenuPlacement preferred;
  final double gap;
  final List<AbMenuEntry> entries;
  final CapturedThemes capturedThemes;
  final String? header;
  final double width;
  final Rect? bounds;

  // Wrapped lazily once per route so that animation rebuilds don't
  // reallocate closures or lists. We can't wrap in the constructor
  // because the wrapped onTap needs a navigator context that only
  // exists once the route is installed — we resolve that via the
  // route's own `navigator` getter.
  List<AbMenuEntry>? _cachedWrapped;
  List<AbMenuEntry> get _wrappedEntries => _cachedWrapped ??= entries
      .map<AbMenuEntry>((e) {
        if (e is! AbMenuItem) return e;
        return AbMenuItem(
          key: e.key,
          label: e.label,
          icon: e.icon,
          shortcut: e.shortcut,
          danger: e.danger,
          badge: e.badge,
          badgeColor: e.badgeColor,
          enabled: e.enabled,
          disabledReason: e.disabledReason,
          value: e.value,
          onTap: () {
            // Pop FIRST so the menu route is no longer at the top of
            // the navigator stack. If the caller's onTap pushes a new
            // route (showDialog, Navigator.push), it lands on top of
            // the page that was beneath the menu, not on top of the
            // menu route itself (otherwise a subsequent pop would
            // unwind the wrong route). Side-effects in onTap are
            // ordered-after-pop for the same reason.
            navigator?.pop<T?>(e.value as T?);
            e.onTap?.call();
          },
        );
      })
      .toList(growable: false);

  @override
  Color? get barrierColor => null;
  @override
  bool get barrierDismissible => true;
  @override
  String? get barrierLabel => 'Dismiss';
  @override
  Duration get transitionDuration => AbTokens.motionSnap;

  @override
  Widget buildPage(
    BuildContext context,
    Animation<double> animation,
    Animation<double> secondaryAnimation,
  ) {
    final menu = AbMenu(header: header, width: width, items: _wrappedEntries);
    // Keyboard wiring on the route, not the menu widget:
    //   - Esc dismisses (DismissIntent → pop).
    //   - Up/Down move focus between items via the traversal group
    //     inside AbMenu (DirectionalFocusIntent is the default
    //     handler Flutter ships for arrow-key traversal).
    final keyboard = Shortcuts(
      shortcuts: const {
        SingleActivator(LogicalKeyboardKey.escape): DismissIntent(),
        SingleActivator(LogicalKeyboardKey.arrowDown): DirectionalFocusIntent(
          TraversalDirection.down,
        ),
        SingleActivator(LogicalKeyboardKey.arrowUp): DirectionalFocusIntent(
          TraversalDirection.up,
        ),
      },
      child: Actions(
        actions: {
          DismissIntent: CallbackAction<DismissIntent>(
            onInvoke: (_) {
              navigator?.pop<T?>(null);
              return null;
            },
          ),
        },
        child: menu,
      ),
    );
    return SafeArea(
      child: CustomSingleChildLayout(
        delegate: _AbMenuLayoutDelegate(
          anchorRect: anchorRect,
          preferred: preferred,
          gap: gap,
          bounds: bounds,
        ),
        child: capturedThemes.wrap(
          FadeTransition(opacity: animation, child: keyboard),
        ),
      ),
    );
  }
}

class _AbMenuLayoutDelegate extends SingleChildLayoutDelegate {
  _AbMenuLayoutDelegate({
    required this.anchorRect,
    required this.preferred,
    required this.gap,
    this.bounds,
  });

  final Rect anchorRect;
  final AbMenuPlacement preferred;
  final double gap;

  /// Optional sub-region (overlay coords) to clamp into. When null the
  /// menu uses the full parent size.
  final Rect? bounds;

  static const double _edgePad = 8.0;

  @override
  BoxConstraints getConstraintsForChild(BoxConstraints constraints) {
    final maxArea = bounds?.size ?? constraints.biggest;
    return BoxConstraints.loose(
      maxArea,
    ).deflate(const EdgeInsets.all(_edgePad));
  }

  @override
  Offset getPositionForChild(Size size, Size childSize) {
    // Resolve the clamping region. With no `bounds`, the full overlay
    // is fair game; otherwise we clamp inside the caller-supplied rect.
    final region = bounds ?? Rect.fromLTWH(0, 0, size.width, size.height);
    final minX = region.left + _edgePad;
    final maxX = region.right - _edgePad;
    final minY = region.top + _edgePad;
    final maxY = region.bottom - _edgePad;

    // Vertical: try preferred side first, flip if it doesn't fit, pick
    // whichever side has more room when both are tight.
    final spaceBelow = maxY - anchorRect.bottom - gap;
    final spaceAbove = anchorRect.top - gap - minY;
    final fitsBelow = childSize.height <= spaceBelow;
    final fitsAbove = childSize.height <= spaceAbove;

    final placeBelow = switch (preferred) {
      AbMenuPlacement.below => fitsBelow || !fitsAbove,
      AbMenuPlacement.above => !fitsAbove && fitsBelow,
    };

    double y;
    if (placeBelow) {
      y = anchorRect.bottom + gap;
      if (y + childSize.height > maxY) y = maxY - childSize.height;
    } else {
      y = anchorRect.top - gap - childSize.height;
      if (y < minY) y = minY;
    }

    // Horizontal: align menu's left edge with the anchor's left edge,
    // flip to anchor.right - menuWidth if it would overflow right, then
    // clamp to the region as a last resort.
    double x = anchorRect.left;
    if (x + childSize.width > maxX) {
      final flipped = anchorRect.right - childSize.width;
      x = flipped >= minX ? flipped : maxX - childSize.width;
    }
    if (x < minX) x = minX;
    return Offset(x, y);
  }

  @override
  bool shouldRelayout(covariant _AbMenuLayoutDelegate oldDelegate) =>
      anchorRect != oldDelegate.anchorRect ||
      preferred != oldDelegate.preferred ||
      gap != oldDelegate.gap ||
      bounds != oldDelegate.bounds;
}

class _MenuItemTile extends StatefulWidget {
  const _MenuItemTile({super.key, required this.item, this.autofocus = false});
  final AbMenuItem item;
  final bool autofocus;

  @override
  State<_MenuItemTile> createState() => _MenuItemTileState();
}

class _MenuItemTileState extends State<_MenuItemTile> {
  bool _hover = false;
  bool _focused = false;

  void _activate() {
    final i = widget.item;
    if (!i.enabled) {
      final reason = i.disabledReason;
      if (reason != null) showAbSnackBar(context, reason);
      return;
    }
    i.onTap?.call();
  }

  @override
  Widget build(BuildContext context) {
    final p = context.antgrid;
    final i = widget.item;
    // Treat keyboard focus the same as pointer hover for the visual
    // highlight — a single "active row" state for either input mode.
    final active = _hover || _focused;
    // Label tone: fg-1 → fg-0 on hover/focus (per Antgrid menu spec).
    final fg = !i.enabled
        ? p.textDisabled
        : i.danger
        ? p.error
        : (active ? p.textPrimary : p.textSecondary);
    // Icon tone is one step dimmer than the label (fg-2 → fg-0 on hover/focus).
    final iconFg = !i.enabled
        ? p.textDisabled
        : i.danger
        ? p.error
        : (active ? p.textPrimary : p.textMuted);
    final tile = FocusableActionDetector(
      autofocus: widget.autofocus,
      // Disabled rows keep hit-testing (so the reason can surface) but must not
      // promise a pick with the cursor — same split as AbSegmented's cells.
      mouseCursor: i.enabled
          ? SystemMouseCursors.click
          : SystemMouseCursors.basic,
      onShowHoverHighlight: (v) {
        if (_hover != v) setState(() => _hover = v);
      },
      onShowFocusHighlight: (v) {
        if (_focused != v) setState(() => _focused = v);
      },
      // Enter/Space activate the focused row — Up/Down/Tab traversal is
      // handled by the surrounding FocusTraversalGroup.
      shortcuts: const {
        SingleActivator(LogicalKeyboardKey.enter): ActivateIntent(),
        SingleActivator(LogicalKeyboardKey.space): ActivateIntent(),
        SingleActivator(LogicalKeyboardKey.numpadEnter): ActivateIntent(),
      },
      actions: {
        ActivateIntent: CallbackAction<ActivateIntent>(
          onInvoke: (_) {
            _activate();
            return null;
          },
        ),
      },
      child: GestureDetector(
        onTap: _activate,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
          decoration: BoxDecoration(
            color: active ? p.bgHover : Colors.transparent,
            borderRadius: AbTokens.borderRadius3,
          ),
          child: Row(
            children: [
              if (i.icon != null)
                Padding(
                  padding: const EdgeInsets.only(right: 9),
                  child: AbIcon(i.icon!, size: 13, color: iconFg),
                ),
              Expanded(
                child: Text(
                  i.label,
                  style: TextStyle(fontSize: AbTokens.fontSm, color: fg),
                ),
              ),
              if (i.badge != null)
                Padding(
                  padding: const EdgeInsets.only(left: 6),
                  child: AbChip.system(
                    label: i.badge!,
                    color: i.enabled ? i.badgeColor : p.textDisabled,
                  ),
                ),
              if (i.shortcut != null)
                Text(
                  i.shortcut!,
                  // Shortcuts are kbd glyphs (⌘ ⇧ ⌫ …) — mono per spec.
                  style: AbTokens.monoStyle(
                    fontSize: AbTokens.fontXxs,
                    color: p.textMuted,
                  ),
                ),
            ],
          ),
        ),
      ),
    );
    final reason = i.enabled ? null : i.disabledReason;
    if (reason == null) return tile;
    return AbTooltip(message: reason, child: tile);
  }
}
