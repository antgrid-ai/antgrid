import 'package:antgrid/design/ab_carbon.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

/// The names of every `Ab*` widget under [scope] (default: the single
/// [AbCarbonScope]), skipping the types in [allow]. The agent mark is allowed
/// by default: its logo is content imagery and builds Ab widgets of its own.
/// The pattern needs a capital after `Ab` so framework widgets such as
/// `AbsorbPointer` do not match.
List<String> abWidgetsInScope(
  WidgetTester tester, {
  Finder? scope,
  Set<String> allow = const {'AbAgentMark'},
}) {
  final found = <String>[];
  void visit(Element element) {
    final name = element.widget.runtimeType.toString();
    if (allow.contains(name)) return;
    if (RegExp(r'^Ab[A-Z]').hasMatch(name)) found.add(name);
    element.visitChildren(visit);
  }

  tester.element(scope ?? find.byType(AbCarbonScope)).visitChildren(visit);
  return found;
}
