import 'package:carbon_flutter/carbon_flutter.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:re_highlight/re_highlight.dart';

import 'code_syntax.dart' show codeLanguageForPath;

/// The text style and syntax palette every Carbon code surface renders at: the
/// file viewer's editor and the diff viewer's hand-painted rows. Both read it
/// from here so a file and its own diff share one size, family and palette.
///
/// The face is Carbon's `typography.code` (IBM Plex Mono); the size and line
/// height are the app's code metrics (12 compact, 13 touch, 1.4 line height),
/// not that step's. On touch the step resolves to 15/20, which costs a phone
/// diff about a fifth of its columns, and a changed line height would move
/// every row extent the viewers already derive from these metrics.
@immutable
class CarbonCodeStyle {
  const CarbonCodeStyle._(this.text, this.highlightTheme);

  factory CarbonCodeStyle.of(BuildContext context) =>
      CarbonCodeStyle.from(CarbonTheme.of(context));

  factory CarbonCodeStyle.from(CarbonThemeData theme) {
    final colors = theme.colors;
    final text = baseTextFor(theme).copyWith(color: colors.textPrimary);
    return CarbonCodeStyle._(text, _paletteFor(colors, text, theme.brightness));
  }

  static const double _compactFontSize = 12;
  static const double _touchFontSize = 13;
  static const double _lineHeightFactor = 1.4;

  /// Carbon's code face at the app's code size for [theme]'s density, with no
  /// colour. Shared with other mono text (the diff stat) so they track it.
  static TextStyle baseTextFor(CarbonThemeData theme) =>
      theme.typography.code.copyWith(
        fontSize: theme.isTouch ? _touchFontSize : _compactFontSize,
        height: _lineHeightFactor,
      );

  /// Base style for plain code and the root of every highlighted span.
  final TextStyle text;

  /// A `re_highlight` theme built from Carbon tokens, so it follows the
  /// scope's brightness. Carbon defines no syntax colours; roles map onto the
  /// closest semantic token:
  /// keywords and links `linkPrimary`; types `supportCautionUndefined`
  /// (purple); strings `supportError`; attributes `supportInfo`; comments,
  /// meta and tags `textSecondary`; everything else `textPrimary`.
  /// Numbers and selectors/bullets are the one brightness split: on Gray 100
  /// they use `supportSuccess` and `supportCautionMajor`, but on White those
  /// two fall below 4.5:1 as text, so they use `supportInfo` and
  /// `supportCautionUndefined` there.
  /// No role sets a background: the diff owns row tints.
  final Map<String, TextStyle> highlightTheme;

  /// One line's height, scaled the way a `Text` or `TextPainter` using
  /// [text] under [scaler] lays it out. Row-extent and jump maths must use this
  /// rather than a constant, or rows drift at a large text scale.
  double lineHeight(TextScaler scaler) =>
      scaler.scale(text.fontSize!) * text.height!;

  @override
  bool operator ==(Object other) =>
      other is CarbonCodeStyle &&
      other.text == text &&
      mapEquals(other.highlightTheme, highlightTheme);

  @override
  int get hashCode => Object.hash(text, highlightTheme.length);

  static Map<String, TextStyle> _paletteFor(
    CarbonColors c,
    TextStyle base,
    Brightness brightness,
  ) {
    TextStyle color(Color value, {FontStyle? fontStyle}) =>
        TextStyle(color: value, fontStyle: fontStyle);
    final keyword = color(c.linkPrimary);
    final type = color(c.supportCautionUndefined);
    final string = color(c.supportError);
    final comment = color(c.textSecondary, fontStyle: FontStyle.italic);
    final meta = color(c.textSecondary);
    final attr = color(c.supportInfo);
    final light = brightness == Brightness.light;
    final selector = color(
      light ? c.supportCautionUndefined : c.supportCautionMajor,
    );
    final number = color(light ? c.supportInfo : c.supportSuccess);
    final plain = color(c.textPrimary);
    return {
      'root': TextStyle(color: base.color),
      'keyword': keyword,
      'literal': keyword,
      'symbol': keyword,
      'name': keyword,
      'link': keyword,
      'built_in': type,
      'type': type,
      'class': type,
      'number': number,
      'string': string,
      'meta-string': string,
      'regexp': string,
      'template-tag': string,
      'subst': plain,
      'function': plain,
      'title': plain,
      'params': plain,
      'formula': plain,
      'comment': comment,
      'quote': comment,
      'doctag': meta,
      'meta': meta,
      'meta-keyword': meta,
      'tag': meta,
      'variable': plain,
      'template-variable': plain,
      'attr': attr,
      'attribute': attr,
      'section': color(c.linkPrimary),
      'emphasis': const TextStyle(fontStyle: FontStyle.italic),
      'strong': const TextStyle(fontWeight: FontWeight.w600),
      'bullet': selector,
      'selector-tag': selector,
      'selector-id': selector,
      'selector-class': selector,
      'selector-attr': selector,
      'selector-pseudo': selector,
    };
  }
}

/// Highlights single lines with a [CarbonCodeStyle], for surfaces that paint
/// their own rows. Each line is highlighted on its own: a diff hunk is a
/// fragment and its -/+ lines interleave two versions of the file, so state
/// carried between lines would cascade into the wrong colours. The palette is
/// supplied per call so a brightness switch recolours open rows.
class CarbonLineHighlighter {
  CarbonLineHighlighter._(this._languageKey, Mode mode)
    : _highlight = Highlight()..registerLanguage(_languageKey, mode);

  /// Null when [path] has no known language; callers then render plain text.
  static CarbonLineHighlighter? forPath(String? path) {
    final lang = codeLanguageForPath(path);
    return lang == null ? null : CarbonLineHighlighter._(lang.key, lang.mode);
  }

  static const _maxCachedLines = 2000;

  final String _languageKey;
  final Highlight _highlight;
  final Map<String, TextSpan> _cache = {};
  CarbonCodeStyle? _style;

  TextSpan span(String text, CarbonCodeStyle style) {
    if (!identical(style, _style)) {
      if (style != _style) _cache.clear();
      _style = style;
    }
    final cached = _cache[text];
    if (cached != null) return cached;

    final renderer = TextSpanRenderer(style.text, style.highlightTheme);
    _highlight.highlight(code: text, language: _languageKey).render(renderer);
    final span = renderer.span ?? TextSpan(text: text, style: style.text);

    if (_cache.length >= _maxCachedLines) _cache.clear();
    _cache[text] = span;
    return span;
  }
}
