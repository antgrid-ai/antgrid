import 'package:antgrid/design/ab_colors.dart';
import 'package:antgrid/widgets/terminal_hyperlink_preview.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

const Size _panel = Size(600, 400);

Future<void> _pump(WidgetTester tester, String uri, Offset anchor) {
  return tester.pumpWidget(
    MaterialApp(
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

/// Every span in the readout, paired with the color it is painted in.
List<(String, Color?)> _spans(WidgetTester tester) {
  final rich = tester.widget<RichText>(
    find.descendant(
      of: find.byType(TerminalHyperlinkPreview),
      matching: find.byType(RichText),
    ),
  );
  final out = <(String, Color?)>[];
  rich.text.visitChildren((span) {
    if (span is TextSpan && (span.text ?? '').isNotEmpty) {
      out.add((span.text!, span.style?.color));
    }
    return true;
  });
  return out;
}

void main() {
  group('TerminalHyperlinkPreview', () {
    const link = 'https://github.com/antgrid-ai/antgrid/pull/13';

    testWidgets('shows the payload verbatim', (tester) async {
      await _pump(tester, link, const Offset(100, 100));

      expect(_spans(tester).map((s) => s.$1).join(), link);
    });

    // A readout that normalized would show the user a string the terminal does
    // not contain, on exactly the characters they are here to compare.
    testWidgets('does not normalize the case it was handed', (tester) async {
      await _pump(tester, 'https://GitHub.COM/OK', const Offset(100, 100));

      expect(_spans(tester).map((s) => s.$1).join(), 'https://GitHub.COM/OK');
    });

    // The point of the split: an impostor parked in userinfo reads dim and the
    // host that actually resolves reads bright, which is the reverse of how the
    // URI is written.
    testWidgets('paints the host brightest, userinfo prefix dimmest', (
      tester,
    ) async {
      late AbColors palette;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Builder(
              builder: (context) {
                palette = context.antgrid;
                return const SizedBox.shrink();
              },
            ),
          ),
        ),
      );
      await _pump(
        tester,
        'https://github.com@evil.example/antgrid/pull/13',
        const Offset(100, 100),
      );

      final spans = _spans(tester);
      expect(spans.first, ('https://github.com@', palette.textMuted));
      expect(spans[1], ('evil.example', palette.textPrimary));
      expect(spans.last.$1, '/antgrid/pull/13');
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
