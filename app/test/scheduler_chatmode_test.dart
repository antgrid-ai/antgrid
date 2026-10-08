import 'package:antgrid/design/widgets/ab_chip.dart';
import 'package:antgrid/design/widgets/ab_prompt_field.dart';
import 'package:antgrid/models/scheduler.dart';
import 'package:antgrid/providers/scheduler_drafts.dart';
import 'package:flutter_test/flutter_test.dart';

import 'scheduler_oneoff_test.dart';
import 'scheduler_ux_test.dart';

Map<String, dynamic> chatSchedule({String? chatMode, String? approval}) => {
  ...settings,
  'mode': 'chat',
  'chatMode': ?chatMode,
  'approvalPolicy': ?approval,
};

Host chatHost({
  String? chatMode,
  String? approval,
  bool listed = true,
  String mode = 'chat',
}) => Host()
  ..chatModesListed = listed
  ..schedules = [
    mode == 'chat'
        ? chatSchedule(chatMode: chatMode, approval: approval)
        : {...settings, 'approvalPolicy': ?approval},
  ];

Future<void> openEditor(WidgetTester tester, Host host) async {
  sizeView(tester);
  await pumpScreen(tester, containerFor(host));
  await editSchedule(tester);
}

Map<String, dynamic> patchOf(Host host) =>
    host.calls.lastWhere((c) => c.method == 'scheduler.update').params['patch']
        as Map<String, dynamic>;

Future<void> pick(WidgetTester tester, String label) async {
  await tester.ensureVisible(chip(label));
  await tester.pumpAndSettle();
  await tester.tap(chip(label));
  await tester.pumpAndSettle();
}

Future<void> save(WidgetTester tester) async {
  await settle(tester);
  await tester.tap(find.text('Save schedule'));
  await tester.pumpAndSettle();
}

Map<String, dynamic> created(Host host) =>
    host.calls.lastWhere((c) => c.method == 'scheduler.create').params['schedule']
        as Map<String, dynamic>;

Future<void> startChatCreate(WidgetTester tester, Host host) async {
  sizeView(tester);
  await pumpScreen(tester, containerFor(host));
  await tester.tap(find.text('Create schedule'));
  await tester.pumpAndSettle();
  await pick(tester, 'Chat');
}

Future<void> fillAndSave(WidgetTester tester) async {
  await tester.enterText(field('Schedule name'), 'Chatty');
  await tester.enterText(find.byType(AbPromptField), 'Do it');
  await save(tester);
}

