import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:antgrid/design/ab_status_tone.dart';
import 'package:antgrid/design/theme_presets.dart';
import 'package:antgrid/design/widgets/ab_status_dot.dart';
import 'package:antgrid/models/recent_session_row.dart';
import 'package:antgrid/models/session_entry.dart';
import 'package:antgrid/providers/recent_sessions.dart';
import 'package:antgrid/services/control_plane_client.dart';
import 'package:antgrid/widgets/agent_work_status_dot.dart';
import 'package:antgrid/widgets/recent_sessions/recent_session_row_widget.dart';

/// End-to-end for the signal the Recent list exists to carry: a status published
/// on the live map has to reach the pixel on the row.
///
/// Every layer between the two is separately reactive and separately tested, so
/// the gap this closes is the seam — a row that reads the wrong entryId, a
/// `select` that compares the wrong thing, or a leading glyph that takes its
/// status once and never looks again. All three fail silently as "the dot never
/// changes", which is indistinguishable from the agent simply being idle.
void main() {
  testWidgets('the row badge follows the live per-session status', (
    tester,
  ) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.macOS;

    final container = ProviderContainer();
    addTearDown(container.dispose);

    final row = RecentSessionRow(
      session: const SessionEntry(
        id: 's1',
        name: 'Fix auth bug',
        createdAt: 0,
        lastUsedAt: 0,
        archived: false,
        // False on purpose: the cache loads every session stopped, so a row
        // whose status only survived while `running` was true would pass here
        // and still be dead in the app after a restart.
        running: false,
        tool: 'claude-code',
      ),
      origin: const RecentOrigin(
        isLocal: true,
        registrationId: 'proj',
        projectId: 'proj',
        machineUuid: null,
        projectName: 'antgrid',
        deviceName: 'This device',
      ),
    );

    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          theme: ThemeData.dark().copyWith(
            extensions: <ThemeExtension<dynamic>>[kDefaultPalette],
          ),
          home: Scaffold(body: RecentSessionRowWidget(row: row)),
        ),
      ),
    );
    await tester.pump();

    AbStatusDot badge() => tester.widget<AbStatusDot>(
      find.descendant(
        of: find.byType(AgentWorkStatusBadge),
        matching: find.byType(AbStatusDot),
      ),
    );

    Future<void> publish(AgentWorkStatus status) async {
      container
          .read(remoteSessionStatusProvider.notifier)
          .setLocalSessionStatuses({
            'proj': {'s1': status},
          });
      await tester.pump();
    }

    expect(badge().tone, AbStatusTone.agentIdle);

    await publish(AgentWorkStatus.working);
    expect(badge().tone, AbStatusTone.info);
    // The pulse is half the signal — a working row that stopped breathing reads
    // as finished.
    expect(badge().pulse, isTrue);

    await publish(AgentWorkStatus.attention);
    expect(badge().tone, AbStatusTone.warning);
    expect(badge().pulse, isTrue);

    await publish(AgentWorkStatus.error);
    expect(badge().tone, AbStatusTone.danger);

    await publish(AgentWorkStatus.done);
    expect(badge().tone, AbStatusTone.agentIdle);
    expect(badge().pulse, isFalse);

    debugDefaultTargetPlatformOverride = null;
  });
}
