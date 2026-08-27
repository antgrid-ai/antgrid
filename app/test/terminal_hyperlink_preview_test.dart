import 'package:antgrid/design/theme_presets.dart';
import 'package:antgrid/widgets/terminal_hyperlink_preview.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';

const Size _panel = Size(600, 400);

Future<void> _pump(WidgetTester tester, String uri, Offset anchor) {
  return tester.pumpWidget(
    MaterialApp(
      // The shipped palette, not `context.antgrid`'s tests-only fallback:
      // without the extension both the widget and the assertions resolve to
      // `_zincFallback`, so a colour assertion compares the fallback against
      // itself and stays green however the emphasis is wired.
      theme: ThemeData.dark().copyWith(
        extensions: <ThemeExtension<dynamic>>[kDefaultPalette],
      ),
      home: Scaffold(
        body: Center(
          child: SizedBox(
            width: _panel.width,
            height: _panel.height,
            child: Stack(
              children: [
                Positioned.fill(
                  child: TerminalHyperlinkPreview(uri: uri, anchor: anchor),
                ),
              ],
            ),
          ),
        ),
      ),
    ),
  );
}

/// The card's rect relative to the panel it floats in.
///
/// The widget itself is `Positioned.fill`, so its own rect IS the panel.
Rect _card(WidgetTester tester) {
  final panel = tester.getTopLeft(find.byType(TerminalHyperlinkPreview));
  return tester
      .getRect(find.byKey(TerminalHyperlinkPreview.cardKey))
      .shift(-panel);
}

/// Every painted run in the readout, paired with the colour it is drawn in.
///
/// The URI is three sibling [Text]s, not one rich run — see the widget for why
/// the host has to be laid out on its own.
List<(String, Color?)> _spans(WidgetTester tester) {
  final riches = tester.widgetList<RichText>(
    find.descendant(
      of: find.byType(TerminalHyperlinkPreview),
      matching: find.byType(RichText),
    ),
  );
  final out = <(String, Color?)>[];
  for (final rich in riches) {
    rich.text.visitChildren((span) {
      if (span is TextSpan && (span.text ?? '').isNotEmpty) {
        out.add((span.text!, span.style?.color));
      }
      return true;
    });
  }
  return out;
}

String _text(WidgetTester tester) => _spans(tester).map((s) => s.$1).join();

