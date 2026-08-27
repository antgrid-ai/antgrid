import 'dart:convert';
import 'dart:math' as math;

import 'package:flutter/widgets.dart';

import '../design/ab_colors.dart';
import '../design/ab_icons.dart';
import '../design/ab_tokens.dart';
import '../design/widgets/ab_icon.dart';

/// Gap between the pointer and the card, in logical pixels.
///
/// Roughly a line of terminal text — enough that the card clears the row it
/// describes rather than covering the link the user is reading.
const double _gap = 18;

/// Distance kept from the panel's edges when the anchor is near one.
const double _margin = AbTokens.space8;

/// Longest run of prefix, host or trailing text laid out.
///
/// `maxLines: 1` and [TextOverflow.ellipsis] bound what is PAINTED, not what is
/// measured — the engine shapes the whole run before eliding it. A payload is
/// unbounded program-chosen text, so without this a single hover shapes all of
/// it on the UI thread. Same trap `_elide` guards in `external_url.dart`, which
/// documents it for the same data.
const int _maxPartChars = 128;

/// Characters that can reorder or hide the rest of the readout.
///
/// Bidi overrides and isolates re-order glyphs ACROSS span boundaries, so a
/// payload carrying U+202E paints a reading order that is not the URI's — on
/// the one surface whose whole job is letting exact characters be compared.
/// [terminalHyperlinkLooksDeceptive] cannot backstop it: the host itself is
/// clean, so such a link takes the desktop no-sheet path.
bool _isDisplayUnsafe(int rune) =>
    rune < 0x20 ||
    rune == 0x7F ||
    rune == 0x061C ||
    (rune >= 0x200E && rune <= 0x200F) ||
    (rune >= 0x202A && rune <= 0x202E) ||
    (rune >= 0x2066 && rune <= 0x2069);

/// Renders [part] with the invisible characters spelled out.
///
/// Percent-encoded rather than dropped, because that is what `Uri.toString()`
/// hands the launcher — so the card and the thing it describes agree on these
/// characters instead of diverging on exactly them.
String _display(String part) {
  if (!part.runes.any(_isDisplayUnsafe)) return part;
  final out = StringBuffer();
  for (final rune in part.runes) {
    if (!_isDisplayUnsafe(rune)) {
      out.writeCharCode(rune);
      continue;
    }
    for (final byte in utf8.encode(String.fromCharCode(rune))) {
      out.write('%${byte.toRadixString(16).toUpperCase().padLeft(2, '0')}');
    }
  }
  return out.toString();
}

/// Replaces the password half of a userinfo with a fixed mask.
///
/// A hover is not consent to display a secret: `https://x:TOKEN@host/` is a
/// shape real tooling prints, and before this readout existed the view painted
/// only an underline. The NAME half survives — it is what an impostor prefix
/// uses to read as a familiar host, which is the thing this card exists to
/// expose.
String _maskPassword(String prefix) {
  final at = prefix.lastIndexOf('@');
  if (at < 0) return prefix;
  final schemeEnd = prefix.indexOf('://');
  if (schemeEnd < 0) return prefix;
  final colon = prefix.indexOf(':', schemeEnd + 3);
  if (colon < 0 || colon > at) return prefix;
  return '${prefix.substring(0, colon + 1)}•••${prefix.substring(at)}';
}

/// Caps [part] to [_maxPartChars], keeping the end when [keepTail] is set.
///
/// The prefix keeps its TAIL: what matters there is the `@` and the characters
/// immediately before the host, not the start of a padded userinfo.
String _cap(String part, {bool keepTail = false}) {
  if (part.length <= _maxPartChars) return part;
  // Back off a stranded surrogate half: `substring` cuts UTF-16 code units, and
  // half a pair renders as a replacement glyph on exactly the characters a
  // reader is trying to identify.
  if (keepTail) {
    var start = part.length - _maxPartChars;
    if (_isLowSurrogate(part.codeUnitAt(start))) start += 1;
    return '…${part.substring(start)}';
  }
  var end = _maxPartChars;
  if (_isHighSurrogate(part.codeUnitAt(end - 1))) end -= 1;
  return '${part.substring(0, end)}…';
}

bool _isHighSurrogate(int unit) => unit >= 0xD800 && unit <= 0xDBFF;

bool _isLowSurrogate(int unit) => unit >= 0xDC00 && unit <= 0xDFFF;

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

  /// The raw OSC 8 payload, as the program wrote it apart from a masked
  /// password and spelled-out control characters.
  ///
  /// Not a parsed [Uri]: this reports what the link SAYS, including a payload
  /// no launcher would accept, and normalizing it would show the user a string
  /// the terminal does not contain.
  final String uri;

  /// Where the pointer was when this URI became the hovered one, in the
  /// enclosing stack's coordinates.
  final Offset anchor;

  /// The card itself, so a test can assert where the delegate put it.
  static const Key cardKey = ValueKey('terminal.hyperlink.preview.card');

  /// Widest the card may grow before its prefix and tail are elided.
  ///
  /// A URI is unbounded program-chosen text, so something has to stop it: the
  /// cap is what keeps a long one from spanning the terminal it overlays.
  static const double _maxWidth = 420;

  /// Widest the HOST span may grow.
  ///
  /// Held well under [_maxWidth] so the host is laid out before the elidable
  /// spans get what is left — see [_HyperlinkText] for why it must never be the
  /// part that gets cut.
  static const double _maxHostWidth = 280;

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
              Flexible(child: _HyperlinkText(uri: uri)),
            ],
          ),
        ),
      ),
    );
  }
}

