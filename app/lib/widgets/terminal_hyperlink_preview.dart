import 'package:flutter/widgets.dart';

import '../design/ab_colors.dart';
import '../design/ab_icons.dart';
import '../design/ab_tokens.dart';
import '../design/widgets/ab_icon.dart';

/// The destination readout for the terminal link under the pointer.
///
/// OSC 8 lets a link's visible text say one thing and its target say another,
/// and the terminal view paints only an underline — so without this the first
/// place the real URI appears is the browser it has already been opened in.
/// This is the desktop half of that disclosure; touch has no hover and gets the
/// confirm sheet instead (`showTerminalHyperlinkSheet`).
///
/// Shaped as a twin of `TerminalUploadStrip` so the terminal's floating
/// overlays read as one family, and [IgnorePointer] for the same reason: it
/// floats over live terminal text, and the pointer it is describing is by
/// definition somewhere underneath it.
class TerminalHyperlinkPreview extends StatelessWidget {
  const TerminalHyperlinkPreview({
    super.key,
    required this.uri,
    required this.anchor,
  });

  /// The raw OSC 8 payload, exactly as the program wrote it.
  ///
  /// Not a parsed [Uri]: this reports what the link SAYS, including a payload
  /// no launcher would accept, and normalizing it here would show the user a
  /// string the terminal does not contain.
  final String uri;

  /// Where the pointer was when this URI became the hovered one, in the
  /// enclosing stack's coordinates.
  final Offset anchor;

  /// Gap between the pointer and the card, in logical pixels.
  ///
  /// Roughly a line of terminal text — enough that the card clears the row it
  /// describes rather than covering the link the user is reading.
  static const double _gap = 18;

  /// Distance kept from the panel's edges when the anchor is near one.
  static const double _margin = AbTokens.space8;

  /// The card itself, so a test can assert where the delegate put it.
  static const Key cardKey = ValueKey('terminal.hyperlink.preview.card');

  /// Widest the card may grow before its tail is elided.
  ///
  /// A URI is unbounded program-chosen text, so something has to stop it: the
  /// cap is what keeps a long one from spanning the terminal it overlays. The
  /// host survives the elision — see [_spans].
  static const double _maxWidth = 420;

  @override
  Widget build(BuildContext context) {
    final p = context.antgrid;
    return IgnorePointer(
      child: CustomSingleChildLayout(
        delegate: _AnchoredNearPointer(anchor: anchor),
        child: Container(
          key: cardKey,
          constraints: const BoxConstraints(maxWidth: _maxWidth),
          padding: const EdgeInsets.symmetric(
            horizontal: AbTokens.space10,
            vertical: AbTokens.space6,
          ),
          decoration: BoxDecoration(
            color: p.bgElevated,
            borderRadius: AbTokens.borderRadius5,
            border: Border.all(color: p.accent.withValues(alpha: 0.3)),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              AbIcon(AbIcons.link, size: 12, color: p.accent),
              const SizedBox(width: AbTokens.space6),
              Flexible(
                child: Text.rich(
                  TextSpan(children: _spans(context, uri)),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  // Mono: this is a URL, and the whole point is that its exact
                  // characters can be compared.
                  style: AbTokens.monoStyle(
                    fontSize: AbTokens.fontXs,
                    color: p.textSecondary,
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Splits [uri] so the HOST is the part that reads brightest.
///
/// The host is the only span that decides where a click actually lands, and it
/// is the span a spoofed URI works hardest to bury: a `github.com@` userinfo
/// prefix puts a familiar name where a glance stops reading, and the real
/// destination after it. The prefix is dim here; the host is not.
///
/// Falls back to one flat span when the payload does not parse or names no
/// host — there is nothing to emphasize, and a guess about which characters are
/// the host would be exactly the wrong thing to be confident about.
List<InlineSpan> _spans(BuildContext context, String uri) {
  final p = context.antgrid;
  final parsed = Uri.tryParse(uri.trim());
  if (parsed == null || parsed.host.isEmpty) {
    return [TextSpan(text: uri)];
  }
  final host = parsed.host;
  // Located in the ORIGINAL text, not rebuilt from the parse: `Uri` lower-cases
  // and percent-encodes as it goes, so a reconstruction would show the user a
  // string the terminal never printed — on precisely the characters this exists
  // to let them compare.
  final start = uri.toLowerCase().indexOf(host.toLowerCase());
  if (start < 0) {
    return [TextSpan(text: uri)];
  }
  final end = start + host.length;
  return [
    TextSpan(
      text: uri.substring(0, start),
      style: TextStyle(color: p.textMuted),
    ),
    TextSpan(
      text: uri.substring(start, end),
      style: TextStyle(color: p.textPrimary),
    ),
    TextSpan(text: uri.substring(end)),
  ];
}

/// Parks the card just below the pointer, flipping above it near the bottom
/// edge and sliding inward near the sides.
///
/// Below by default because the terminal's live prompt is at the BOTTOM of the
/// panel: a fixed readout down there — the browser status-bar placement — would
/// sit on the one line the user is typing into.
class _AnchoredNearPointer extends SingleChildLayoutDelegate {
  const _AnchoredNearPointer({required this.anchor});

  final Offset anchor;

  @override
  BoxConstraints getConstraintsForChild(BoxConstraints constraints) =>
      BoxConstraints.loose(
        Size(
          (constraints.maxWidth - TerminalHyperlinkPreview._margin * 2).clamp(
            0.0,
            double.infinity,
          ),
          constraints.maxHeight,
        ),
      );

  @override
  Offset getPositionForChild(Size size, Size childSize) {
    const margin = TerminalHyperlinkPreview._margin;
    const gap = TerminalHyperlinkPreview._gap;
    // `clamp` with a collapsed range throws, so the panel being narrower than
    // the card has to resolve to the margin rather than to an assertion.
    final maxDx = size.width - childSize.width - margin;
    final dx = maxDx <= margin
        ? margin
        : anchor.dx.clamp(margin, maxDx).toDouble();
    var dy = anchor.dy + gap;
    if (dy + childSize.height > size.height - margin) {
      dy = anchor.dy - gap - childSize.height;
    }
    final maxDy = size.height - childSize.height - margin;
    return Offset(dx, maxDy <= margin ? margin : dy.clamp(margin, maxDy));
  }

  @override
  bool shouldRelayout(_AnchoredNearPointer oldDelegate) =>
      oldDelegate.anchor != anchor;
}
