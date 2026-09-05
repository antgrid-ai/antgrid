// Four surfaces name a session — the drawer row, the Recent list's two
// layouts, and the breadcrumb — and a session that is part of a session led
// elsewhere has to say so on every one of them. A badge mounted at three of
// four is worse than none: it teaches the user that its absence means the
// session works alone.
//
// The badge's own states (glyph, machine, orphaned copy) live in
// session_member_badge_test.dart; these tests only pin the mounts.
import 'package:antgrid/design/ab_icons.dart';
import 'package:antgrid/design/theme_presets.dart';
import 'package:antgrid/design/widgets/ab_icon.dart';
import 'package:antgrid/models/handler_state.dart';
import 'package:antgrid/models/recent_session_row.dart';
import 'package:antgrid/models/session_entry.dart';
import 'package:antgrid/models/terminal_models.dart';
import 'package:antgrid/project/project_session.dart';
import 'package:antgrid/project/project_session_registry.dart';
import 'package:antgrid/providers/agent_transport.dart';
import 'package:antgrid/providers/providers.dart';
import 'package:antgrid/providers/sessions.dart';
import 'package:antgrid/storage/cached_sessions_store.dart';
import 'package:antgrid/test_helpers/fake_agent_transport.dart';
import 'package:antgrid/widgets/recent_sessions/recent_session_row_widget.dart';
import 'package:antgrid/widgets/session_row.dart';
import 'package:antgrid/widgets/window_title_bar.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import '../helpers/prefs_test_mock.dart';
import '../helpers/test_store_overrides.dart';

const _kProjectId = 'proj-member';

SessionEntry _member() => const SessionEntry(
  id: 'sess-peer',
  name: 'Trace the leak',
  createdAt: 0,
  lastUsedAt: 0,
  archived: false,
  running: true,
  memberOf: SessionMemberOf(
    ref: SessionMemberRef(
      machineId: 'lead-machine-uuid',
      projectId: 'lead-proj',
      sessionId: 'sess-lead',
      machineLabel: 'Studio',
    ),
    joinedAt: 1,
  ),
);

Finder _badge() => find.byWidgetPredicate(
  (w) => w is AbIcon && w.icon == AbIcons.sessionMemberOf,
);

Widget _app(Widget child) => MaterialApp(
  theme: ThemeData.dark().copyWith(
    extensions: <ThemeExtension<dynamic>>[kDefaultPalette],
  ),
  home: Scaffold(body: child),
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late TestStoreOverrides stores;

  setUp(() async {
    useInMemoryPrefs();
    stores = await buildTestStoreOverrides();
  });

  tearDown(() => stores.close());

  testWidgets('the drawer session row badges a member session', (tester) async {
    final transport = FakeAgentTransport();
    final cache = await CachedSessionsStore.open();
    final projectSession = ProjectSession(
      projectId: _kProjectId,
      transport: transport,
      mode: ProjectSessionMode.local,
      cachedSessionsStore: cache,
      onClose: () async => transport.dispose(),
    );
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          ...stores.overrides,
          selectedRegistrationIdProvider.overrideWithValue(_kProjectId),
          projectSessionProvider.overrideWith((ref, id) async => projectSession),
        ],
        child: _app(
          SizedBox(
            width: 260,
            child: SessionRow(entryId: _kProjectId, session: _member()),
          ),
        ),
      ),
    );
    await tester.pump();

    expect(_badge(), findsOneWidget);
  });

  // The Recent list has two layouts, split on width, and each builds its own
  // badge run — the wide one is not the narrow one with columns hidden.
  for (final (name, width) in const [('wide', 900.0), ('compact', 420.0)]) {
    testWidgets('the $name Recent row badges a member session', (tester) async {
      debugDefaultTargetPlatformOverride = TargetPlatform.macOS;

      await tester.pumpWidget(
        ProviderScope(
          overrides: stores.overrides,
          child: _app(
            SizedBox(
              width: width,
              child: RecentSessionRowWidget(
                row: RecentSessionRow(
                  session: _member(),
                  origin: const RecentOrigin(
                    isLocal: true,
                    registrationId: _kProjectId,
                    projectId: _kProjectId,
                    machineUuid: 'local-machine-uuid',
                    projectName: 'antgrid',
                    deviceName: 'This machine',
                  ),
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pump();

      expect(_badge(), findsOneWidget);
      debugDefaultTargetPlatformOverride = null;
    });
  }

  // One breadcrumb, three headers: the window title bar, the desktop AgentBar
  // and the mobile toolbar all mount this, so badging it here badges all of
  // them at once.
  testWidgets('the breadcrumb badges the active member session', (
    tester,
  ) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          ...stores.overrides,
          selectedRegistrationIdProvider.overrideWith((ref) => _kProjectId),
          activeSessionProvider.overrideWithValue(_member()),
          terminalStateProvider.overrideWith(
            (ref) => Stream.value(const TerminalState()),
          ),
          handlerStateProvider.overrideWith(
            (ref) => Stream.value(const HandlerState.initial()),
          ),
        ],
        child: _app(const TitleBarBreadcrumb()),
      ),
    );
    await tester.pump();

    expect(_badge(), findsOneWidget);
  });
}
