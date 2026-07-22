import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:antgrid/models/agent_event.dart';
import 'package:antgrid/widgets/transcript/slash_suggestions.dart';

const _commands = [
  AgentCapabilityCommand(
    id: 'builtin:compact',
    name: 'compact',
    description: 'Free context',
  ),
  AgentCapabilityCommand(
    id: 'cmd:review',
    name: 'review',
    argHint: r'$ARGUMENTS',
  ),
  AgentCapabilityCommand(id: 'skill:code-review', name: 'code-review'),
];

const _caps = AgentCapabilities(sessionId: 's1', commands: _commands);

void main() {
  group('filterSlashCommands', () {
    test('prefix-matches case-insensitively', () {
      expect(filterSlashCommands(_commands, 'RE').single.id, 'cmd:review');
      expect(filterSlashCommands(_commands, '').length, 3);
      expect(filterSlashCommands(_commands, 'zzz'), isEmpty);
    });
  });

  group('resolveSubmission', () {
    test('recognized /command strips to args + commandId', () {
      final r = resolveSubmission('/review src/main.ts', _caps);
      expect(r.commandId, 'cmd:review');
      expect(r.text, 'src/main.ts');
    });

    test('bare /command yields empty args', () {
      final r = resolveSubmission('/compact', _caps);
      expect(r.commandId, 'builtin:compact');
      expect(r.text, '');
    });

    test('matches case-insensitively, mirroring the filter', () {
      final r = resolveSubmission('/Review src/main.ts', _caps);
      expect(r.commandId, 'cmd:review');
      expect(r.text, 'src/main.ts');
    });

    test('unknown /token passes through verbatim as text', () {
      final r = resolveSubmission('/nonesuch do it', _caps);
      expect(r.commandId, isNull);
      expect(r.text, '/nonesuch do it');
    });

    test('plain text and null caps pass through', () {
      expect(resolveSubmission('hello', _caps).commandId, isNull);
      expect(resolveSubmission('/review x', null).commandId, isNull);
    });
  });

  testWidgets('renders rows mono-named and tap picks the command', (
    tester,
  ) async {
    AgentCapabilityCommand? picked;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SlashSuggestions(
            commands: _commands,
            selectedIndex: 0,
            onPick: (c) => picked = c,
          ),
        ),
      ),
    );
    expect(find.text('/compact'), findsOneWidget);
    expect(find.text('/review'), findsOneWidget);
    await tester.tap(find.text('/review'));
    expect(picked?.id, 'cmd:review');
  });

  testWidgets('caps visible rows at 6', (tester) async {
    final many = [
      for (var i = 0; i < 10; i++)
        AgentCapabilityCommand(id: 'c$i', name: 'cmd$i'),
    ];
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SlashSuggestions(
            commands: many,
            selectedIndex: 0,
            onPick: (_) {},
          ),
        ),
      ),
    );
    expect(find.textContaining('/cmd'), findsNWidgets(6));
  });
}
