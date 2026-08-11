import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../design/ab_colors.dart';
import '../design/ab_tokens.dart';
import '../design/widgets/ab_search_field.dart';
import '../providers/session_search.dart';
import 'session_search_results.dart';

/// The DESKTOP session search: a title-bar field that drops a result popup
/// beneath itself. Mobile uses `SessionSearchButton` and its full-screen modal
/// instead — see `session_search_modal.dart` for why the two differ.
///
/// A popup rather than a filter over some list already on screen, because what
/// is being searched usually isn't on screen — sessions span every project and
/// machine, and the field sits in the window title bar, above every route. The
/// popup is what lets the search answer from anywhere and jump straight into a
/// session, instead of quietly rearranging a list the user may not be looking
/// at.
///
/// Takes its [FocusNode] from [sessionSearchFocusProvider] so Ctrl+K can reach
/// it from the shell; only one search surface is ever mounted, so a single
/// shared node is safe.
class SessionSearchField extends ConsumerStatefulWidget {
  const SessionSearchField({super.key, this.height = AbTokens.rowHeightXs});

  /// Defaults to the title bar's compact row — the bar is [rowHeightSm] tall
  /// and nothing taller fits. Mobile passes a touch-sized height instead.
  final double height;

  @visibleForTesting
  static const popupKey = Key('session-search-popup');

  @override
  ConsumerState<SessionSearchField> createState() => _SessionSearchFieldState();
}

class _SessionSearchFieldState extends ConsumerState<SessionSearchField> {
  final _link = LayerLink();
  final _portal = OverlayPortalController();
  late final TextEditingController _controller;
  late final FocusNode _focusNode;

  @override
  void initState() {
    super.initState();
    // Seeded, not bound: the query survives a layout change that swaps which of
    // the two mount points is up, and the field has to come back carrying it.
    _controller = TextEditingController(
      text: ref.read(sessionSearchQueryProvider),
    );
    _focusNode = ref.read(sessionSearchFocusProvider)..addListener(_onFocus);
  }

  @override
  void dispose() {
    // The node is provider-owned and outlives this widget — detach, never
    // dispose.
    _focusNode.removeListener(_onFocus);
    _controller.dispose();
    super.dispose();
  }

  /// Opening on focus (not on the first keystroke) is what makes the popup's
  /// resting state the recent list: click the box and there are already
  /// sessions to pick from; typing only narrows them. It also means Ctrl+K
  /// opens the popup without a second gesture.
  ///
  /// Blur deliberately does NOT close it — the result rows are focusable, so
  /// reaching for one takes focus off the field. The barrier handles the
  /// outside click instead.
  void _onFocus() {
    if (_focusNode.hasFocus) _portal.show();
  }

  void _set(String query) =>
      ref.read(sessionSearchQueryProvider.notifier).set(query);

  void _clear() {
    _controller.clear();
    _set('');
  }

  /// Escape empties a non-empty box and closes an already-empty one, so the one
  /// key does both things a search box is escaped for without the user having
  /// to guess which it will do.
  void _onEscape() {
    if (_controller.text.isEmpty) {
      _dismiss();
      return;
    }
    _clear();
  }

  void _dismiss() {
    _portal.hide();
    _focusNode.unfocus();
  }

