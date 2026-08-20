import 'package:flutter/painting.dart';
import 'package:re_highlight/re_highlight.dart';
import 'package:re_highlight/languages/bash.dart';
import 'package:re_highlight/languages/c.dart';
import 'package:re_highlight/languages/cpp.dart';
import 'package:re_highlight/languages/csharp.dart';
import 'package:re_highlight/languages/css.dart';
import 'package:re_highlight/languages/dart.dart';
import 'package:re_highlight/languages/dockerfile.dart';
import 'package:re_highlight/languages/go.dart';
import 'package:re_highlight/languages/gradle.dart';
import 'package:re_highlight/languages/ini.dart';
import 'package:re_highlight/languages/java.dart';
import 'package:re_highlight/languages/javascript.dart';
import 'package:re_highlight/languages/json.dart';
import 'package:re_highlight/languages/kotlin.dart';
import 'package:re_highlight/languages/markdown.dart';
import 'package:re_highlight/languages/python.dart';
import 'package:re_highlight/languages/ruby.dart';
import 'package:re_highlight/languages/rust.dart';
import 'package:re_highlight/languages/scss.dart';
import 'package:re_highlight/languages/sql.dart';
import 'package:re_highlight/languages/swift.dart';
import 'package:re_highlight/languages/typescript.dart';
import 'package:re_highlight/languages/xml.dart';
import 'package:re_highlight/languages/yaml.dart';
import 'package:re_highlight/styles/vs2015.dart';

import '../design/ab_tokens.dart';
import 'viewer_support.dart';

/// Metrics every code surface renders at — the file viewer's editor and the
/// diff viewer's hand-painted rows. Shared so a file and its own diff read at
/// the same size; two sizes make one document look like two.
const double kCodeFontSize = AbTokens.fontSm;
const double kCodeFontHeight = 1.4;
const double kCodeLineHeight = kCodeFontSize * kCodeFontHeight;

final _langModes = <String, ({String key, Mode mode})>{
  'dart': (key: 'dart', mode: langDart),
  'js': (key: 'javascript', mode: langJavascript),
  'jsx': (key: 'javascript', mode: langJavascript),
  'ts': (key: 'typescript', mode: langTypescript),
  'tsx': (key: 'typescript', mode: langTypescript),
  'py': (key: 'python', mode: langPython),
  'rb': (key: 'ruby', mode: langRuby),
  'java': (key: 'java', mode: langJava),
  'kt': (key: 'kotlin', mode: langKotlin),
  'swift': (key: 'swift', mode: langSwift),
  'go': (key: 'go', mode: langGo),
  'rs': (key: 'rust', mode: langRust),
  'c': (key: 'c', mode: langC),
  'cpp': (key: 'cpp', mode: langCpp),
  'cc': (key: 'cpp', mode: langCpp),
  'cxx': (key: 'cpp', mode: langCpp),
  'h': (key: 'cpp', mode: langCpp),
  'hpp': (key: 'cpp', mode: langCpp),
  'cs': (key: 'csharp', mode: langCsharp),
  'html': (key: 'xml', mode: langXml),
  'htm': (key: 'xml', mode: langXml),
  'xml': (key: 'xml', mode: langXml),
  'css': (key: 'css', mode: langCss),
  'scss': (key: 'scss', mode: langScss),
  'json': (key: 'json', mode: langJson),
  'yaml': (key: 'yaml', mode: langYaml),
  'yml': (key: 'yaml', mode: langYaml),
  'md': (key: 'markdown', mode: langMarkdown),
  'sql': (key: 'sql', mode: langSql),
  'sh': (key: 'bash', mode: langBash),
  'bash': (key: 'bash', mode: langBash),
  'zsh': (key: 'bash', mode: langBash),
  'dockerfile': (key: 'dockerfile', mode: langDockerfile),
  'toml': (key: 'ini', mode: langIni),
  'gradle': (key: 'gradle', mode: langGradle),
};

/// The highlight language for [path], or null when the extension has none.
({String key, Mode mode})? codeLanguageForPath(String? path) {
  if (path == null) return null;
  final name = viewerBasename(path);
  final ext = name.contains('.') ? name.split('.').last : null;
  return ext != null ? _langModes[ext] : null;
}

/// Highlights single lines for surfaces that paint their own rows — the diff
/// viewer, which needs per-row backgrounds and a dual line-number gutter that
/// re_editor can't give it, but must still colour code exactly like the file
/// viewer beside it (same [vs2015Theme]).
///
/// Lines are highlighted INDEPENDENTLY of each other, deliberately. A hunk is
/// a fragment with no lead-in, and its `-`/`+` lines interleave two versions of
/// the file — so any state carried line to line (an unterminated string, an
/// open block comment) is as likely to be wrong as right, and a wrong state
/// cascades over every line below it. Per line, a miss stays on its own row.
class CodeLineHighlighter {
  CodeLineHighlighter._(this._languageKey, Mode mode)
    : _highlight = Highlight()..registerLanguage(_languageKey, mode);

  /// Null when [path] has no known language — callers then render plain text.
  static CodeLineHighlighter? forPath(String? path) {
    final lang = codeLanguageForPath(path);
    return lang == null ? null : CodeLineHighlighter._(lang.key, lang.mode);
  }

  /// Bounded so a long diff can't grow the cache without limit; hunks are
  /// short and revisited on every scroll, so the hit rate is what matters.
  static const _maxCachedLines = 2000;

  final String _languageKey;
  final Highlight _highlight;
  final Map<String, TextSpan> _cache = {};
  TextStyle? _base;

  TextSpan span(String text, TextStyle base) {
    if (base != _base) {
      _cache.clear();
      _base = base;
    }
    final cached = _cache[text];
    if (cached != null) return cached;

    final renderer = TextSpanRenderer(base, vs2015Theme);
    _highlight.highlight(code: text, language: _languageKey).render(renderer);
    final span = renderer.span ?? TextSpan(text: text, style: base);

    if (_cache.length >= _maxCachedLines) _cache.clear();
    _cache[text] = span;
    return span;
  }
}
