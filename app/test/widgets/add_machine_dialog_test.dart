// The add-machine dialog's picking rules (spec 7.5).
//
// What a screenshot cannot show is asserted here: which project the dialog
// guesses from the repo the lead is already in, that the guess is only a guess,
// that a machine with no model catalog can still be given a model, and above
// all that a dialog the user cancels has created nothing anywhere.
import 'dart:async';
import 'dart:io';

import 'package:antgrid/design/ab_theme.dart';
import 'package:antgrid/design/widgets/ab_button.dart';
import 'package:antgrid/design/widgets/ab_text_field.dart';
import 'package:antgrid/models/ab_project.dart';
import 'package:antgrid/models/agent_descriptor.dart';
import 'package:antgrid/models/session_entry.dart';
import 'package:antgrid/project/project_session_registry.dart';
import 'package:antgrid/providers/add_machine_action.dart';
import 'package:antgrid/providers/agent_catalog.dart';
import 'package:antgrid/providers/capability_catalog.dart';
import 'package:antgrid/providers/control_plane.dart';
import 'package:antgrid/providers/device_provisioning.dart';
import 'package:antgrid/providers/machine_capability_card.dart';
import 'package:antgrid/providers/new_session_picker.dart';
import 'package:antgrid/providers/projects.dart';
import 'package:antgrid/providers/sessions.dart';
import 'package:antgrid/services/capability_catalog_cache.dart';
import 'package:antgrid/services/control_plane_client.dart';
import 'package:antgrid/widgets/add_machine_dialog.dart';
import 'package:antgrid/widgets/new_session/picker_sources.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import '../helpers/prefs_test_mock.dart';

const _leadRegistrationId = 'lead-proj';
const _leadSessionId = 'sess-lead';
const _leadRemote = 'github.com/acme/app';

const _studioUuid = 'machine-studio';
const _laptopUuid = 'machine-laptop';

const _sources = [
  PickerSource(id: 'local', label: 'Local', isLocal: true, projects: []),
  PickerSource(
    id: 'machine:machine-studio',
    label: 'Studio',
    isLocal: false,
    projects: [],
    machineUuid: _studioUuid,
  ),
  PickerSource(
    id: 'machine:machine-laptop',
    label: 'Laptop',
    isLocal: false,
    projects: [],
    machineUuid: _laptopUuid,
  ),
];

/// Advert order is the order the project pane renders, and that order is the
/// pre-selection's only tiebreak — so the matching repo is deliberately NOT
/// first here.
const _studioProjects = [
  AdvertisedProject(
    projectId: 'other',
    label: 'other-repo',
    path: '/w/other',
    running: true,
  ),
  AdvertisedProject(
    projectId: 'app',
    label: 'app',
    path: '/w/app',
    running: true,
  ),
];

/// The laptop advertises a project but answers no Capability Card — an
/// unreachable card reader and a bridge predating the verb both look like this,
/// and a machine has to stay joinable through either.
const _laptopProjects = [
  AdvertisedProject(
    projectId: 'spare',
    label: 'spare',
    path: '/w/spare',
    running: true,
  ),
];

const _studioCard = CapabilityCard(
  os: OsCard(name: 'linux', version: '6.8', arch: 'x64'),
  projects: {
    'other': RepoCard(remote: 'github.com/acme/other', branch: 'main'),
    'app': RepoCard(remote: _leadRemote, branch: 'feature/leak'),
  },
);

/// The lead's own row, as the drawer would hold it — the dialog reads the
/// project list to label the lead half of the membership, and the real store
/// behind it wants a disk the widget tests do not have.
class _SeededProjects extends ProjectsNotifier {
  @override
  List<AbProject> build() => [
    AbProject(
      projectId: _leadRegistrationId,
      folder: '/w/app',
      displayName: 'app',
      hostDeviceUuid: 'local-uuid',
      hostMachineName: 'This machine',
      lastOpenedAt: DateTime.fromMillisecondsSinceEpoch(0),
    ),
  ];
}

class _SeededCatalog extends AgentCatalogNotifier {
  _SeededCatalog(this.seed);

  final Map<String, AgentDescriptor> seed;

  @override
  Map<String, AgentDescriptor> build() => seed;
}

SessionEntry _lead({List<SessionMember> members = const []}) => SessionEntry(
  id: _leadSessionId,
  name: 'Trace the leak',
  createdAt: 0,
  lastUsedAt: 0,
  archived: false,
  running: true,
  mode: 'chat',
  members: members,
);

/// Every project id a service was resolved for. Nothing in the Add flow can
/// reach a bridge without one — `warmServiceFor` awaits this family — so an
/// empty list is the assertion that the dialog has sent nothing.
late List<String> warmed;

/// Every Add the dialog actually issued, as the arguments it issued it with.
/// The flow itself is covered in `providers/add_machine_action_test.dart`; what
/// is asserted here is what the DIALOG resolved before handing over — the mode
/// above all, which is derived from a provider the dialog must have watched.
typedef AddCall =
    ({String tool, String? mode, String brief, SessionMemberCard? card});

