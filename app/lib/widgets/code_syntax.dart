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

import 'viewer_support.dart';

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