  /// Popup geometry measured off the field itself, rather than fixed.
  ///
  /// Width tracks the field so the panel is exactly as wide as the box that
  /// opened it at either mount point — the title bar's capped 560, mobile's
  /// screen-width row. Height is only what is free below, because mobile puts
  /// the field partway down a canvas with the keyboard up, where a fixed panel
  /// would drop most of its rows behind the keyboard or off the screen.
  ///
  /// The panel hangs downward in both cases; flipping above when the field is
  /// near the bottom is deliberately not handled, since neither mount point
  /// puts it there.
  ({double width, double maxHeight}) _popupBounds(BuildContext overlayContext) {
    const fallback = (
      width: AbTokens.sessionSearchWidth,
      maxHeight: AbTokens.sessionSearchPopupMaxHeight,
    );
    final box = context.findRenderObject() as RenderBox?;
    final media = MediaQuery.maybeOf(overlayContext);
    if (box == null || !box.hasSize || media == null) return fallback;

    final free =
        media.size.height -
        media.viewInsets.bottom -
        box.localToGlobal(Offset(0, box.size.height)).dy -
        AbTokens.space6 -
        AbTokens.space12;

    // The floors are themselves capped by the screen: on a small phone a floor
    // wider or taller than the window would be worse than the measurement.
    return (
      width: box.size.width.clamp(
        math.min(AbTokens.sessionSearchPopupMinWidth, media.size.width),
        AbTokens.sessionSearchWidth,
      ),
      maxHeight: free.clamp(
        math.min(AbTokens.sessionSearchPopupMinHeight, media.size.height),
        AbTokens.sessionSearchPopupMaxHeight,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return OverlayPortal(
      controller: _portal,
      overlayChildBuilder: (overlayContext) {
        final bounds = _popupBounds(overlayContext);
        return _SearchPopupLayer(
          link: _link,
          width: bounds.width,
          maxHeight: bounds.maxHeight,
          onDismiss: _dismiss,
        );
      },
      child: CompositedTransformTarget(
        link: _link,
        child: CallbackShortcuts(
          bindings: {
            const SingleActivator(LogicalKeyboardKey.escape): _onEscape,
          },
          child: AbSearchField(
            controller: _controller,
            focusNode: _focusNode,
            hint: 'Search sessions…',
            height: widget.height,
            // No debounce: filtering is a local pass over the session cache, so
            // a keystroke costs a rebuild, not a round trip.
            debounce: null,
            onChanged: _set,
            onClear: _clear,
          ),
        ),
      ),
    );
  }
}

/// Everything the popup puts in the overlay: a full-screen dismiss barrier, and
/// the results panel hung under the field by [link].
///
/// `Positioned.fill` at the root because the overlay lays its children out like
/// a Stack — unpositioned, this would be sized by its content and the barrier
/// would cover only the panel.
class _SearchPopupLayer extends StatelessWidget {
  const _SearchPopupLayer({
    required this.link,
    required this.width,
    required this.maxHeight,
    required this.onDismiss,
  });

  final LayerLink link;
  final double width;
  final double maxHeight;
  final VoidCallback onDismiss;

  @override
  Widget build(BuildContext context) {
    return Positioned.fill(
      // Nothing above the overlay supplies a Material — it is a sibling of the
      // routes — and the result rows are written for a route, where one always
      // exists. Transparency, so it paints nothing of its own.
      child: Material(
        type: MaterialType.transparency,
        child: Stack(
          children: [
            // Below the panel in paint order, so a click INSIDE the popup never
            // reaches it, and opaque so a click anywhere else does.
            Positioned.fill(
              child: GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTap: onDismiss,
              ),
            ),
            CompositedTransformFollower(
              link: link,
              // Centred under the field rather than anchored to an edge of it:
              // the field is itself centred in the title bar, so an edge anchor
              // would visibly lean the popup off to one side.
              targetAnchor: Alignment.bottomCenter,
              followerAnchor: Alignment.topCenter,
              offset: const Offset(0, AbTokens.space6),
              child: ConstrainedBox(
                constraints: BoxConstraints(
                  minWidth: width,
                  maxWidth: width,
                  // Past this the list scrolls — a tall window must not turn
                  // the resting recent list into a full-height wall.
                  maxHeight: maxHeight,
                ),
                child: _SearchPanel(onOpened: onDismiss),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// The popup's own chrome around the shared [SessionSearchResults].
class _SearchPanel extends StatelessWidget {
  const _SearchPanel({required this.onOpened});

  final VoidCallback onOpened;

  @override
  Widget build(BuildContext context) {
    final t = context.antgrid;
    return Container(
      key: SessionSearchField.popupKey,
      decoration: BoxDecoration(
        color: t.bgElevated,
        border: Border.all(color: t.borderDefault),
        borderRadius: BorderRadius.circular(AbTokens.radius8),
      ),
      clipBehavior: Clip.antiAlias,
      child: SessionSearchResults(
        onOpened: onOpened,
        // The panel's own fill, not the canvas default.
        surfaceColor: t.bgElevated,
        // Sized by its content up to the popup's cap, rather than filling a
        // height it was never given.
        shrinkWrap: true,
      ),
    );
  }
}