late List<AddCall> added;

Future<void> _openDialog(
  WidgetTester tester, {
  SessionEntry? session,
  String? leadRemote = _leadRemote,
}) async {
  useInMemoryPrefs();
  warmed = <String>[];
  added = <AddCall>[];
  tester.view.physicalSize = const Size(900, 1000);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);

  final cacheRoot = Directory.systemTemp.createTempSync('ab_add_machine');
  addTearDown(() {
    if (cacheRoot.existsSync()) cacheRoot.deleteSync(recursive: true);
  });

  late BuildContext hostContext;
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        pickerSourcesProvider.overrideWithValue(_sources),
        controlPlaneStateProvider.overrideWith(
          (ref, uuid) => Stream.value(
            ControlPlaneState(
              projects: switch (uuid) {
                _studioUuid => _studioProjects,
                _laptopUuid => _laptopProjects,
                _ => const <AdvertisedProject>[],
              },
            ),
          ),
        ),
        machineCapabilityCardProvider.overrideWith(
          (ref, uuid) async => uuid == _studioUuid ? _studioCard : null,
        ),
        localProjectRemoteProvider.overrideWith(
          (ref, projectId) async =>
              projectId == _leadRegistrationId ? leadRemote : null,
        ),
        detectedToolsForProvider.overrideWith(
          (ref, target) async => const {'claude-code': 'Claude Code'},
        ),
        chatCapableToolsForProvider.overrideWith(
          (ref, target) async => const {'claude-code'},
        ),
        agentCatalogProvider.overrideWith(
          () => _SeededCatalog({
            'claude-code': const AgentDescriptor(
              tool: 'claude-code',
              label: 'Claude Code',
              chatCapable: true,
              judgeCapable: true,
              handlerTerminal: true,
              handlerChat: true,
            ),
          }),
        ),
        capabilityCatalogCacheProvider.overrideWithValue(
          CapabilityCatalogCache.testInstance(root: cacheRoot.path),
        ),
        activeSessionProvider.overrideWithValue(session ?? _lead()),
        projectsProvider.overrideWith(_SeededProjects.new),
        localDeviceUuidProvider.overrideWith((ref) async => 'local-uuid'),
        projectSessionProvider.overrideWith((ref, id) async {
          warmed.add(id);
          throw StateError('no bridge in this test');
        }),
        addMachineActionProvider.overrideWithValue((
          container, {
          required leadRegistrationId,
          required leadSessionId,
          required leadRef,
          required peer,
          required tool,
          required brief,
          model,
          mode,
          sessionName,
          peerMachineLabel,
          peerProjectLabel,
          peerCard,
        }) async {
          added.add((tool: tool, mode: mode, brief: brief, card: peerCard));
          return AddMachineOutcome.added(
            SessionMemberRef(
              machineId: peer.machineUuid,
              projectId: peer.projectId,
              sessionId: 'sess-peer',
            ),
          );
        }),
      ],
      child: MaterialApp(
        theme: buildAbTheme(),
        home: Scaffold(
          body: Builder(
            builder: (context) {
              hostContext = context;
              return const SizedBox.shrink();
            },
          ),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();

  unawaited(
    promptAddMachine(
      hostContext,
      leadRegistrationId: _leadRegistrationId,
      leadSessionId: _leadSessionId,
    ),
  );
  await tester.pumpAndSettle();
}

Future<void> _tapChip(WidgetTester tester, String labelFragment) async {
  await tester.tap(find.textContaining(labelFragment).first);
  await tester.pumpAndSettle();
}

Future<void> _pickStudio(WidgetTester tester) async {
  await _tapChip(tester, 'Select machine');
  await tester.tap(find.text('Studio'));
  await tester.pumpAndSettle();
}

Future<void> _pickAgent(WidgetTester tester) async {
  await _tapChip(tester, 'Select agent');
  await tester.tap(find.text('Claude Code'));
  await tester.pumpAndSettle();
}

Future<void> _typeBrief(WidgetTester tester) async {
  await tester.enterText(
    find.byWidgetPredicate((w) => w is AbTextField && w.maxLines == 6),
    'Take the Windows half',
  );
  await tester.pumpAndSettle();
}

AbButton _addButton(WidgetTester tester) => tester.widget<AbButton>(
  find.byWidgetPredicate((w) => w is AbButton && w.label == 'Add'),
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('pre-selects the project that is the same repo as the lead', (
    tester,
  ) async {
    await _openDialog(tester);
    await _pickStudio(tester);

    // Second in the advert order, so nothing but the remote match can have
    // chosen it.
    expect(find.text('app'), findsOneWidget);
    expect(find.textContaining('Select project'), findsNothing);
    // The card line is what lets the user see it really is the same repo.
    expect(find.textContaining('feature/leak'), findsOneWidget);
  });

  testWidgets('leaves the project unpicked when the lead has no remote', (
    tester,
  ) async {
    await _openDialog(tester, leadRemote: null);
    await _pickStudio(tester);

    expect(find.textContaining('Select project'), findsOneWidget);
  });

  testWidgets('the pre-selection is only a guess and can be overridden', (
    tester,
  ) async {
    await _openDialog(tester);
    await _pickStudio(tester);

    await _tapChip(tester, 'app');
    await tester.tap(find.text('other-repo'));
    await tester.pumpAndSettle();

    expect(find.text('other-repo'), findsOneWidget);
    expect(find.text('app'), findsNothing);
  });

  testWidgets('a machine already in the session is not offered again', (
    tester,
  ) async {
    await _openDialog(
      tester,
      session: _lead(
        members: const [
          SessionMember(
            ref: SessionMemberRef(
              machineId: _laptopUuid,
              projectId: 'p',
              sessionId: 's',
            ),
            joinedAt: 1,
          ),
        ],
      ),
    );
    await _tapChip(tester, 'Select machine');

    expect(find.text('Studio'), findsOneWidget);
    expect(find.text('Laptop'), findsNothing);
  });

  testWidgets('a model can be typed when the machine has listed none', (
    tester,
  ) async {
    await _openDialog(tester);
    await _pickStudio(tester);
    await _pickAgent(tester);

    await _tapChip(tester, 'Default');
    expect(find.textContaining('type an id'), findsOneWidget);

    final field = find.byWidgetPredicate(
      (w) => w is AbTextField && w.hintText == 'Model id',
    );
    expect(field, findsOneWidget);
    await tester.enterText(field, 'sonnet-4-6');
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pumpAndSettle();

    expect(find.text('sonnet-4-6'), findsWidgets);
  });

  testWidgets('Add stays disabled until the machine can be told what to do', (
    tester,
  ) async {
    await _openDialog(tester);
    expect(_addButton(tester).onTap, isNull);

    await _pickStudio(tester);
    expect(_addButton(tester).onTap, isNull, reason: 'no agent picked yet');

    await _pickAgent(tester);
    expect(_addButton(tester).onTap, isNull, reason: 'the brief is empty');

    await _typeBrief(tester);
    expect(_addButton(tester).onTap, isNotNull);
  });

  testWidgets(
    'the machine is always started in terminal, even when its agent speaks '
    'chat',
    (tester) async {
      // The seeded catalog and `chatCapableToolsForProvider` override both
      // mark claude-code chat-capable — a peer created in chat mode gets no
      // Antgrid MCP server and so could never receive a task, report, or ask
      // the lead, which is exactly the regression this pins.
      await _openDialog(tester);
      await _pickStudio(tester);
      await _pickAgent(tester);
      await _typeBrief(tester);
      await tester.tap(find.text('Add'));
      await tester.pumpAndSettle();

      expect(added, hasLength(1));
      expect(added.single.tool, 'claude-code');
      expect(added.single.mode, 'terminal');
      expect(added.single.brief, 'Take the Windows half');
    },
  );

  testWidgets('the card the dialog showed is the card it hands over', (
    tester,
  ) async {
    await _openDialog(tester);
    await _pickStudio(tester);
    await _pickAgent(tester);
    await _typeBrief(tester);
    await tester.tap(find.text('Add'));
    await tester.pumpAndSettle();

    // The machine's OS beside the repo of the project that was PICKED — the
    // dialog reads a card for the whole catalog, and only one project's half of
    // it belongs on this membership.
    expect(
      added.single.card,
      SessionMemberCard(
        osName: 'linux',
        osVersion: '6.8',
        osArch: 'x64',
        repoRemote: _leadRemote,
        repoBranch: 'feature/leak',
      ),
    );
  });

  testWidgets('a machine that answered no card is still addable', (
    tester,
  ) async {
    await _openDialog(tester);
    await _tapChip(tester, 'Select machine');
    await tester.tap(find.text('Laptop'));
    await tester.pumpAndSettle();
    await _tapChip(tester, 'Select project');
    await tester.tap(find.text('spare'));
    await tester.pumpAndSettle();
    await _pickAgent(tester);
    await _typeBrief(tester);
    await tester.tap(find.text('Add'));
    await tester.pumpAndSettle();

    expect(added, hasLength(1));
    expect(added.single.card, isNull);
  });

  testWidgets('a cancelled dialog has created nothing anywhere', (
    tester,
  ) async {
    await _openDialog(tester);
    await _pickStudio(tester);
    await _tapChip(tester, 'app');
    await tester.tap(find.text('other-repo'));
    await tester.pumpAndSettle();
    await _pickAgent(tester);
    await _typeBrief(tester);

    // Every field is set and Add is live — the dialog is one tap from creating
    // a session, and still nothing has been asked of any machine.
    expect(_addButton(tester).onTap, isNotNull);
    expect(warmed, isEmpty);

    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();

    expect(find.text('Add machine'), findsNothing);
    expect(warmed, isEmpty);
    expect(added, isEmpty);
  });
}
