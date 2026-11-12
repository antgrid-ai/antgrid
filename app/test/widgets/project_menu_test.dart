import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/misc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:antgrid/design/ab_carbon.dart';
import 'package:antgrid/design/ab_theme.dart';
import 'package:antgrid/providers/control_plane.dart';
import 'package:antgrid/providers/new_session_picker.dart';
import 'package:antgrid/services/control_plane_client.dart';
import 'package:antgrid/widgets/ab_status_helpers.dart';
import 'package:antgrid/widgets/new_session/picker_sources.dart';
import 'package:antgrid/widgets/new_session/project_menu.dart';

// Fabricated sources follow the pattern used in test/new_session_picker_test.dart
// and test/widgets/environment_menu_test.dart: pickerSourcesProvider is a pure
// Provider<List<PickerSource>>, so it can be overridden with a literal list.
const _localSource = PickerSource(
  id: 'local',
  label: 'Local',
  isLocal: true,
  projects: [
    PickerProject(
      id: 'p-my-repo',
      name: 'my-repo',
      detail: '/home/me/my-repo',
      isLocal: true,
    ),
    PickerProject(
      id: 'p-other',
      name: 'other-repo',
      detail: '/home/me/other-repo',
      isLocal: true,
    ),
  ],
);

const _remoteSource = PickerSource(
  id: 'machine:u1',
  label: 'Buildbox',
  isLocal: false,
  projects: <PickerProject>[],
  machineUuid: 'u1',
);

const _emptyLocalSource = PickerSource(
  id: 'local',
  label: 'Local',
  isLocal: true,
  projects: <PickerProject>[],
);

// The mobile "nothing paired yet" fallback: buildPickerSources emits a single
// placeholder with a null machineUuid, which visiblePickerSourceProvider then
// hands to the menu.
const _placeholderSource = PickerSource(
  id: 'machine:none',
  label: 'Remote',
  isLocal: false,
  projects: <PickerProject>[],
  machineUuid: null,
);

Widget _host({
  List<PickerSource>? sources,
  VoidCallback? onOpenFolder,
  List<Override> extraOverrides = const [],
}) {
  return ProviderScope(
    overrides: [
      pickerSourcesProvider.overrideWithValue(sources ?? const [_localSource]),
      ...extraOverrides,
    ],
    child: MaterialApp(
      theme: buildAbTheme(),
      home: Scaffold(
        body: Center(
          child: AbCarbonScope(
            child: ProjectChip(onOpenFolder: onOpenFolder ?? _noop),
          ),
        ),
      ),
    ),
  );
}

