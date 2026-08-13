// app/lib/navigation/nav_console.dart
import 'dart:convert';

import 'package:flutter/foundation.dart';
// Only the ancestor a TextField asserts on; the bar's own chrome is AbTokens.
import 'package:flutter/material.dart' show Material, MaterialType;
import 'package:flutter/services.dart' show TextInputAction;
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../design/ab_colors.dart';
import '../design/ab_tokens.dart';
import '../design/widgets/ab_text_field.dart';
import '../providers/visible_surface.dart';
import 'nav_controller.dart';
import 'nav_serialization.dart';

/// Whether the nav console may render at all.
///
/// Mutable rather than a `--dart-define` because the thing that distinguishes a
/// driven app from a normal one is its ENTRY POINT
/// (`test_driver/driver_main.dart`, selected by `target:`), not a build flag —
/// so the entry point sets this before calling `main()`. Every read is paired
/// with [kDebugMode], which keeps the console out of release builds whatever
/// this holds.
bool kNavConsoleEnabled = false;

/// Debug-only command bar that lets an agent driving the app NAME a destination
/// instead of tapping its way to one, and read back where it landed.
///
/// It speaks the same `antgrid://nav/...` grammar as the deep links
/// ([navLocationFromUri]) and renders its answer through [navLocationToUri], so
/// there is one grammar in and out rather than a second console-only dialect.
///
/// Wrap the app with it from `MaterialApp.builder` so it sits above every route
/// and outside the shell's own layout; it returns [child] untouched unless
/// [kNavConsoleEnabled] is set.
class NavConsole extends StatelessWidget {
  const NavConsole({required this.child, super.key});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    if (!kDebugMode || !kNavConsoleEnabled) return child;
    return Column(
      children: [
        Expanded(child: child),
        const _NavConsoleBar(),
      ],
    );
  }
}

/// The bar itself: state out on the left, command in on the right.
///
/// Deliberately NOT wrapped in [Offstage]. `find.byKey` defaults to
/// `skipOffstage: true` in both flutter_test and the driver's finder factory,
/// so an offstage bar is invisible to every finder that could drive it; the
/// driver's `tap` also aims at the widget's centre, which needs real layout
/// size. It only exists under the driver entry point, so being visible costs
/// nothing worth hiding it for.
class _NavConsoleBar extends ConsumerStatefulWidget {
  const _NavConsoleBar();

  @override
  ConsumerState<_NavConsoleBar> createState() => _NavConsoleBarState();
}

class _NavConsoleBarState extends ConsumerState<_NavConsoleBar> {
  /// Owned here so [_submit] can hand focus back; [AbTextField] only borrows it.
  final FocusNode _focusNode = FocusNode();

  /// Folded into the same payload as the location so ONE `get_text` answers both
  /// "where am I" and "did that work" — and so a link the codec refuses surfaces
  /// as text instead of as a silent no-op.
  String _lastResult = 'none';

  @override
  void dispose() {
    _focusNode.dispose();
    super.dispose();
  }

  void _submit(String raw) {
    final text = raw.trim();
    final uri = Uri.tryParse(text);
    final loc = uri == null ? null : navLocationFromUri(uri);
    if (loc != null) {
      ref.read(navControllerProvider.notifier).applyDeepLink(loc);
    }
    setState(() {
      _lastResult = loc == null ? 'error: not a nav location: $text' : 'ok';
    });
    // This is a terminal-first app: a field left focused eats the keystrokes
    // meant for the PTY, so the console holds focus only between tap and submit.
    _focusNode.unfocus();
  }

  @override
  Widget build(BuildContext context) {
    final nav = ref.watch(navControllerProvider);
    final current = nav.current;
    final payload = jsonEncode({
      'location': current == null ? null : navLocationToUri(current).toString(),
      'view': ref.watch(visibleWorkspaceViewProvider)?.name,
      'canBack': nav.canBack,
      'canForward': nav.canForward,
      'last': _lastResult,
    });
    final colors = context.antgrid;

    return DecoratedBox(
      decoration: BoxDecoration(
        color: colors.bgDeep,
        border: Border(top: BorderSide(color: colors.borderDefault)),
      ),
      child: SafeArea(
        top: false,
        // Both wrappers exist because the bar mounts above every route, outside
        // any Material — the same bind as `window_title_bar.dart`. A TextField
        // asserts outright on a missing Material ancestor, and out here the
        // ambient DefaultTextStyle is WidgetsApp's red-on-yellow error style,
        // whose double underline survives `Text.style` merging. Transparency, so
        // the Material paints nothing of its own.
        child: Material(
          type: MaterialType.transparency,
          child: Padding(
            padding: const EdgeInsets.symmetric(
              horizontal: AbTokens.space8,
              vertical: AbTokens.space4,
            ),
            child: DefaultTextStyle(
              style: AbTokens.monoStyle(color: colors.textSecondary),
              // The command field is an EditableText, which builds its selection
              // handles and context menu into an Overlay — and the app's only
              // Overlay belongs to the Navigator, which is this bar's SIBLING.
              // `wrap` sizes itself to the row here, since the console's height
              // is unbounded inside the outer Column.
              child: Overlay.wrap(
                child: Row(
                  children: [
                    Expanded(
                      flex: 3,
                      child: Text(
                        payload,
                        key: const ValueKey('ab.nav.state'),
                        maxLines: 1,
                        // Clipping is cosmetic: `get_text` reads the widget's
                        // data, not the glyphs that fit.
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                    const SizedBox(width: AbTokens.space8),
                    Expanded(
                      flex: 2,
                      child: AbTextField(
                        key: const ValueKey('ab.nav.command'),
                        focusNode: _focusNode,
                        hintText: 'antgrid://nav/...',
                        // A URI is not prose, and an IME rewriting it on the
                        // way out would change the destination.
                        autocorrect: false,
                        enableSuggestions: false,
                        textInputAction: TextInputAction.done,
                        onSubmitted: _submit,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