/// The URI itself, split so the HOST is both the part that reads brightest and
/// the part that survives when the card runs out of room.
///
/// The host is the only span that decides where a click actually lands, and it
/// is the span a spoofed URI works hardest to bury: a `github.com@` userinfo
/// prefix puts a familiar name where a glance stops reading, and the real
/// destination after it.
///
/// Three separate [Text]s rather than one [Text.rich], because a single rich
/// run elides its TAIL — which behind a padded userinfo
/// (`https://github.com.login.oauth.…@evil.example/`) is the host itself, so
/// the readout would render as a clean GitHub URL and confirm the lie. Here the
/// host is the only non-flex child, so the elidable spans surrender their width
/// first and the host is cut last.
class _HyperlinkText extends StatelessWidget {
  const _HyperlinkText({required this.uri});

  final String uri;

  @override
  Widget build(BuildContext context) {
    final p = context.antgrid;
    // Mono: this is a URL, and the whole point is that its exact characters can
    // be compared.
    final base = AbTokens.monoStyle(
      fontSize: AbTokens.fontXs,
      color: p.textSecondary,
    );
    final range = _hostRange(uri);
    // Nothing to emphasize, and a guess about which characters are the host
    // would be exactly the wrong thing to be confident about.
    if (range == null) {
      return Text(
        _display(_cap(uri)),
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: base,
      );
    }
    final (start, end) = range;
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Flexible(
          child: Text(
            _display(
              _cap(_maskPassword(uri.substring(0, start)), keepTail: true),
            ),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: base.copyWith(color: p.textMuted),
          ),
        ),
        ConstrainedBox(
          constraints: const BoxConstraints(
            maxWidth: TerminalHyperlinkPreview._maxHostWidth,
          ),
          child: Text(
            _display(_cap(uri.substring(start, end))),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: base.copyWith(color: p.textPrimary),
          ),
        ),
        Flexible(
          child: Text(
            _display(_cap(uri.substring(end))),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: base,
          ),
        ),
      ],
    );
  }
}

/// The `[start, end)` span of the authority's host inside [uri], or null when
/// the payload names no host.
///
/// Located POSITIONALLY in the original text, never by searching it for the
/// parsed host. Two reasons, and each is the difference between disclosing the
/// lie and repeating it:
///
///  * `indexOf(host)` finds the FIRST occurrence, which an impostor puts in the
///    userinfo — `https://github.com.evil.tld@evil.tld/` would paint the
///    userinfo copy bright and leave the real authority reading as body text.
///  * `Uri.host` percent-encodes a raw unicode host, so it does not occur in
///    the original text at all and the search silently finds nothing, dropping
///    the emphasis on precisely the homoglyph it exists to expose.
///
/// Rebuilding the string from the parse is not an option either: `Uri`
/// lower-cases and percent-encodes as it goes, and this exists to let the user
/// compare the characters the terminal actually printed.
(int, int)? _hostRange(String uri) {
  final schemeEnd = uri.indexOf('://');
  if (schemeEnd < 0) return null;
  final authorityStart = schemeEnd + 3;
  var authorityEnd = uri.length;
  for (var i = authorityStart; i < uri.length; i++) {
    final c = uri[i];
    if (c == '/' || c == '?' || c == '#') {
      authorityEnd = i;
      break;
    }
  }
  // LAST `@`: a userinfo may contain one, and the host is what follows the
  // final separator — the same rule the parser applies.
  final at = uri.substring(authorityStart, authorityEnd).lastIndexOf('@');
  final start = authorityStart + (at < 0 ? 0 : at + 1);
  var end = authorityEnd;
  final rest = uri.substring(start, authorityEnd);
  if (rest.startsWith('[')) {
    // IPv6 literal: its colons belong to the host, and only one after `]`
    // starts a port.
    final close = rest.indexOf(']');
    if (close >= 0) end = start + close + 1;
  } else {
    final colon = rest.indexOf(':');
    if (colon >= 0) end = start + colon;
  }
  return end > start ? (start, end) : null;
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
      constraints.loosen().copyWith(
        maxWidth: math.max(0, constraints.maxWidth - _margin * 2),
      );

  @override
  Offset getPositionForChild(Size size, Size childSize) {
    // `math.max` on the upper bound rather than a branch: `clamp` throws on an
    // inverted range, so a panel narrower than the card has to resolve to the
    // margin instead of to an assertion. Hoisted into `double` locals because
    // `clamp` takes `num`: an inline `math.max` infers that from the parameter
    // and hands back a `num` no `Offset` will take.
    final double maxDx = math.max(
      _margin,
      size.width - childSize.width - _margin,
    );
    final double maxDy = math.max(
      _margin,
      size.height - childSize.height - _margin,
    );
    final dx = anchor.dx.clamp(_margin, maxDx);
    var dy = anchor.dy + _gap;
    if (dy + childSize.height > size.height - _margin) {
      dy = anchor.dy - _gap - childSize.height;
    }
    return Offset(dx, dy.clamp(_margin, maxDy));
  }

  @override
  bool shouldRelayout(_AnchoredNearPointer oldDelegate) =>
      oldDelegate.anchor != anchor;
}