void main() {
  testWidgets('chip shows Select project… until a target is picked', (
    tester,
  ) async {
    await tester.pumpWidget(_host());
    await tester.pumpAndSettle();

    expect(find.text('Select project…'), findsOneWidget);
  });

  testWidgets(
    'local menu: Open folder… row first, then projects; pick writes target',
    (tester) async {
      await tester.pumpWidget(_host());
      await tester.pumpAndSettle();

      await tester.tap(find.byType(ProjectChip));
      await tester.pumpAndSettle();

      expect(find.text('Open folder…'), findsOneWidget);
      expect(find.text('my-repo'), findsOneWidget);
      expect(find.text('other-repo'), findsOneWidget);

      final container = ProviderScope.containerOf(
        tester.element(find.byType(ProjectChip)),
      );

      await tester.tap(find.text('my-repo'));
      await tester.pumpAndSettle();

      expect(container.read(selectedTargetProjectProvider)?.id, 'p-my-repo');
      expect(find.text('my-repo'), findsOneWidget);
      expect(find.text('Select project…'), findsNothing);
    },
  );

  testWidgets('Open folder… invokes the callback and closes the menu', (
    tester,
  ) async {
    var opened = false;
    await tester.pumpWidget(_host(onOpenFolder: () => opened = true));
    await tester.pumpAndSettle();

    await tester.tap(find.byType(ProjectChip));
    await tester.pumpAndSettle();

    await tester.tap(find.text('Open folder…'));
    await tester.pumpAndSettle();

    expect(opened, isTrue);
    // Menu closed: its rows are gone.
    expect(find.text('my-repo'), findsNothing);
  });

  testWidgets('remote menu shows Connecting… while the advert is loading', (
    tester,
  ) async {
    final controller = StreamController<ControlPlaneState>();
    addTearDown(controller.close);

    await tester.pumpWidget(
      _host(
        sources: const [_remoteSource],
        extraOverrides: [
          controlPlaneStateProvider(
            'u1',
          ).overrideWith((ref) => controller.stream),
        ],
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.byType(ProjectChip));
    // Open lands a setState on the chip, then the menu mounts; the stream is
    // still pending throughout, so these pumps never reach a data frame.
    await tester.pump();
    await tester.pump();

    expect(find.text('Connecting…'), findsOneWidget);
  });

  testWidgets(
    'remote menu reads an empty advert as offline, not "no projects"',
    (tester) async {
      // A null/absent control-plane client yields an empty ControlPlaneState
      // (not an error), so the common OFFLINE case surfaces as an empty advert.
      await tester.pumpWidget(
        _host(
          sources: const [_remoteSource],
          extraOverrides: [
            controlPlaneStateProvider(
              'u1',
            ).overrideWith((ref) => Stream.value(const ControlPlaneState())),
          ],
        ),
      );
      await tester.pumpAndSettle();

      await tester.tap(find.byType(ProjectChip));
      await tester.pumpAndSettle();

      expect(find.text('Machine offline'), findsOneWidget);
      expect(find.text('No projects advertised'), findsNothing);
    },
  );

  testWidgets(
    'remote menu explains remoteAccessEnabled:false instead of "offline"',
    (tester) async {
      // The advert arrived and said the switch is off — same wording as the
      // NOT_ALLOWED verb refusal, pinned via friendlyErrorCopy so the two
      // surfaces can't drift apart.
      await tester.pumpWidget(
        _host(
          sources: const [_remoteSource],
          extraOverrides: [
            controlPlaneStateProvider('u1').overrideWith(
              (ref) => Stream.value(
                const ControlPlaneState(
                  projects: [],
                  remoteAccessEnabled: false,
                ),
              ),
            ),
          ],
        ),
      );
      await tester.pumpAndSettle();

      await tester.tap(find.byType(ProjectChip));
      await tester.pumpAndSettle();

      expect(find.text(friendlyErrorCopy('NOT_ALLOWED')!), findsOneWidget);
      expect(find.text('Machine offline'), findsNothing);
    },
  );

  testWidgets(
    'remote menu reads remoteAccessEnabled:true + empty as "no projects yet"',
    (tester) async {
      await tester.pumpWidget(
        _host(
          sources: const [_remoteSource],
          extraOverrides: [
            controlPlaneStateProvider('u1').overrideWith(
              (ref) => Stream.value(
                const ControlPlaneState(
                  projects: [],
                  remoteAccessEnabled: true,
                ),
              ),
            ),
          ],
        ),
      );
      await tester.pumpAndSettle();

      await tester.tap(find.byType(ProjectChip));
      await tester.pumpAndSettle();

      expect(find.text('No projects on this machine yet'), findsOneWidget);
      expect(find.text('Machine offline'), findsNothing);
    },
  );

  testWidgets('remote menu reads a control-plane error as offline', (
    tester,
  ) async {
    await tester.pumpWidget(
      _host(
        sources: const [_remoteSource],
        extraOverrides: [
          controlPlaneStateProvider('u1').overrideWith(
            (ref) => Stream<ControlPlaneState>.error(StateError('unreachable')),
          ),
        ],
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.byType(ProjectChip));
    await tester.pumpAndSettle();

    expect(find.text('Machine offline'), findsOneWidget);
  });

  testWidgets('placeholder machine source renders an empty state (no crash)', (
    tester,
  ) async {
    // buildPickerSources' mobile fallback has a null machineUuid; the menu must
    // not force-unwrap it (the CRITICAL crash) — a graceful hint instead.
    await tester.pumpWidget(_host(sources: const [_placeholderSource]));
    await tester.pumpAndSettle();

    await tester.tap(find.byType(ProjectChip));
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull);
    expect(find.text('No machines on this account'), findsOneWidget);
  });

  testWidgets('local menu with no projects shows the empty-state hint', (
    tester,
  ) async {
    await tester.pumpWidget(_host(sources: const [_emptyLocalSource]));
    await tester.pumpAndSettle();

    await tester.tap(find.byType(ProjectChip));
    await tester.pumpAndSettle();

    expect(find.text('Open folder…'), findsOneWidget);
    expect(find.text('No local projects yet'), findsOneWidget);
  });

  testWidgets(
    'remote menu: live advert rows appear and picking one writes target',
    (tester) async {
      await tester.pumpWidget(
        _host(
          sources: const [_remoteSource],
          extraOverrides: [
            controlPlaneStateProvider('u1').overrideWith(
              (ref) => Stream.value(
                const ControlPlaneState(
                  projects: [
                    AdvertisedProject(
                      projectId: 'a',
                      label: 'Alpha',
                      path: '/a',
                      running: true,
                    ),
                    AdvertisedProject(
                      projectId: 'b',
                      path: '/b',
                      running: false,
                    ),
                  ],
                ),
              ),
            ),
          ],
        ),
      );
      await tester.pumpAndSettle();

      await tester.tap(find.byType(ProjectChip));
      await tester.pumpAndSettle();

      expect(find.text('Alpha'), findsOneWidget);
      expect(find.text('b'), findsOneWidget);
      // The running/stopped status is each row's secondary text.
      expect(find.text('Running'), findsOneWidget);
      expect(find.text('Stopped'), findsOneWidget);

      final container = ProviderScope.containerOf(
        tester.element(find.byType(ProjectChip)),
      );
      await tester.tap(find.text('Alpha'));
      await tester.pumpAndSettle();

      expect(container.read(selectedTargetProjectProvider)?.id, 'u1.a');
    },
  );

  testWidgets('the advert is watched only while the menu is open', (
    tester,
  ) async {
    var subscriptions = 0;
    await tester.pumpWidget(
      _host(
        sources: const [_remoteSource],
        extraOverrides: [
          controlPlaneStateProvider('u1').overrideWith((ref) {
            subscriptions++;
            return Stream.value(const ControlPlaneState());
          }),
        ],
      ),
    );
    await tester.pumpAndSettle();

    // A visible composer must not dial the machine.
    expect(subscriptions, 0);

    await tester.tap(find.byType(ProjectChip));
    await tester.pumpAndSettle();

    expect(subscriptions, 1);
    expect(find.text('Machine offline'), findsOneWidget);
  });

  testWidgets('remote rows carry Running / Stopped with recency', (
    tester,
  ) async {
    final now = DateTime.now();
    await tester.pumpWidget(
      _host(
        sources: const [_remoteSource],
        extraOverrides: [
          controlPlaneStateProvider('u1').overrideWith(
            (ref) => Stream.value(
              ControlPlaneState(
                projects: [
                  AdvertisedProject(
                    projectId: 'old',
                    label: 'Old',
                    path: '/old',
                    running: false,
                    lastActiveAt: now
                        .subtract(const Duration(hours: 3))
                        .toUtc()
                        .toIso8601String(),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.byType(ProjectChip));
    await tester.pumpAndSettle();

    expect(find.textContaining('Stopped · last active'), findsOneWidget);
  });
}

void _noop() {}
