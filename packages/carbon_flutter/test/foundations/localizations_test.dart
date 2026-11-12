import 'package:carbon_flutter/carbon_flutter.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

Widget _localized({
  required Locale locale,
  required List<LocalizationsDelegate<dynamic>> delegates,
  required Widget child,
}) => Directionality(
  textDirection: TextDirection.ltr,
  child: Localizations(locale: locale, delegates: delegates, child: child),
);

void main() {
  test('english defaults and plural helpers', () {
    const en = CarbonLocalizations.english;
    expect(en.clear, 'Clear');
    expect(en.resultCount(1), '1 result');
    expect(en.resultCount(0), '0 results');
    expect(en.resultCount(3), '3 results');
    expect(en.removeItem('api'), 'Remove api');
  });

  test('custom resultCount and removeItem override the defaults', () {
    final fr = CarbonLocalizations(
      resultCount: (n) => '$n résultat(s)',
      removeItem: (label) => 'Retirer $label',
    );
    expect(fr.resultCount(2), '2 résultat(s)');
    expect(fr.removeItem('x'), 'Retirer x');
  });

  testWidgets('falls back to English with no scope or delegate', (tester) async {
    late CarbonLocalizations seen;
    await tester.pumpWidget(
      Directionality(
        textDirection: TextDirection.ltr,
        child: Builder(
          builder: (context) {
            seen = CarbonLocalizations.of(context);
            return const SizedBox();
          },
        ),
      ),
    );
    expect(seen, same(CarbonLocalizations.english));
  });

  testWidgets('delegateFor resolves per locale and falls back to English', (
    tester,
  ) async {
    final delegate = CarbonLocalizations.delegateFor(
      (locale) => locale.languageCode == 'fr'
          ? const CarbonLocalizations(close: 'Fermer')
          : null,
    );
    Future<String> closeFor(Locale locale) async {
      late String text;
      await tester.pumpWidget(
        _localized(
          locale: locale,
          delegates: [delegate, DefaultWidgetsLocalizations.delegate],
          child: Builder(
            builder: (context) {
              text = CarbonLocalizations.of(context).close;
              return const SizedBox();
            },
          ),
        ),
      );
      return text;
    }

    expect(await closeFor(const Locale('fr')), 'Fermer');
    expect(await closeFor(const Locale('de')), 'Close');
  });

  testWidgets('the default delegate supports every locale in English', (
    tester,
  ) async {
    expect(CarbonLocalizations.delegate.isSupported(const Locale('xx')), isTrue);
    late CarbonLocalizations seen;
    await tester.pumpWidget(
      _localized(
        locale: const Locale('ja'),
        delegates: [
          CarbonLocalizations.delegate,
          DefaultWidgetsLocalizations.delegate,
        ],
        child: Builder(
          builder: (context) {
            seen = CarbonLocalizations.of(context);
            return const SizedBox();
          },
        ),
      ),
    );
    expect(seen, same(CarbonLocalizations.english));
  });

  testWidgets('a scope beats the app delegate and updates live', (tester) async {
    final delegate = CarbonLocalizations.delegateFor(
      (_) => const CarbonLocalizations(close: 'Delegate'),
    );
    final seen = <String>[];
    Widget app(String? scoped) {
      Widget probe = Builder(
        builder: (context) {
          seen.add(CarbonLocalizations.of(context).close);
          return const SizedBox();
        },
      );
      if (scoped != null) {
        probe = CarbonLocalizationsScope(
          messages: CarbonLocalizations(close: scoped),
          child: probe,
        );
      }
      return _localized(
        locale: const Locale('en'),
        delegates: [delegate, DefaultWidgetsLocalizations.delegate],
        child: probe,
      );
    }

    await tester.pumpWidget(app(null));
    await tester.pumpWidget(app('Scope A'));
    await tester.pumpWidget(app('Scope B'));
    expect(seen, ['Delegate', 'Scope A', 'Scope B']);
  });
}