void main() {
  group('TerminalHyperlinkPreview', () {
    const link = 'https://github.com/antgrid-ai/antgrid/pull/13';

    testWidgets('shows the payload verbatim', (tester) async {
      await _pump(tester, link, const Offset(100, 100));

      expect(_text(tester), link);
    });

    // A readout that normalized would show the user a string the terminal does
    // not contain, on exactly the characters they are here to compare.
    testWidgets('does not normalize the case it was handed', (tester) async {
      await _pump(tester, 'https://GitHub.COM/OK', const Offset(100, 100));

      expect(_text(tester), 'https://GitHub.COM/OK');
    });

    // The point of the split: an impostor parked in userinfo reads dim and the
    // host that actually resolves reads bright, which is the reverse of how the
    // URI is written.
    testWidgets('paints the host brightest, userinfo prefix dimmest', (
      tester,
    ) async {
      await _pump(
        tester,
        'https://github.com@evil.example/antgrid/pull/13',
        const Offset(100, 100),
      );

      final spans = _spans(tester);
      expect(spans.first, ('https://github.com@', kDefaultPalette.textMuted));
      expect(spans[1], ('evil.example', kDefaultPalette.textPrimary));
      expect(spans.last.$1, '/antgrid/pull/13');
    });

    // Searching the raw text for the parsed host finds the FIRST occurrence,
    // which an attacker puts in the userinfo -- lighting up the impostor and
    // leaving the real destination reading as body text.
    testWidgets('a userinfo wearing the host does not steal the highlight', (
      tester,
    ) async {
      await _pump(tester, 'https://b.com.evil@b.com/x', const Offset(100, 100));

      final spans = _spans(tester);
      expect(spans.first, ('https://b.com.evil@', kDefaultPalette.textMuted));
      expect(spans[1], ('b.com', kDefaultPalette.textPrimary));
      expect(spans.last.$1, '/x');
    });

    // `Uri.host` percent-encodes a raw unicode host, so it does not occur in
    // the payload at all -- a search for it finds nothing and silently drops
    // the emphasis on the one shape it exists to expose.
    testWidgets('emphasizes a raw unicode host too', (tester) async {
      await _pump(tester, 'https://\u0430pple.com/login', const Offset(10, 10));

      final spans = _spans(tester);
      expect(spans[1], ('\u0430pple.com', kDefaultPalette.textPrimary));
    });

    // A single rich run elides its TAIL, and behind a padded userinfo the tail
    // IS the host -- so the card would render as a clean GitHub URL and confirm
    // the lie it exists to expose.
    testWidgets('keeps the host when a padded userinfo overflows the card', (
      tester,
    ) async {
      const host = 'evil.example';
      await _pump(
        tester,
        'https://github.com.${'padding.' * 40}@$host/pull/13',
        const Offset(10, 10),
      );

      final paragraph = tester.renderObject<RenderParagraph>(find.text(host));
      expect(paragraph.didExceedMaxLines, isFalse);
      expect(paragraph.size.width, greaterThan(0));
      // The elidable prefix is what gave up its width instead.
      expect(_card(tester).width, lessThanOrEqualTo(_panel.width));
    });

    // Bidi overrides re-order glyphs across span boundaries, so a payload
    // carrying one paints a reading order that is not the URI's -- and the
    // deception check cannot see it, because the host itself is clean.
    testWidgets('spells out a bidi control rather than obeying it', (
      tester,
    ) async {
      await _pump(
        tester,
        'https://evil.example/\u202Egro.dirgtna',
        const Offset(10, 10),
      );

      final text = _text(tester);
      expect(text, contains('%E2%80%AE'));
      expect(text, isNot(contains('\u202E')));
    });

    // A hover is not consent to display a secret, and before this readout
    // existed the view painted only an underline.
    testWidgets('masks the password half of a userinfo', (tester) async {
      await _pump(
        tester,
        'https://oauth2:ghp_LIVE_TOKEN@github.com/org/repo',
        const Offset(10, 10),
      );

      final text = _text(tester);
      expect(text, isNot(contains('ghp_LIVE_TOKEN')));
      expect(text, startsWith('https://oauth2:'));
      expect(_spans(tester)[1].$1, 'github.com');
    });

    // Nothing to emphasize, and a guess about which characters are the host is
    // exactly the wrong thing to be confident about.
    testWidgets('renders an unparseable payload flat', (tester) async {
      await _pump(tester, 'not a url at all', const Offset(100, 100));

      final spans = _spans(tester);
      expect(spans.length, 1);
      expect(spans.single.$1, 'not a url at all');
    });

    testWidgets('parks below the pointer, left edge on it', (tester) async {
      await _pump(tester, link, const Offset(100, 100));

      final card = _card(tester);
      expect(card.left, 100);
      expect(card.top, greaterThan(100));
    });

    // The prompt the user is typing into is the bottom line of the panel, so
    // the card has to leave it alone rather than settle over it.
    testWidgets('flips above the pointer near the bottom edge', (tester) async {
      await _pump(tester, link, Offset(100, _panel.height - 4));

      final card = _card(tester);
      expect(card.bottom, lessThan(_panel.height - 4));
      expect(card.top, greaterThanOrEqualTo(0));
    });

    testWidgets('slides inward rather than off the right edge', (tester) async {
      await _pump(tester, link, Offset(_panel.width - 4, 100));

      final card = _card(tester);
      expect(card.right, lessThanOrEqualTo(_panel.width));
      expect(card.left, lessThan(_panel.width - 4));
    });

    // A URI is unbounded program-chosen text; without the cap one long enough
    // would span the terminal it overlays.
    testWidgets('caps its width on a very long URI', (tester) async {
      await _pump(
        tester,
        'https://example.com/${'segment/' * 200}',
        const Offset(100, 100),
      );

      final card = _card(tester);
      expect(card.width, lessThan(_panel.width * 0.75));
      expect(card.right, lessThanOrEqualTo(_panel.width));
    });
  });
}
