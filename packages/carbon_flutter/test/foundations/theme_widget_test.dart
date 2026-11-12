import 'package:carbon_flutter/carbon_flutter.dart';
import 'package:flutter/material.dart' show DefaultMaterialLocalizations, Material, MaterialType, TextField;
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

Widget _host(Widget child, {TextDirection direction = TextDirection.ltr}) =>
    Directionality(
      textDirection: direction,
      child: MediaQuery(data: const MediaQueryData(), child: child),
    );

void main() {
  group('CarbonTheme.of', () {
    testWidgets('falls back to White compact without a scope', (tester) async {
      late CarbonThemeData seen;
      await tester.pumpWidget(
        _host(
          Builder(
            builder: (context) {
              seen = CarbonTheme.of(context);
              return const SizedBox();
            },
          ),
        ),
      );
      expect(seen, CarbonThemeData());
      expect(CarbonLayer.of(tester.element(find.byType(SizedBox))), 1);
    });

    testWidgets('inner scope overrides density only when asked', (tester) async {
      late CarbonThemeData outer;
      late CarbonThemeData inner;
      late CarbonThemeData sibling;
      await tester.pumpWidget(
        _host(
          CarbonTheme(
            data: CarbonThemeData(scheme: CarbonThemeScheme.gray90),
            child: Column(
              children: [
                Builder(
                  builder: (context) {
                    outer = CarbonTheme.of(context);
                    return const SizedBox();
                  },
                ),
                CarbonTheme(
                  data: CarbonThemeData(scheme: CarbonThemeScheme.gray90),
                  density: CarbonDensity.touch,
                  child: Builder(
                    builder: (context) {
                      inner = CarbonTheme.of(context);
                      return const SizedBox();
                    },
                  ),
                ),
                Builder(
                  builder: (context) {
                    sibling = CarbonTheme.of(context);
                    return const SizedBox();
                  },
                ),
              ],
            ),
          ),
        ),
      );
      expect(outer.density, CarbonDensity.compact);
      expect(inner.density, CarbonDensity.touch);
      expect(inner.controlHeight, 48);
      expect(inner.colors, CarbonColors.gray90);
      expect(sibling.density, CarbonDensity.compact);
    });

    testWidgets('sets default text style and icon theme from Carbon roles', (
      tester,
    ) async {
      late TextStyle style;
      late IconThemeData icons;
      await tester.pumpWidget(
        _host(
          CarbonTheme(
            data: CarbonThemeData(
              scheme: CarbonThemeScheme.gray100,
              density: CarbonDensity.touch,
            ),
            child: Builder(
              builder: (context) {
                style = DefaultTextStyle.of(context).style;
                icons = IconTheme.of(context);
                return const SizedBox();
              },
            ),
          ),
        ),
      );
      expect(style.color, CarbonColors.gray100.textPrimary);
      expect(style.fontSize, 16);
      expect(icons.color, CarbonColors.gray100.iconPrimary);
      expect(icons.size, 20);
    });

    testWidgets('changing data rebuilds dependents without remounting', (
      tester,
    ) async {
      final key = GlobalKey();
      Widget app(CarbonThemeData data) => _host(
        CarbonTheme(
          data: data,
          child: Builder(
            builder: (context) => Align(alignment: Alignment.topLeft, child: SizedBox(
              key: key,
              height: CarbonTheme.of(context).controlHeight,
            ),
            ),
          ),
        ),
      );
      await tester.pumpWidget(app(CarbonThemeData()));
      final element = tester.element(find.byKey(key));
      expect(tester.getSize(find.byKey(key)).height, 32);
      await tester.pumpWidget(app(CarbonThemeData(density: CarbonDensity.touch)));
      expect(tester.element(find.byKey(key)), same(element));
      expect(tester.getSize(find.byKey(key)).height, 48);
    });
  });

  group('CarbonLayer', () {
    testWidgets('CarbonLayerSurface paints the layer and raises children', (
      tester,
    ) async {
      final levels = <int>[];
      await tester.pumpWidget(
        _host(
          CarbonTheme(
            data: CarbonThemeData(),
            child: CarbonLayerSurface(
              child: Builder(
                builder: (context) {
                  levels.add(CarbonLayer.of(context));
                  return CarbonLayerSurface(
                    child: Builder(
                      builder: (context) {
                        levels.add(CarbonLayer.of(context));
                        return CarbonLayerSurface(
                          child: Builder(
                            builder: (context) {
                              levels.add(CarbonLayer.of(context));
                              return const SizedBox();
                            },
                          ),
                        );
                      },
                    ),
                  );
                },
              ),
            ),
          ),
        ),
      );
      expect(levels, [2, 3, 3]);
      final fills = tester
          .widgetList<DecoratedBox>(find.byType(DecoratedBox))
          .map((b) => (b.decoration as BoxDecoration).color)
          .toList();
      expect(fills, [
        CarbonColors.white.layer01,
        CarbonColors.white.layer02,
        CarbonColors.white.layer03,
      ]);
    });
  });

  group('CarbonScopeRelay', () {
    testWidgets(
      'relays the live theme into a pushed route and keeps typed text',
      (tester) async {
        final data = ValueNotifier(CarbonThemeData());
        addTearDown(data.dispose);
        final controller = TextEditingController();
        addTearDown(controller.dispose);
        final densities = <CarbonDensity>[];
        final colors = <CarbonColors>[];

        await tester.pumpWidget(
          WidgetsApp(
            color: const Color(0xFF000000),
            localizationsDelegates: const [
              DefaultMaterialLocalizations.delegate,
              DefaultWidgetsLocalizations.delegate,
            ],
            pageRouteBuilder: <T>(settings, builder) => PageRouteBuilder<T>(
              settings: settings,
              pageBuilder: (context, _, _) => builder(context),
            ),
            home: ValueListenableBuilder<CarbonThemeData>(
              valueListenable: data,
              builder: (context, theme, _) => CarbonTheme(
                data: theme,
                child: Builder(
                  builder: (context) => Align(alignment: Alignment.topLeft, child: GestureDetector(
                    behavior: HitTestBehavior.opaque,
                    onTap: () {
                      final relay = CarbonScopeRelay.of(context);
                      Navigator.of(context).push(
                        PageRouteBuilder<void>(
                          opaque: false,
                          pageBuilder: (_, _, _) => relay.wrap(
                            Builder(
                              builder: (context) {
                                final t = CarbonTheme.of(context);
                                densities.add(t.density);
                                colors.add(t.colors);
                                return Material(
                                  type: MaterialType.transparency,
                                  child: TextField(controller: controller),
                                );
                              },
                            ),
                          ),
                        ),
                      );
                    },
                    child: const SizedBox(width: 50, height: 50),
                  ),
                  ),
                ),
              ),
            ),
          ),
        );

        await tester.tap(find.byType(GestureDetector).first);
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 400));
        await tester.enterText(find.byType(TextField), 'hello');
        expect(densities.last, CarbonDensity.compact);

        data.value = CarbonThemeData(
          scheme: CarbonThemeScheme.gray100,
          density: CarbonDensity.touch,
        );
        // The relay notifies on the frame after the scope rebuilds.
        await tester.pump();
        await tester.pump();

        expect(densities.last, CarbonDensity.touch);
        expect(colors.last, CarbonColors.gray100);
        expect(controller.text, 'hello');
        expect(find.text('hello'), findsOneWidget);
      },
    );

    testWidgets('carries localizations and direction captured at open', (
      tester,
    ) async {
      const messages = CarbonLocalizations(close: 'Fermer');
      late Widget wrapped;
      await tester.pumpWidget(
        _host(
          direction: TextDirection.rtl,
          CarbonLocalizationsScope(
            messages: messages,
            child: CarbonTheme(
              data: CarbonThemeData(),
              child: Builder(
                builder: (context) {
                  wrapped = CarbonScopeRelay.of(context).wrap(
                    Builder(
                      builder: (context) => Text(
                        '${CarbonLocalizations.of(context).close}|'
                        '${Directionality.of(context).name}',
                        textDirection: TextDirection.ltr,
                      ),
                    ),
                  );
                  return const SizedBox();
                },
              ),
            ),
          ),
        ),
      );
      await tester.pumpWidget(
        Directionality(textDirection: TextDirection.ltr, child: wrapped),
      );
      expect(find.text('Fermer|rtl'), findsOneWidget);
    });

    testWidgets('without a scope the relay wraps a static snapshot', (
      tester,
    ) async {
      late CarbonScopeRelay relay;
      await tester.pumpWidget(
        _host(
          Builder(
            builder: (context) {
              relay = CarbonScopeRelay.of(context);
              return const SizedBox();
            },
          ),
        ),
      );
      late CarbonThemeData seen;
      await tester.pumpWidget(
        _host(
          relay.wrap(
            Builder(
              builder: (context) {
                seen = CarbonTheme.of(context);
                return const SizedBox();
              },
            ),
          ),
        ),
      );
      expect(seen, CarbonThemeData());
    });
  });
}