void main() {
  test('chatMode parses and round-trips for chat only', () {
    final chat = AgentSchedule.fromJson(chatSchedule(chatMode: 'auto'));
    expect(chat.chatMode, 'auto');
    expect(chat.settings()['chatMode'], 'auto');
    expect(
      AgentSchedule.fromJson(chatSchedule()).settings().containsKey('chatMode'),
      isFalse,
    );
    final terminal = AgentSchedule.fromJson({...settings, 'chatMode': 'auto'});
    expect(terminal.settings().containsKey('chatMode'), isFalse);
  });

  test('capabilities parse chatModes and default to none', () {
    final caps = SchedulerCapabilities.fromJson({
      'supported': true,
      'chatModes': {
        'claude': [
          {'id': 'plan', 'name': 'Plan', 'description': 'Read only.'},
        ],
      },
    });
    expect(caps.chatModes['claude']!.single.name, 'Plan');
    expect(caps.chatModes['claude']!.single.description, 'Read only.');
    expect(SchedulerCapabilities.fromJson({}).chatModes, isEmpty);
  });

  test('the dirty check covers chatMode', () async {
    final snapshot = await chatHost(chatMode: 'plan').snapshot();
    final draft = SchedulerDraft.start(snapshot, snapshot.schedules.single);
    expect(draft.dirty, isFalse);
    final edited = draft.edit(
      {...draft.values, 'chatMode': 'auto'},
      draft.frequency,
      draft.time,
    );
    expect(edited.dirty, isTrue);
    final cleared = draft.edit(
      {...draft.values}..remove('chatMode'),
      draft.frequency,
      draft.time,
    );
    expect(cleared.dirty, isTrue);
  });

  schedulerTestWidgets('the picker shows for chat on an agent with modes', (
    tester,
  ) async {
    await openEditor(tester, chatHost());
    expect(find.text('Permissions'), findsOneWidget);
    for (final label in [
      'Agent default',
      'Default',
      'Plan',
      'Auto',
      'Accept edits',
    ]) {
      expect(chip(label), findsOneWidget);
    }
    expect(tester.widget<AbChip>(chip('Agent default')).selected, isTrue);
  });

  schedulerTestWidgets('a stored "default" mode is told apart from no mode', (
    tester,
  ) async {
    final host = chatHost(chatMode: 'default');
    await openEditor(tester, host);
    expect(tester.widget<AbChip>(chip('Default')).selected, isTrue);
    expect(tester.widget<AbChip>(chip('Agent default')).selected, isFalse);
    await pick(tester, 'Agent default');
    await save(tester);
    expect(patchOf(host).containsKey('chatMode'), isTrue);
    expect(patchOf(host)['chatMode'], isNull);
  });

  schedulerTestWidgets('the picker is hidden for terminal', (tester) async {
    await openEditor(tester, chatHost(mode: 'terminal'));
    expect(find.text('Permissions'), findsNothing);
  });

  schedulerTestWidgets('the picker is hidden for Bypass', (tester) async {
    await openEditor(tester, chatHost(approval: 'bypass'));
    expect(find.text('Permissions'), findsNothing);
  });

  schedulerTestWidgets('the picker is hidden without capabilities', (
    tester,
  ) async {
    await openEditor(tester, chatHost(listed: false));
    expect(find.text('Permissions'), findsNothing);
  });

  schedulerTestWidgets('choosing a mode sends it on create', (tester) async {
    final host = Host()..chatModesListed = true;
    await startChatCreate(tester, host);
    await pick(tester, 'Plan');
    await fillAndSave(tester);
    expect(created(host)['mode'], 'chat');
    expect(created(host)['chatMode'], 'plan');
  });

  schedulerTestWidgets('a new chat schedule left on Default sends no chatMode', (
    tester,
  ) async {
    final host = Host()..chatModesListed = true;
    await startChatCreate(tester, host);
    await fillAndSave(tester);
    expect(created(host).containsKey('chatMode'), isFalse);
  });

  schedulerTestWidgets(
    'choosing Agent default on an existing schedule sends null',
    (tester) async {
      final host = chatHost(chatMode: 'auto');
      await openEditor(tester, host);
      await pick(tester, 'Agent default');
      await save(tester);
      expect(patchOf(host).containsKey('chatMode'), isTrue);
      expect(patchOf(host)['chatMode'], isNull);
    },
  );

  schedulerTestWidgets('choosing the listed Default sends its id', (
    tester,
  ) async {
    final host = chatHost(chatMode: 'auto');
    await openEditor(tester, host);
    await pick(tester, 'Default');
    await save(tester);
    expect(patchOf(host)['chatMode'], 'default');
  });

  schedulerTestWidgets('retapping the selected agent keeps a hidden mode', (
    tester,
  ) async {
    final host = chatHost(chatMode: 'build', listed: false);
    await openEditor(tester, host);
    await pick(tester, 'claude');
    await pick(tester, 'Chat');
    await tester.enterText(field('Schedule name'), 'Renamed');
    await save(tester);
    expect(patchOf(host)['chatMode'], 'build');
  });

  schedulerTestWidgets('switching agent clears the chat mode', (tester) async {
    final host = chatHost(chatMode: 'auto')
      ..extraAgents = [
        {
          'agentId': 'codex',
          'modes': ['chat', 'terminal'],
        },
      ];
    await openEditor(tester, host);
    await pick(tester, 'codex');
    expect(find.text('Permissions'), findsNothing);
    await save(tester);
    expect(patchOf(host)['agentId'], 'codex');
    expect(patchOf(host)['mode'] ?? 'chat', 'chat');
    expect(patchOf(host).containsKey('chatMode'), isTrue);
    expect(patchOf(host)['chatMode'], isNull);
  });

  schedulerTestWidgets('an unlisted stored mode is shown and kept on save', (
    tester,
  ) async {
    final host = chatHost(chatMode: 'build');
    await openEditor(tester, host);
    expect(tester.widget<AbChip>(chip('build')).selected, isTrue);
    await tester.enterText(field('Schedule name'), 'Renamed');
    await save(tester);
    expect(patchOf(host)['chatMode'], 'build');
  });

  schedulerTestWidgets('an agent with no listed modes keeps its stored mode', (
    tester,
  ) async {
    final host = chatHost(chatMode: 'build', listed: false);
    await openEditor(tester, host);
    expect(find.text('Permissions'), findsNothing);
    await tester.enterText(field('Schedule name'), 'Renamed');
    await save(tester);
    expect(patchOf(host)['chatMode'], 'build');
  });

  schedulerTestWidgets('the card names the permission mode', (tester) async {
    sizeView(tester);
    await pumpScreen(tester, containerFor(chatHost(chatMode: 'auto')));
    expect(find.text('Permissions: Auto'), findsOneWidget);
  });
}
