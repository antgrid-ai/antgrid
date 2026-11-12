import 'package:carbon_flutter/carbon_flutter.dart';
import 'package:flutter/material.dart' show DefaultMaterialLocalizations;
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

/// Live knobs for a mounted [carbonHarness]. Changing a value rebuilds the
/// scaffolding in place — nothing below remounts — so tests can switch theme,
/// density, direction or text scale while controls hold focus, text or an
/// open popup.
class CarbonHarness {
  CarbonHarness({
    CarbonThemeData? theme,
    TextDirection direction = TextDirection.ltr,
    double textScale = 1,
    bool reduceMotion = false,
  }) : theme = ValueNotifier<CarbonThemeData>(theme ?? CarbonThemeData()),
       direction = ValueNotifier<TextDirection>(direction),
       textScale = ValueNotifier<double>(textScale),
       reduceMotion = ValueNotifier<bool>(reduceMotion);

  final ValueNotifier<CarbonThemeData> theme;
  final ValueNotifier<TextDirection> direction;
  final ValueNotifier<double> textScale;
  final ValueNotifier<bool> reduceMotion;

  /// The harness Navigator, for pushing modal routes or simulating back.
  final GlobalKey<NavigatorState> navigatorKey = GlobalKey<NavigatorState>();

  Listenable get _all =>
      Listenable.merge(<Listenable>[theme, direction, textScale, reduceMotion]);

  /// Replaces the theme and pumps one frame plus the post-frame relay that
  /// carries it into Navigator routes.
  Future<void> setTheme(WidgetTester tester, CarbonThemeData data) async {
    theme.value = data;
    await tester.pump();
    await tester.pump();
  }

  Future<void> setDensity(WidgetTester tester, CarbonDensity density) =>
      setTheme(tester, theme.value.copyWith(density: density));

  /// Sends a system back through the harness Navigator, as Android's back
  /// button does, and pumps.
  Future<void> back(WidgetTester tester) async {
    await navigatorKey.currentState!.maybePop();
    await tester.pump();
  }

  void dispose() {
    theme.dispose();
    direction.dispose();
    textScale.dispose();
    reduceMotion.dispose();
  }
}

/// Carbon test scaffolding without WidgetsApp: MediaQuery, Localizations
/// (widgets + Material delegates, which text fields need), Directionality,
/// TapRegionSurface, default shortcuts and actions, CarbonTheme and a
/// Navigator whose single route hosts [child] (the Navigator also supplies the
/// Overlay that OverlayPortal needs).
///
/// Pass [harness] to control the scaffolding live; [pumpCarbon] does this for
/// you.
Widget carbonHarness(
  Widget child, {
  CarbonHarness? harness,
  CarbonThemeData? theme,
  TextDirection dir = TextDirection.ltr,
  double textScale = 1,
  bool reduceMotion = false,
}) {
  return _Harness(
    harness:
        harness ??
        CarbonHarness(
          theme: theme,
          direction: dir,
          textScale: textScale,
          reduceMotion: reduceMotion,
        ),
    ownsHarness: harness == null,
    child: child,
  );
}

/// Pumps [child] inside [carbonHarness] and returns the live
/// [CarbonHarness]. [size] sets the test view's logical size (reset after the
/// test).
Future<CarbonHarness> pumpCarbon(
  WidgetTester tester,
  Widget child, {
  CarbonThemeData? theme,
  TextDirection dir = TextDirection.ltr,
  double textScale = 1,
  Size? size,
  bool reduceMotion = false,
}) async {
  if (size != null) {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = size;
    addTearDown(tester.view.reset);
  }
  // Re-pumping keeps the mounted harness, like pumpWidget keeps a same-typed
  // tree: state below survives and new settings apply live.
  final mounted = find.byType(_Harness).evaluate();
  final CarbonHarness harness;
  var owns = false;
  if (mounted.isNotEmpty) {
    final existing = mounted.single.widget as _Harness;
    harness = existing.harness;
    owns = existing.ownsHarness;
    harness.theme.value = theme ?? CarbonThemeData();
    harness.direction.value = dir;
    harness.textScale.value = textScale;
    harness.reduceMotion.value = reduceMotion;
  } else {
    harness = CarbonHarness(
      theme: theme,
      direction: dir,
      textScale: textScale,
      reduceMotion: reduceMotion,
    );
    addTearDown(harness.dispose);
  }
  await tester.pumpWidget(
    _Harness(harness: harness, ownsHarness: owns, child: child),
  );
  return harness;
}

/// Switches the theme of the harness currently mounted by [pumpCarbon] or
/// [carbonHarness], keeping all state below it.
Future<void> setCarbonTheme(WidgetTester tester, CarbonThemeData data) {
  final state = tester.state<_HarnessState>(find.byType(_Harness));
  return state.widget.harness.setTheme(tester, data);
}

class _Harness extends StatefulWidget {
  const _Harness({
    required this.harness,
    required this.ownsHarness,
    required this.child,
  });

  final CarbonHarness harness;
  final bool ownsHarness;
  final Widget child;

  @override
  State<_Harness> createState() => _HarnessState();
}

class _HarnessState extends State<_Harness> {
  // The route builds from this, so a new child widget from a re-pump reaches
  // the already-pushed route without replacing it.
  late final ValueNotifier<Widget> _child = ValueNotifier<Widget>(widget.child);

  @override
  void didUpdateWidget(_Harness oldWidget) {
    super.didUpdateWidget(oldWidget);
    _child.value = widget.child;
    if (oldWidget.ownsHarness && oldWidget.harness != widget.harness) {
      oldWidget.harness.dispose();
    }
  }

  @override
  void dispose() {
    _child.dispose();
    if (widget.ownsHarness) widget.harness.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final harness = widget.harness;
    return ListenableBuilder(
      listenable: harness._all,
      builder: (context, _) {
        final view = MediaQueryData.fromView(View.of(context));
        return MediaQuery(
          data: view.copyWith(
            textScaler: TextScaler.linear(harness.textScale.value),
            disableAnimations: harness.reduceMotion.value,
          ),
          child: Localizations(
            locale: const Locale('en', 'US'),
            delegates: const <LocalizationsDelegate<Object?>>[
              DefaultWidgetsLocalizations.delegate,
              DefaultMaterialLocalizations.delegate,
            ],
            child: Directionality(
              textDirection: harness.direction.value,
              child: TapRegionSurface(
                child: Shortcuts(
                  shortcuts: WidgetsApp.defaultShortcuts,
                  child: DefaultTextEditingShortcuts(
                    child: Actions(
                      actions: WidgetsApp.defaultActions,
                      child: FocusTraversalGroup(
                        policy: ReadingOrderTraversalPolicy(),
                        child: CarbonTheme(
                          data: harness.theme.value,
                          child: Navigator(
                            key: harness.navigatorKey,
                            onGenerateRoute: (settings) => PageRouteBuilder<void>(
                              settings: settings,
                              transitionDuration: Duration.zero,
                              reverseTransitionDuration: Duration.zero,
                              pageBuilder: (context, _, _) =>
                                  ValueListenableBuilder<Widget>(
                                    valueListenable: _child,
                                    builder: (context, child, _) => child,
                                  ),
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
        );
      },
    );
  }
}
